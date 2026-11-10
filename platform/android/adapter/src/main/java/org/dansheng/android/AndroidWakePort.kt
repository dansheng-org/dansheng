// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONObject

/** The application installs this at Application.onCreate in every process creation.
 * The implementation opens core on a worker, reloads current grants/account, claims the
 * persistent job once, and completes asynchronously. No policy/endpoints live here.
 */
interface WakeExecutionPort {
    fun activeAccount(): String?
    fun authorize(spec: WakeSpec): Boolean
    fun start(spec: WakeSpec, done: () -> Unit)
    fun cancel(jobId: String)
    fun needsUserResume(spec: WakeSpec, reason: String)
}

object AndroidRuntime { @Volatile var execution: WakeExecutionPort? = null }

class AndroidWakePort(private val context: Context) {
    companion object { private val claimLock = Any() }
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val prefs = context.getSharedPreferences("dansheng-wake-v1", Context.MODE_PRIVATE)
    private fun key(jobId: String) = "job:" + jobId
    private fun encode(s: WakeSpec) = JSONObject().put("job", s.jobId).put("account", s.account ?: JSONObject.NULL)
        .put("owner", s.owner).put("run_at", s.runAt).put("deadline", s.deadline).put("generation", s.generation)
        .put("execute_at", s.executeAt).put("precision", s.precision).toString()
    private fun decode(value: String): WakeSpec? = try {
        val j = JSONObject(value)
        WakeSpec(j.getString("job"), if (j.isNull("account")) null else j.getString("account"), j.getString("owner"),
            j.getLong("run_at"), j.getLong("deadline"), j.getString("generation"),
            j.optLong("execute_at", j.getLong("run_at")), j.optString("precision", "exact"))
    } catch (_: Exception) { null }
    fun load(jobId: String): WakeSpec? = prefs.getString(key(jobId), null)?.let(::decode)
    fun all(): List<WakeSpec> = prefs.all.values.filterIsInstance<String>().mapNotNull(::decode)
    fun capabilities(): JSONObject = JSONObject().put("exact_available", Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms())
        .put("inexact_available", true).put("inexact_background_fgs_guaranteed", false)
        .put("max_foreground_window_ms", 600_000)
        .put("exact_permission_requires_visible_ui", Build.VERSION.SDK_INT >= 31 && !alarms.canScheduleExactAlarms())
    fun claimed(spec: WakeSpec): Boolean = prefs.getString("claimed:" + spec.jobId, null) == spec.generation
    fun claim(spec: WakeSpec): Boolean = synchronized(claimLock) {
        if (load(spec.jobId)?.generation != spec.generation || prefs.getString("claimed:" + spec.jobId, null) == spec.generation) return@synchronized false
        prefs.edit().putString("claimed:" + spec.jobId, spec.generation).commit()
    }

    private fun pending(s: WakeSpec): PendingIntent {
        val uri = Uri.Builder().scheme("dansheng-wake").authority("job").appendPath(s.jobId)
            .appendPath(s.generation).build()
        return PendingIntent.getBroadcast(context, 0, Intent(context, WakeReceiver::class.java)
            .setData(uri).putExtra("job", s.jobId).putExtra("generation", s.generation),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** Called only after trusted host checks job ownership and explicit user authorization.
     * No inexact fallback: expose missing exact-alarm permission to the visible UI.
     */
    @Synchronized fun schedule(spec: WakeSpec) {
        spec.validate(System.currentTimeMillis())
        val execution = AndroidRuntime.execution ?: throw PortError("CapabilityUnavailable")
        if (!execution.authorize(spec) || (spec.account != null && execution.activeAccount() != spec.account)) throw PortError("PermissionDenied")
        if (spec.precision == "exact" && !capabilities().getBoolean("exact_available")) throw PortError("ExactAlarmPermissionRequired")
        load(spec.jobId)?.let { alarms.cancel(pending(it)) }
        if (!prefs.edit().putString(key(spec.jobId), encode(spec)).remove("claimed:" + spec.jobId).commit()) throw PortError("StorageError")
        try {
            val at = maxOf(System.currentTimeMillis() + 1, spec.runAt)
            if (spec.precision == "exact") alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(spec))
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(spec))
        } catch (_: SecurityException) {
            prefs.edit().remove(key(spec.jobId)).commit(); throw PortError("ExactAlarmPermissionRequired")
        }
    }

    @Synchronized fun cancel(jobId: String, owner: String) {
        val spec = load(jobId) ?: return
        if (owner != spec.owner) throw PortError("PermissionDenied")
        // Revoke persistent generation before stopping work; stale alarm intents become inert.
        if (!prefs.edit().remove(key(jobId)).remove("claimed:" + jobId).commit()) throw PortError("StorageError")
        alarms.cancel(pending(spec)); AndroidRuntime.execution?.cancel(jobId)
    }

    /** A restore must not erase a claim won by delivery during foreground/boot recovery. */
    fun rearmIfUnclaimed(spec:WakeSpec):Boolean = synchronized(claimLock) {
        val previous=load(spec.jobId)
        if(previous!=null && claimed(previous)) return@synchronized false
        schedule(spec)
        true
    }

    fun cancelAccount(account: String) {
        all().filter { it.account == account }.forEach { cancel(it.jobId, it.owner) }
    }

    fun deliver(jobId: String, generation: String) {
        val spec = load(jobId) ?: return
        if (spec.generation != generation) return
        if (System.currentTimeMillis() >= spec.deadline) { cancel(jobId, spec.owner); return }
        val execution = AndroidRuntime.execution ?: return // durable entry retained; no invented successful run
        if (!spec.mayRun(System.currentTimeMillis(), execution.activeAccount(), generation)) return
        if (!execution.authorize(spec)) { cancel(jobId, spec.owner); return }
        try {
            context.startForegroundService(Intent(context, DeadlineService::class.java)
                .putExtra("job", spec.jobId).putExtra("generation", spec.generation))
        } catch (_: Exception) { execution.needsUserResume(spec, "ForegroundStartUnavailable") }
    }

    /** Re-arm future, unclaimed subscriptions; never start a dataSync FGS FROM boot.
     * Missed or already claimed wakes require visible resumption/reconciliation.
     */
    fun restore() {
        all().forEach { spec ->
            val execution = AndroidRuntime.execution
            when {
                System.currentTimeMillis() >= spec.deadline -> cancel(spec.jobId, spec.owner)
                execution == null -> Unit // Application must install the host before restoring.
                claimed(spec) -> execution.needsUserResume(spec, "ProcessRestartRequiresReconciliation")
                (spec.account != null && execution.activeAccount() != spec.account) || !execution.authorize(spec) ->
                    execution.needsUserResume(spec, "AccountOrGrantUnavailable")
                spec.runAt <= System.currentTimeMillis() -> execution.needsUserResume(spec, "MissedWakeRequiresUserResume")
                else -> try { rearmIfUnclaimed(spec) } catch (e: PortError) { execution.needsUserResume(spec, e.code) }
            }
        }
    }
}

class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val job = intent.getStringExtra("job") ?: return
        val generation = intent.getStringExtra("generation") ?: return
        AndroidWakePort(context).deliver(job, generation)
    }
}

class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED))
            AndroidWakePort(context).restore()
    }
}
