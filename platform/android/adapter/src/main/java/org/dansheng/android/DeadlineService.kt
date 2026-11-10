// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock

/** Generic bounded job lifecycle; sports timings, selection, retry and URLs belong to plugins. */
class DeadlineService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val running = mutableMapOf<String, Pair<WakeSpec, Deadline>>()
    private var lock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val wake = AndroidWakePort(this)
        val spec = intent?.getStringExtra("job")?.let(wake::load)
        val execution = AndroidRuntime.execution
        if (spec == null || execution == null || !execution.authorize(spec) ||
            !spec.mayRun(System.currentTimeMillis(), execution.activeAccount(), intent.getStringExtra("generation"))) {
            if (running.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        if (running.containsKey(spec.jobId)) return START_NOT_STICKY
        if (!wake.claim(spec)) {
            execution.needsUserResume(spec, "PreviouslyClaimedRequiresReconciliation")
            if (running.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("dansheng-jobs", "Scheduled work", NotificationManager.IMPORTANCE_LOW))
        val notification = Notification.Builder(this, "dansheng-jobs").setContentTitle("Scheduled work active")
            .setContentText("Open the application to review or stop work")
            .setSmallIcon(android.R.drawable.ic_popup_sync).setOngoing(true).build()
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            startForeground(7021, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(7021, notification)
        }
        val deadline = Deadline(spec.deadline, System.currentTimeMillis(), SystemClock.elapsedRealtime())
        running[spec.jobId] = spec to deadline
        if (lock == null) lock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dansheng:deadline").apply {
                setReferenceCounted(false); acquire(600_000)
            }
        handler.removeCallbacks(check); handler.post(check)
        try { execution.start(spec) { handler.post { finish(spec.jobId, false) } } }
        catch (_: Exception) { finish(spec.jobId, true) }
        return START_NOT_STICKY
    }
    private val check = object : Runnable {
        override fun run() {
            val wake = AndroidWakePort(this@DeadlineService)
            running.toMap().forEach { (id, pair) ->
                val (spec, deadline) = pair
                val execution = AndroidRuntime.execution
                if (execution == null || !execution.authorize(spec) ||
                    !spec.mayRun(System.currentTimeMillis(), execution.activeAccount(), wake.load(id)?.generation) ||
                    deadline.remaining(System.currentTimeMillis(), SystemClock.elapsedRealtime()) == 0L) finish(id, true)
            }
            if (running.isNotEmpty()) handler.postDelayed(this, 100)
        }
    }
    private fun finish(id: String, cancel: Boolean) {
        if (running.remove(id) == null) return
        if (cancel) AndroidRuntime.execution?.cancel(id)
        if (running.isEmpty()) {
            lock?.let { if (it.isHeld) it.release() }; lock = null
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        }
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        running.keys.toList().forEach { finish(it, true) }; stopSelf()
    }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        running.keys.toList().forEach { AndroidRuntime.execution?.cancel(it) }; running.clear()
        lock?.let { if (it.isHeld) it.release() }; lock = null
        super.onDestroy()
    }
}
