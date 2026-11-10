// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean

/** Loaded from core jobs.status, never from the platform call's claimed owner/account. */
data class CoreJobBinding(val jobId: String, val owner: String, val account: String?,
    val runAt: Long, val deadline: Long, val state: String)

interface JobBindingResolver {
    fun resolve(jobId: String, reply: (Result<CoreJobBinding>) -> Unit)
}

/** Host-internal platform calls. Install only behind the trusted C queue, never plugin APIs.
 * Supports the raw core shape and the normal principal/grant/input mediation shape.
 */
class JobWakeDispatcher(context: Context, private val resolver: JobBindingResolver) : PlatformDispatcher {
    private val wake = AndroidWakePort(context.applicationContext)
    private val handler = Handler(Looper.getMainLooper())
    override val capabilities = setOf("jobs.wake.schedule", "jobs.wake.cancel", "jobs.wake.status")
    override fun dispatch(capability: String, mediated: JSONObject, reply: PortReply) {
        val complete = AtomicBoolean(false)
        val timeout = Runnable {
            if (complete.compareAndSet(false, true)) reply(Result.failure(PortError("WakeBindingTimeout")))
        }
        handler.postDelayed(timeout, 45_000)
        fun finish(result: Result<JSONObject>) {
            if (complete.compareAndSet(false, true)) { handler.removeCallbacks(timeout); reply(result) }
        }
        try {
            if (capability !in capabilities) throw PortError("CapabilityUnavailable")
            val input = if (mediated.has("principal")) mediated.getJSONObject("input") else mediated
            if (capability == "jobs.wake.status") {
                checkAuthority(capability, mediated, null)
                finish(Result.success(wake.capabilities())); return
            }
            val job = input.getString("job_id")
            if (job.isBlank() || job.length > 200) throw PortError("InvalidWake")
            // Core may already have removed/disabled the job before cancelling its wake.
            // Raw calls are internal; use the previously trusted persisted binding and
            // avoid a reentrant core lookup just to remove an alarm. Mediated callers
            // still require the full owner/grant lookup below.
            if (capability == "jobs.wake.cancel" && !mediated.has("principal")) {
                wake.load(job)?.let { saved ->
                    if (input.has("account_id") && !input.isNull("account_id") && input.getString("account_id") != saved.account)
                        throw PortError("PermissionDenied")
                    wake.cancel(job, saved.owner)
                }
                finish(Result.success(JSONObject().put("job_id", job).put("cancelled", true))); return
            }
            resolver.resolve(job) { resolved ->
                if (!complete.get()) try {
                    val binding = resolved.getOrThrow()
                    if (binding.jobId != job || binding.owner.isBlank()) throw PortError("PermissionDenied")
                    checkAuthority(capability, mediated, binding)
                    if (input.has("account_id") && !input.isNull("account_id") && input.getString("account_id") != binding.account)
                        throw PortError("PermissionDenied")
                    if (capability == "jobs.wake.cancel") {
                        wake.cancel(job, binding.owner)
                        finish(Result.success(JSONObject().put("job_id", job).put("cancelled", true)))
                    } else {
                        val run = instant(input, "run_at")
                        val deadline = instant(input, "deadline_at")
                        val prepare = if (input.has("prepare_at") && !input.isNull("prepare_at")) instant(input, "prepare_at") else run
                        // Do not extend/re-time a job using untrusted schedule parameters.
                        if (run != binding.runAt || deadline != binding.deadline || binding.state != "scheduled") throw PortError("JobNotRunnable")
                        val precision = input.optString("precision", "exact")
                        val spec = WakeSpec(job, binding.account, binding.owner, prepare, deadline,
                            executeAt = run, precision = precision)
                        wake.schedule(spec)
                        finish(Result.success(JSONObject().put("job_id", job).put("scheduled", true)
                            .put("precision", precision).put("exact", precision == "exact")
                            .put("wake_at", Instant.ofEpochMilli(prepare).toString())
                            .put("run_at", Instant.ofEpochMilli(run).toString())
                            .put("deadline_at", Instant.ofEpochMilli(deadline).toString())
                            .put("capabilities", wake.capabilities())))
                    }
                } catch (e: Exception) { finish(Result.failure(if (e is PortError) e else PortError("InvalidWake"))) }
            }
        } catch (e: Exception) { finish(Result.failure(if (e is PortError) e else PortError("InvalidWake"))) }
    }
    private fun instant(input: JSONObject, field: String): Long = try { epochMillis(input.getString(field)) }
        catch (_: Exception) { throw PortError("InvalidWake") }

    private fun checkAuthority(capability: String, envelope: JSONObject, binding: CoreJobBinding?) {
        if (!envelope.has("principal")) return // Core-internal port; never forward arbitrary client calls here.
        val p = envelope.getJSONObject("principal")
        if (p.optString("kind") == "owner" && p.optString("id") == "owner") return
        val g = envelope.getJSONObject("grant")
        fun contains(field: String, value: String): Boolean = g.optJSONArray(field)?.let { a ->
            (0 until a.length()).any { a.optString(it) == value } } ?: false
        val expiry = g.optString("expires_at").takeIf { it.isNotEmpty() && it != "null" }
        if (!contains("capabilities", capability) ||
            (expiry != null && epochMillis(expiry) <= System.currentTimeMillis()) ||
            (binding != null && binding.owner != p.optString("id")) ||
            (binding?.account != null && !contains("account_ids", binding.account))) throw PortError("PermissionDenied")
    }
}
