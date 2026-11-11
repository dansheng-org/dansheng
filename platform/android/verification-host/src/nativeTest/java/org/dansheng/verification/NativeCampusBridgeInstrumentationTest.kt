// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.content.Intent
import android.test.InstrumentationTestCase
import org.dansheng.android.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Real Rust C ABI -> official Canvas service -> authenticated page wrapper ->
 * source cache. The WebView blocks network loads and contains only synthetic data.
 */
@Suppress("DEPRECATION")
class NativeCampusBridgeInstrumentationTest : InstrumentationTestCase() {
    fun testRegisteredCanvasUsesPageAndPersistsTheSameRecords() {
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext,
            FixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as FixtureActivity
        var engine = 0L
        var pump: PlatformPump? = null
        fun await(operation: Long): JSONObject {
            val end = System.currentTimeMillis() + 20_000
            while (System.currentTimeMillis() < end) {
                NativeCore.poll(operation)?.let { return JSONObject(it.toString(Charsets.UTF_8)) }
                Thread.sleep(10)
            }
            throw AssertionError("native fixture operation timed out")
        }
        fun request(method: String, params: JSONObject): JSONObject = await(NativeCore.request(engine,
            JSONObject().put("id", "native-campus-fixture").put("method", method).put("params", params)
                .toString().toByteArray(Charsets.UTF_8))).also {
            assertFalse("native fixture returned an error code", it.has("error"))
        }.getJSONObject("result")
        try {
            val loggedIn = CountDownLatch(1)
            val result = AtomicReference<Result<JSONObject>>()
            activity.browser.call("browser.login", activity.authority(), JSONObject()
                .put("account_id", "fixture-a").put("url", "https://fixture.invalid/")) {
                result.set(it); loggedIn.countDown()
            }
            val end = System.currentTimeMillis() + 5000
            var ready = false
            while (!ready && System.currentTimeMillis() < end) {
                val checked = CountDownLatch(1)
                instrumentation.runOnMainSync {
                    activity.fixtureView?.evaluateJavascript("window.fixtureIdentity === 'fixture-a'") {
                        ready = it == "true"; checked.countDown()
                    } ?: checked.countDown()
                }
                checked.await(1, TimeUnit.SECONDS)
                if (!ready) Thread.sleep(25)
            }
            assertTrue(ready)
            instrumentation.runOnMainSync { activity.verifyLogin!!.invoke() }
            assertTrue(loggedIn.await(5, TimeUnit.SECONDS))
            result.get().getOrThrow()
            val scripted = CountDownLatch(1)
            instrumentation.runOnMainSync {
                activity.fixtureView!!.evaluateJavascript("window.fixtureReply=[{id:'9007199254740993123456789',title:'Synthetic native quiz',course_id:'81001',quiz_type:'assignment',points_possible:5}];window.fixtureHeaders={'content-type':'application/json'};") {
                    scripted.countDown()
                }
            }
            assertTrue(scripted.await(3, TimeUnit.SECONDS))
            NativeCore.load()
            val open = await(NativeCore.open(JSONObject()
                .put("data_dir", activity.filesDir.resolve("native-campus-${System.nanoTime()}").absolutePath)
                .put("platform_capabilities", JSONArray(listOf("browser.evaluate", "browser.request")))
                .toString().toByteArray(Charsets.UTF_8)))
            assertFalse(open.has("error"))
            engine = open.getJSONObject("result").getLong("engine")
            pump = PlatformPump(engine, BrowserDispatcher(activity.browser)).also { it.start() }
            val configured = request("canvas.configure", JSONObject().put("account_id", "fixture-a")
                .put("origin", "https://fixture.invalid").put("access", "browser_session"))
            assertEquals("browser_session", configured.getString("access"))
            val synced = await(NativeCore.request(engine, JSONObject().put("id", "native-canvas")
                .put("method", "canvas.quizzes.sync").put("params", JSONObject()
                    .put("account_id", "fixture-a").put("course_id", "81001"))
                .toString().toByteArray(Charsets.UTF_8)))
            assertFalse("Canvas native read failed", synced.has("error"))
            val records = synced.getJSONArray("result")
            assertEquals(1, records.length())
            assertEquals("9007199254740993123456789", records.getJSONObject(0).getJSONObject("payload").getString("id"))
            val query = await(NativeCore.request(engine, JSONObject().put("id", "native-cache")
                .put("method", "sources.query").put("params", JSONObject()
                    .put("account_id", "fixture-a").put("source_id", "official.canvas.quizzes:81001"))
                .toString().toByteArray(Charsets.UTF_8)))
            assertFalse(query.has("error"))
            val cached = query.getJSONArray("result")
            assertEquals(1, cached.length())
            assertEquals(records.getJSONObject(0).getJSONObject("payload").toString(), cached.getJSONObject(0).getJSONObject("data").toString())
            val observed = CountDownLatch(1)
            val calls = AtomicReference<String>()
            instrumentation.runOnMainSync {
                activity.fixtureView!!.evaluateJavascript("JSON.stringify(window.fixtureCalls)") {
                    calls.set(it); observed.countDown()
                }
            }
            assertTrue(observed.await(3, TimeUnit.SECONDS))
            assertTrue(calls.get().contains("/api/v1/courses/81001/quizzes"))
            assertTrue(calls.get().contains("synthetic-waf=dynamic"))
        } finally {
            pump?.close()
            if (engine != 0L) await(NativeCore.close(engine))
            instrumentation.runOnMainSync { activity.finish() }
            instrumentation.waitForIdleSync()
        }
    }
}
