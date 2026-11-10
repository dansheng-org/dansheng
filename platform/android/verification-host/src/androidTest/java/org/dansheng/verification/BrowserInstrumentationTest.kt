// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.content.Intent
import android.test.InstrumentationTestCase
import org.dansheng.android.*
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@Suppress("DEPRECATION")
class BrowserInstrumentationTest : InstrumentationTestCase() {
    private lateinit var activity: FixtureActivity
    override fun setUp() {
        super.setUp()
        val intent = Intent(instrumentation.targetContext, FixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity = instrumentation.startActivitySync(intent) as FixtureActivity
    }
    override fun tearDown() {
        instrumentation.runOnMainSync { activity.finish() }
        instrumentation.waitForIdleSync(); super.tearDown()
    }
    private fun call(capability: String, p: JSONObject, authority: Authority = activity.authority()): Result<JSONObject> {
        val latch = CountDownLatch(1); val result = AtomicReference<Result<JSONObject>>()
        activity.browser.call(capability, authority, p) { result.set(it); latch.countDown() }
        assertTrue("browser reply timed out", latch.await(10, TimeUnit.SECONDS))
        return result.get()
    }
    private fun login(): String {
        val latch = CountDownLatch(1); val result = AtomicReference<Result<JSONObject>>()
        activity.browser.call("browser.login", activity.authority(), JSONObject().put("account_id", "fixture-a")
            .put("url", "https://fixture.invalid/")) { result.set(it); latch.countDown() }
        val end = System.currentTimeMillis() + 5000
        var ready = false
        while (!ready && System.currentTimeMillis() < end) {
            val checked = CountDownLatch(1)
            instrumentation.runOnMainSync {
                activity.fixtureView?.evaluateJavascript("window.fixtureIdentity === 'fixture-a'") { r -> ready = r == "true"; checked.countDown() }
                    ?: checked.countDown()
            }
            checked.await(1, TimeUnit.SECONDS)
            if (!ready) Thread.sleep(25)
        }
        assertTrue("synthetic document not loaded", ready)
        instrumentation.runOnMainSync { activity.verifyLogin!!.invoke() }
        assertTrue(latch.await(5, TimeUnit.SECONDS)); return result.get().getOrThrow().getString("session_handle")
    }
    private fun request(handle: String, path: String = "/api", write: Boolean = false): JSONObject = JSONObject()
        .put("account_id", "fixture-a").put("session_handle", handle).put("url", "https://fixture.invalid$path")
        .put("method", if (write) "POST" else "GET").put("transport", if (write) "xhr" else "fetch")
        .put("headers", JSONObject().put("Accept", "application/json").apply { if (write) put("sign-key", "fixturepost") })
        .put("deadline_epoch_ms", System.currentTimeMillis() + 2000)
        .apply { if (write) put("form_fields", JSONObject().put("data", "synthetic")) }

    fun testVisibleLoginCurrentPageFetchAndXhr() {
        val handle = login()
        assertTrue(call("browser.request", request(handle)).getOrThrow().getString("body").contains("dynamic"))
        assertTrue(call("browser.request", request(handle, write = true)).isSuccess)
        val latch = CountDownLatch(1); var calls = ""
        instrumentation.runOnMainSync { activity.fixtureView!!.evaluateJavascript("JSON.stringify(window.fixtureCalls)") { calls = it; latch.countDown() } }
        assertTrue(latch.await(3, TimeUnit.SECONDS))
        assertTrue(calls.contains("synthetic-waf=dynamic")); assertTrue(calls.contains("fetch"))
        assertTrue(calls.contains("xhr")); assertTrue(calls.contains("fixturepost")); assertTrue(calls.contains("form"))
    }
    fun testOwnershipGrantsAndArbitraryScriptDenied() {
        val handle = login()
        val wrong = request(handle).put("account_id", "fixture-b")
        assertEquals("SessionOwnershipMismatch", (call("browser.request", wrong).exceptionOrNull() as PortError).code)
        val grant = Authority("plugin:fixture", false, setOf("browser.request"), setOf("fixture-b"), setOf("https://fixture.invalid"))
        assertEquals("PermissionDenied", (call("browser.request", request(handle), grant).exceptionOrNull() as PortError).code)
        assertEquals("OriginMismatch", (call("browser.request", request(handle).put("url", "https://other.invalid/api")).exceptionOrNull() as PortError).code)
        assertEquals("CapabilityUnavailable", (call("browser.evaluate", JSONObject().put("account_id", "fixture-a")
            .put("operation", "eval").put("script", "document.cookie")).exceptionOrNull() as PortError).code)
    }
    fun testWriteDeadlineIsUncertainAndLogoutRevokesHandle() {
        val handle = login()
        val hanging = request(handle, "/hang", true).put("deadline_epoch_ms", System.currentTimeMillis() + 100)
        assertEquals("NeedsReconciliation", (call("browser.request", hanging).exceptionOrNull() as PortError).code)
        val close = JSONObject().put("account_id", "fixture-a").put("session_handle", handle)
        assertTrue(call("browser.close", close).getOrThrow().getBoolean("closed"))
        assertEquals("AuthenticationRequired", (call("browser.request", request(handle)).exceptionOrNull() as PortError).code)
    }
    fun testExpiredRequestNeverDispatchesAndCancelDuringWriteIsUncertain() {
        val handle = login()
        assertEquals("DeadlineExceeded", (call("browser.request", request(handle).put("deadline_epoch_ms", 1)).exceptionOrNull() as PortError).code)
        val latch = CountDownLatch(1); val result = AtomicReference<Result<JSONObject>>()
        activity.browser.call("browser.request", activity.authority(), request(handle, "/hang", true)) { result.set(it); latch.countDown() }
        Thread.sleep(50)
        val cleared = CountDownLatch(1); activity.browser.logout("fixture-a") { cleared.countDown() }
        assertTrue(latch.await(5, TimeUnit.SECONDS)); assertTrue(cleared.await(5, TimeUnit.SECONDS))
        assertEquals("NeedsReconciliation", (result.get().exceptionOrNull() as PortError).code)
    }
    fun testCancellingVisibleHandoffRevokesAndAllowsNewLogin() {
        val done = CountDownLatch(1); val result = AtomicReference<Result<JSONObject>>()
        activity.browser.call("browser.login", activity.authority(), JSONObject().put("account_id", "fixture-a")
            .put("url", "https://fixture.invalid/")) { result.set(it); done.countDown() }
        // Main-thread barrier ensures the handoff was created before host cancellation.
        instrumentation.waitForIdleSync()
        val cleared = CountDownLatch(1); activity.browser.logout("fixture-a") { cleared.countDown() }
        assertTrue(done.await(5, TimeUnit.SECONDS)); assertTrue(cleared.await(5, TimeUnit.SECONDS))
        assertEquals("AuthenticationRequired", (result.get().exceptionOrNull() as PortError).code)
        assertTrue(login().isNotBlank())
    }
    fun testStatusZeroNetworkLossAndPostBodyInterruptionRemainUncertain() {
        val handle = login()
        for (path in listOf("/status-zero", "/network-loss")) {
            assertEquals("NeedsReconciliation", (call("browser.request", request(handle, path, true)).exceptionOrNull() as PortError).code)
        }
        val fetch = request(handle, "/body-interrupted", true).put("transport", "fetch").put("body", "synthetic")
        fetch.remove("form_fields")
        assertEquals("NeedsReconciliation", (call("browser.request", fetch).exceptionOrNull() as PortError).code)
    }
    fun testPostRequiresWriteGrantWhileGetRemainsReadOnly() {
        val handle = login()
        val readOnly = Authority("plugin:fixture", false, setOf("browser.request"), setOf("fixture-a"), setOf("https://fixture.invalid"))
        assertTrue(call("browser.request", request(handle), readOnly).isSuccess)
        assertEquals("PermissionDenied", (call("browser.request", request(handle, write = true), readOnly).exceptionOrNull() as PortError).code)
        val writable = readOnly.copy(capabilities = setOf("browser.request", "browser.write"))
        assertTrue(call("browser.request", request(handle, write = true), writable).isSuccess)
        instrumentation.runOnMainSync { activity.allowFixtureWrites = false }
        assertEquals("ApprovalRequired", (call("browser.request", request(handle, write = true), writable).exceptionOrNull() as PortError).code)
    }
}
