// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ScheduledFuture

/** Trusted application's core initializer/transport. Replies contain the standard Response envelope.
 * initialize must open core, attach its platform pump and load current account/grants on a worker.
 * It must NOT execute overdue jobs independently of core's claim/deadline/reconciliation rules.
 */
interface CoreJobClient {
    fun beginLocal(jobId: String) {}
    fun initialize(reply: (Result<Unit>) -> Unit)
    fun request(method: String, params: JSONObject, deadlineEpochMs: Long, reply: PortReply)
    fun cancelLocal(jobId: String)
}

/** Production host glue: initialization at prepare_at, fresh job lookup, then jobs.run at run_at.
 * permissionNow is a trusted, nonblocking current-account/grant check, not a JSON approval flag.
 * Core jobs.run remains responsible for persistent atomic claim and mutation authorization.
 */
class CoreJobWakeHost(private val client: CoreJobClient,
    private val accountNow: () -> String?, private val permissionNow: (WakeSpec) -> Boolean,
    private val onResumeRequired: (WakeSpec, String) -> Unit
) : WakeExecutionPort, JobBindingResolver, AutoCloseable {
    private class Run(val spec: WakeSpec, val done: () -> Unit) {
        val live = AtomicBoolean(true)
        val prepared = AtomicBoolean(false)
        val timer = AtomicReference<ScheduledFuture<*>?>()
    }
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val running = ConcurrentHashMap<String, Run>()
    /** Optional host-owned, read-only warm-up after validating the actual job.
     * The continuation always re-checks the lease, account, grants and deadline. */
    @Volatile var prepareSession: ((WakeSpec, () -> Unit) -> Unit)? = null
    override fun activeAccount(): String? = accountNow()
    override fun authorize(spec: WakeSpec): Boolean = permissionNow(spec) &&
        (spec.account == null || spec.account == accountNow()) && System.currentTimeMillis() < spec.deadline
    override fun resolve(jobId: String, reply: (Result<CoreJobBinding>) -> Unit) {
        client.initialize { initialized ->
            if (initialized.isFailure) reply(Result.failure(initialized.exceptionOrNull()!!))
            else client.request("jobs.status", JSONObject().put("job_id", jobId), System.currentTimeMillis() + 10_000) { response ->
                reply(runCatching {
                    val j = response.getOrThrow().getJSONObject("result")
                    val data = j.getJSONObject("data")
                    val nested = data.optJSONObject("input")
                    val account = when {
                        data.has("account_id") && !data.isNull("account_id") -> data.getString("account_id")
                        nested != null && nested.has("account_id") && !nested.isNull("account_id") -> nested.getString("account_id")
                        else -> null
                    }
                    CoreJobBinding(j.getString("id"), j.getJSONObject("owner").getString("id"), account,
                        epochMillis(j.getString("run_at")),
                        epochMillis(data.getString("deadline_at")), j.getString("state"))
                })
            }
        }
    }
    override fun start(spec: WakeSpec, done: () -> Unit) {
        val run = Run(spec, done)
        if (running.putIfAbsent(spec.jobId, run) != null) { done(); return }
        client.beginLocal(spec.jobId)
        resolve(spec.jobId) { binding ->
            if (run.live.get()) advance(run, binding.getOrNull())
        }
    }
    private fun valid(spec: WakeSpec, binding: CoreJobBinding?): Boolean = binding != null &&
        binding.jobId == spec.jobId && binding.owner == spec.owner && binding.account == spec.account &&
        binding.runAt == spec.executeAt && binding.deadline == spec.deadline && authorize(spec)
    private fun execute(run: Run) {
        if (!run.live.get()) return
        val spec = run.spec
        if (System.currentTimeMillis() < spec.executeAt) {
            // RTC rollback must not execute a job before its declared time.
            run.timer.set(timer.schedule({ execute(run) }, minOf(1000, spec.executeAt - System.currentTimeMillis()), TimeUnit.MILLISECONDS))
            return
        }
        resolve(spec.jobId) { binding ->
            if (!run.live.get()) return@resolve
            advance(run, binding.getOrNull())
        }
    }
    private fun advance(run: Run, binding: CoreJobBinding?) {
        val spec = run.spec
        if (!valid(spec, binding)) { complete(run, "JobNotRunnable"); return }
        val prepare = prepareSession
        if (binding!!.state=="scheduled" && prepare!=null && run.prepared.compareAndSet(false,true)) {
            val resumed=AtomicBoolean(false)
            val resume:()->Unit={
                if(run.live.get() && resumed.compareAndSet(false,true)) resolve(spec.jobId) { refreshed ->
                    if(run.live.get()) advance(run,refreshed.getOrNull())
                }
            }
            try { prepare(spec,resume) } catch(_:Exception) { resume() }
            return
        }
        when (binding.state) {
            // Core's own scheduler may win the atomic claim. Follow it; never duplicate execution.
            "running" -> run.timer.set(timer.schedule({ execute(run) }, 250, TimeUnit.MILLISECONDS))
            "succeeded", "cancelled", "expired" -> complete(run, null)
            "scheduled" -> if (System.currentTimeMillis() < spec.executeAt) {
                run.timer.set(timer.schedule({ execute(run) }, spec.executeAt - System.currentTimeMillis(), TimeUnit.MILLISECONDS))
            } else {
            client.request("jobs.run", JSONObject().put("job_id", spec.jobId), spec.deadline) { response ->
                if (run.live.get()) {
                    val code = response.exceptionOrNull()?.let { (it as? PortError)?.code ?: "CoreJobFailed" }
                    if (code == "JobNotRunnable") run.timer.set(timer.schedule({ execute(run) }, 250, TimeUnit.MILLISECONDS))
                    else complete(run, code)
                }
            }
            }
            else -> complete(run, binding.state)
        }
    }
    private fun complete(run: Run, reason: String?) {
        if (!run.live.compareAndSet(true, false)) return
        running.remove(run.spec.jobId, run); run.timer.get()?.cancel(false)
        if (reason != null) onResumeRequired(run.spec, reason)
        run.done()
    }
    override fun cancel(jobId: String) {
        running[jobId]?.let { complete(it, null) }; client.cancelLocal(jobId)
    }
    override fun needsUserResume(spec: WakeSpec, reason: String) = onResumeRequired(spec, reason)
    override fun close() { running.keys.toList().forEach(::cancel); timer.shutdownNow() }
}

