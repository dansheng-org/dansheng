// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.app.AlarmManager
import android.content.Intent
import android.test.InstrumentationTestCase
import org.dansheng.android.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@Suppress("DEPRECATION")
class WakeInstrumentationTest : InstrumentationTestCase() {
    private lateinit var activity: FixtureActivity
    private lateinit var wake: AndroidWakePort
    private lateinit var execution: FixtureExecution
    class FixtureExecution : WakeExecutionPort {
        var account = "fixture-a"; var authorized = true
        val started = CountDownLatch(1); val cancelled = CountDownLatch(1)
        val resumed = mutableListOf<String>()
        override fun activeAccount() = account
        override fun authorize(spec: WakeSpec) = authorized && spec.owner == "fixture-owner"
        override fun start(spec: WakeSpec, done: () -> Unit) { started.countDown() }
        override fun cancel(jobId: String) { cancelled.countDown() }
        override fun needsUserResume(spec: WakeSpec, reason: String) { resumed.add(reason) }
    }
    override fun setUp() {
        super.setUp()
        activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, FixtureActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as FixtureActivity
        execution = FixtureExecution(); AndroidRuntime.execution = execution
        wake = AndroidWakePort(activity)
    }
    override fun tearDown() {
        wake.all().forEach { wake.cancel(it.jobId, it.owner) }
        instrumentation.runOnMainSync { activity.finish() }
        AndroidRuntime.execution = null
        super.tearDown()
    }
    private fun spec(deadlineMs: Long = 3000) = WakeSpec("fixture-wake", "fixture-a", "fixture-owner",
        System.currentTimeMillis() + 60000, System.currentTimeMillis() + 60000 + deadlineMs)
    private fun canExact() = activity.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    fun testExactPermissionAccountOwnerAndDurableGeneration() {
        val s = spec()
        if (!canExact()) {
            try { wake.schedule(s); fail("permission gate expected") } catch (e: PortError) { assertEquals("ExactAlarmPermissionRequired", e.code) }
            return
        }
        wake.schedule(s)
        assertEquals(s, AndroidWakePort(activity).load(s.jobId))
        try { wake.cancel(s.jobId, "another-owner"); fail("wrong owner") } catch (e: PortError) { assertEquals("PermissionDenied", e.code) }
        assertTrue(wake.claim(s)); assertFalse(wake.claim(s))
        val next = s.copy(generation = "new-fixture-generation"); wake.schedule(next)
        assertFalse(wake.claim(s)); assertTrue(wake.claim(next))
        wake.cancelAccount("fixture-a"); assertNull(wake.load(s.jobId))
        execution.account = "fixture-b"
        try { wake.schedule(s); fail("account mismatch") } catch (e: PortError) { assertEquals("PermissionDenied", e.code) }
    }
    fun testRestoreRequiresVisibleResumptionAndNeverStartsWork() {
        if (!canExact()) return
        val s = spec(); wake.schedule(s); wake.restore()
        assertTrue(execution.resumed.isEmpty())
        assertEquals(s, AndroidWakePort(activity).load(s.jobId))
        assertTrue(wake.claim(s)); wake.restore()
        assertTrue(execution.resumed.contains("ProcessRestartRequiresReconciliation"))
        assertEquals(1L, execution.started.count)
        execution.account = "fixture-b"; wake.deliver(s.jobId, s.generation)
        assertEquals(1L, execution.started.count)
    }
    fun testDurableMutationClaimsRespectAccountDeadlineAndReconciliation() {
        val operation = "fixture-" + java.util.UUID.randomUUID()
        val request = org.json.JSONObject().put("mutation_key", operation).put("deadline_epoch_ms", System.currentTimeMillis() + 5000)
        val gate = PersistentMutationGate(activity) { principal, account, _, _ -> principal == "fixture-owner" && account == "fixture-a" }
        assertFalse(gate.allowed("unapproved", "fixture-a", request))
        assertFalse(gate.allowed("fixture-owner", "fixture-b", request))
        assertTrue(gate.allowed("fixture-owner", "fixture-a", request))
        val reopened = PersistentMutationGate(activity) { _, _, _, _ -> true }
        try { reopened.allowed("fixture-owner", "fixture-a", request); fail("duplicate write") }
        catch (e: PortError) { assertEquals("NeedsReconciliation", e.code) }
        reopened.clearAfterAuthoritativeAbsence("fixture-owner", "fixture-a", operation)
        assertTrue(reopened.allowed("fixture-owner", "fixture-a", request))
        try { reopened.allowed("fixture-owner", "fixture-a", org.json.JSONObject(request.toString()).put("deadline_epoch_ms", 1)); fail("expired mutation") }
        catch (e: PortError) { assertEquals("DeadlineExceeded", e.code) }
    }
    fun testForegroundDeadlineStopsWithoutAutomaticRestart() {
        if (!canExact()) return
        val now = System.currentTimeMillis()
        val s = WakeSpec("fixture-deadline", "fixture-a", "fixture-owner", now - 1, now + 12000)
        // Actual alarm is exercised, not a direct call into the lifecycle policy.
        wake.schedule(s)
        assertTrue("foreground job did not start: " + execution.resumed, execution.started.await(10, TimeUnit.SECONDS))
        assertTrue("deadline did not cancel", execution.cancelled.await(13, TimeUnit.SECONDS))
        assertFalse(wake.claim(s))
    }
}
