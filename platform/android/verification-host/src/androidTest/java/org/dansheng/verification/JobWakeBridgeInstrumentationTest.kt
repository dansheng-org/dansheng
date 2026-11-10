// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.content.Intent
import android.test.InstrumentationTestCase
import org.dansheng.android.*
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Mocked core client, actual Android AlarmManager/FGS delivery. No network or remote mutation. */
@Suppress("DEPRECATION")
class JobWakeBridgeInstrumentationTest : InstrumentationTestCase() {
    private lateinit var activity: FixtureActivity
    private lateinit var client: FixtureCore
    private lateinit var host: CoreJobWakeHost
    private lateinit var bridge: JobWakeDispatcher
    private lateinit var wake: AndroidWakePort
    private var activeAccount: String? = "fixture-a"
    private var permitted = true
    private val resumes = java.util.concurrent.CopyOnWriteArrayList<String>()

    class FixtureCore : CoreJobClient {
        val jobs = ConcurrentHashMap<String, JSONObject>()
        val calls = java.util.concurrent.CopyOnWriteArrayList<String>()
        val ran = CountDownLatch(1)
        @Volatile var initializedAt = 0L
        @Volatile var executedAt = 0L
        override fun initialize(reply: (Result<Unit>) -> Unit) { initializedAt = System.currentTimeMillis(); calls.add("initialize"); reply(Result.success(Unit)) }
        override fun request(method: String, params: JSONObject, deadlineEpochMs: Long, reply: PortReply) {
            calls.add(method)
            val job = jobs[params.getString("job_id")]
            if (job == null) { reply(Result.failure(PortError("NotFound"))); return }
            if (method == "jobs.run") {
                if (System.currentTimeMillis() >= Instant.parse(job.getJSONObject("data").getString("deadline_at")).toEpochMilli()) {
                    reply(Result.failure(PortError("DeadlineExceeded"))); return
                }
                executedAt = System.currentTimeMillis(); job.put("state", "succeeded"); ran.countDown()
                reply(Result.success(JSONObject().put("result", JSONObject().put("synthetic", true))))
            } else reply(Result.success(JSONObject().put("result", JSONObject(job.toString()))))
        }
        override fun cancelLocal(jobId: String) { calls.add("cancel:" + jobId) }
    }
    override fun setUp() {
        super.setUp()
        activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, FixtureActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as FixtureActivity
        client = FixtureCore()
        host = CoreJobWakeHost(client, { activeAccount }, { permitted && it.owner == "fixture-owner" }, { _, reason -> resumes.add(reason) })
        AndroidRuntime.execution = host
        bridge = JobWakeDispatcher(activity, host); wake = AndroidWakePort(activity)
    }
    override fun tearDown() {
        wake.all().forEach { wake.cancel(it.jobId, it.owner) }
        host.close(); AndroidRuntime.execution = null
        instrumentation.runOnMainSync { activity.finish() }
        super.tearDown()
    }
    private fun job(id: String, runAt: Long, deadline: Long, account: String? = "fixture-a"): JSONObject {
        val data = JSONObject().put("deadline_at", Instant.ofEpochMilli(deadline).toString())
            .put("account_id", account ?: JSONObject.NULL)
        client.jobs[id] = JSONObject().put("id", id).put("owner", JSONObject().put("id", "fixture-owner"))
            .put("run_at", Instant.ofEpochMilli(runAt).toString()).put("state", "scheduled").put("data", data)
        return JSONObject().put("job_id", id).put("run_at", Instant.ofEpochMilli(runAt).toString())
            .put("deadline_at", Instant.ofEpochMilli(deadline).toString()).put("account_id", account ?: JSONObject.NULL)
    }
    private fun call(method: String, input: JSONObject): Result<JSONObject> {
        val latch = CountDownLatch(1); val result = AtomicReference<Result<JSONObject>>()
        bridge.dispatch(method, input) { result.set(it); latch.countDown() }
        assertTrue("bridge reply timed out", latch.await(5, TimeUnit.SECONDS)); return result.get()
    }
    fun testActualAlarmInitializesThenRunsCoreAtRunAt() {
        val capabilities = call("jobs.wake.status", JSONObject()).getOrThrow()
        assertTrue("Grant exact-alarm access in the visible Settings UI before running actual-alarm fixture", capabilities.getBoolean("exact_available"))
        val now = System.currentTimeMillis(); val execute = now + 9000
        val input = job("fixture-bridge-actual", execute, now + 25000)
            .put("prepare_at", Instant.ofEpochMilli(now + 1000).toString())
        val result = call("jobs.wake.schedule", input).getOrThrow()
        assertTrue(result.getBoolean("exact")); assertEquals("exact", result.getString("precision"))
        assertTrue(client.ran.await(18, TimeUnit.SECONDS))
        assertTrue(client.calls.indexOf("initialize") < client.calls.indexOf("jobs.run"))
        assertTrue("jobs.run executed before declared time", client.executedAt >= execute)
        assertEquals(1, client.calls.count { it == "jobs.run" })
    }
    fun testPersistedCancelExpiredSkipAndExplicitInexactReport() {
        val now = System.currentTimeMillis()
        val request = job("fixture-bridge-cancel", now + 60000, now + 90000).put("precision", "inexact")
        val result = call("jobs.wake.schedule", request).getOrThrow()
        assertFalse(result.getBoolean("exact")); assertEquals("inexact", result.getString("precision"))
        val persisted = AndroidWakePort(activity).load("fixture-bridge-cancel")!!
        assertEquals(now + 60000, persisted.executeAt)
        client.jobs.remove(persisted.jobId) // Core may delete the row before its platform cancellation.
        call("jobs.wake.cancel", JSONObject().put("job_id", persisted.jobId)).getOrThrow()
        wake.deliver(persisted.jobId, persisted.generation)
        assertNull(wake.load(persisted.jobId)); assertEquals(0, client.calls.count { it == "jobs.run" })
        val expired = job("fixture-bridge-expired", now - 1000, now - 1).put("precision", "inexact")
        assertEquals("DeadlineExceeded", (call("jobs.wake.schedule", expired).exceptionOrNull() as PortError).code)
        assertNull(wake.load("fixture-bridge-expired"))
        assertEquals(0, client.calls.count { it == "jobs.run" })
    }
    fun testRestoreRearamsFutureButClaimedRequiresReconciliation() {
        val now = System.currentTimeMillis()
        call("jobs.wake.schedule", job("fixture-bridge-restore", now + 60000, now + 90000).put("precision", "inexact")).getOrThrow()
        val before = wake.load("fixture-bridge-restore")!!
        AndroidWakePort(activity).restore()
        assertEquals(before, wake.load(before.jobId)); assertTrue(resumes.isEmpty())
        assertTrue(wake.claim(before)); AndroidWakePort(activity).restore()
        assertTrue(resumes.contains("ProcessRestartRequiresReconciliation")); assertEquals(0, client.calls.count { it == "jobs.run" })
    }
    fun testWrongAccountOwnerGrantAndDeadlineCannotOverrideCoreBinding() {
        val now = System.currentTimeMillis()
        val input = job("fixture-bridge-grant", now + 60000, now + 90000).put("precision", "inexact")
        assertEquals("PermissionDenied", (call("jobs.wake.schedule", JSONObject(input.toString()).put("account_id", "another-account")).exceptionOrNull() as PortError).code)
        assertEquals("JobNotRunnable", (call("jobs.wake.schedule", JSONObject(input.toString()).put("deadline_at", Instant.ofEpochMilli(now + 100000).toString())).exceptionOrNull() as PortError).code)
        val envelope = JSONObject().put("principal", JSONObject().put("id", "other-owner").put("kind", "client"))
            .put("grant", JSONObject().put("capabilities", org.json.JSONArray().put("jobs.wake.schedule"))
                .put("account_ids", org.json.JSONArray().put("fixture-a"))).put("input", input)
        assertEquals("PermissionDenied", (call("jobs.wake.schedule", envelope).exceptionOrNull() as PortError).code)
        activeAccount = "fixture-b"
        assertEquals("PermissionDenied", (call("jobs.wake.schedule", input).exceptionOrNull() as PortError).code)
        activeAccount = null
        val unscoped = job("fixture-bridge-unscoped", now + 60000, now + 90000, null).put("precision", "inexact")
        client.jobs["fixture-bridge-unscoped"]!!.getJSONObject("data").put("input", JSONObject().put("account_id", JSONObject.NULL))
        assertTrue(call("jobs.wake.schedule", unscoped).getOrThrow().getBoolean("scheduled"))
    }
    fun testWorkerCancellationAndExpiredLookupNeverRunCoreJob() {
        val now = System.currentTimeMillis()
        job("fixture-worker-cancel", now + 350, now + 3000)
        val s = WakeSpec("fixture-worker-cancel", "fixture-a", "fixture-owner", now, now + 3000, executeAt = now + 350)
        val done = CountDownLatch(1); host.start(s) { done.countDown() }; host.cancel(s.jobId)
        assertTrue(done.await(2, TimeUnit.SECONDS)); Thread.sleep(400)
        assertEquals(0, client.calls.count { it == "jobs.run" })
        job("fixture-worker-expired", now - 1000, now - 1)
        val expired = s.copy(jobId = "fixture-worker-expired", runAt = now - 1000, executeAt = now - 1000, deadline = now - 1)
        val ended = CountDownLatch(1); host.start(expired) { ended.countDown() }
        assertTrue(ended.await(2, TimeUnit.SECONDS)); assertEquals(0, client.calls.count { it == "jobs.run" })
    }
    fun testExistingCoreClaimIsFollowedWithoutAnotherRun() {
        val now = System.currentTimeMillis()
        job("fixture-already-running", now - 1, now + 4000)
        client.jobs["fixture-already-running"]!!.put("state", "running")
        val s = WakeSpec("fixture-already-running", "fixture-a", "fixture-owner", now - 1, now + 4000)
        val done = CountDownLatch(1); host.start(s) { done.countDown() }
        client.jobs[s.jobId]!!.put("state", "succeeded")
        assertTrue(done.await(2, TimeUnit.SECONDS)); assertEquals(0, client.calls.count { it == "jobs.run" })
    }
}