/** Optional C ABI client. The app owns engine/pump lifetime and supplies openOrGetEngine.
 * Native polling never blocks a UI thread. Cancelling local wait does not undo remote effects.
 */
class NativeCoreJobClient(private val openOrGetEngine: ((Result<Long>) -> Unit) -> Unit) : CoreJobClient, AutoCloseable {
    private val workers = Executors.newCachedThreadPool()
    private val operations = ConcurrentHashMap<String, Long>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val generations = ConcurrentHashMap<String, Long>()
    override fun beginLocal(jobId: String) { generations.merge(jobId, 1L, Long::plus); cancelled.remove(jobId) }
    override fun initialize(reply: (Result<Unit>) -> Unit) {
        workers.execute { openOrGetEngine { reply(it.map { Unit }) } }
    }
    override fun request(method: String, params: JSONObject, deadlineEpochMs: Long, reply: PortReply) {
        val job = params.optString("job_id")
        val generation = generations[job] ?: 0L
        openOrGetEngine { engine ->
            workers.execute {
                var operation: Long? = null
                try {
                    if (System.currentTimeMillis() >= deadlineEpochMs) throw PortError("DeadlineExceeded")
                    if (method == "jobs.run" && (job in cancelled || generation != (generations[job] ?: 0L))) throw PortError("Cancelled")
                    val bytes = JSONObject().put("id", java.util.UUID.randomUUID().toString()).put("method", method)
                        .put("params", params).toString().toByteArray(Charsets.UTF_8)
                    operation = NativeCore.request(engine.getOrThrow(), bytes)
                    if (method == "jobs.run") {
                        operations[job] = operation
                        if (job in cancelled || generation != (generations[job] ?: 0L)) NativeCore.cancel(operation)
                    }
                    val end = System.nanoTime() + (deadlineEpochMs - System.currentTimeMillis()).coerceIn(0, 55_000) * 1_000_000
                    while (System.nanoTime() < end) {
                        val result = NativeCore.poll(operation)
                        if (result != null) {
                            val response = JSONObject(result.toString(Charsets.UTF_8))
                            if (response.has("error")) throw PortError(response.getJSONObject("error").optString("code", "CoreJobFailed"))
                            reply(Result.success(response)); return@execute
                        }
                        Thread.sleep(10)
                    }
                    NativeCore.cancel(operation)
                    // Poll cancellation once consumed; any late operation is drained on this worker.
                    val drainEnd = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                    while (System.nanoTime() < drainEnd && NativeCore.poll(operation) == null) Thread.sleep(10)
                    throw PortError("NeedsReconciliation")
                } catch (e: Exception) { reply(Result.failure(if (e is PortError) e else PortError("CoreUnavailable"))) }
                finally { operation?.let { operations.remove(job, it) } }
            }
        }
    }
    override fun cancelLocal(jobId: String) { generations.merge(jobId, 1L, Long::plus); cancelled.add(jobId); operations[jobId]?.let { NativeCore.cancel(it) } }
    override fun close() { operations.keys.toList().forEach(::cancelLocal); workers.shutdown() }
}
