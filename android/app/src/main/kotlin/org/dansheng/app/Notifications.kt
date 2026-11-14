// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.dansheng.android.WakeSpec
import org.dansheng.android.PlatformDispatcher
import org.dansheng.android.PortError
import org.dansheng.android.PortReply
import org.json.JSONObject

class Notifications(private val context: Context, private val accountNow:()->String?) : PlatformDispatcher {
    companion object {
        const val CHANNEL_JOBS = "dansheng-jobs"
        const val CHANNEL_ALERTS = "dansheng-alerts"
        const val NOTIFICATION_ID_RESUME = 7022
    }

    private val manager: NotificationManager by lazy {
        context.getSystemService(NotificationManager::class.java)
    }

    override val capabilities = setOf("notifications.show")
    override fun dispatch(capability:String,mediated:JSONObject,reply:PortReply) {
        try {
            if(capability !in capabilities)throw PortError("CapabilityUnavailable")
            val principal=mediated.getJSONObject("principal"); val grant=mediated.getJSONObject("grant"); val input=mediated.getJSONObject("input")
            val activity=input.optJSONObject("activity")
            val account=activity?.optString("account_id")?.takeIf { it.isNotBlank() && it!="null" }
                ?: input.optString("account_id").takeIf { it.isNotBlank() && it!="null" }
            if(account!=null && account!=accountNow()) throw PortError("PermissionDenied")
            if(principal.optString("kind")!="owner" || principal.optString("id")!="owner") {
                fun has(key:String,value:String)=grant.optJSONArray(key)?.let { a->(0 until a.length()).any { a.optString(it)==value } }==true
                val expiry=grant.optString("expires_at")
                if(!has("capabilities",capability) || (account!=null && !has("account_ids",account)) ||
                    (expiry.isNotEmpty() && expiry!="null" && java.time.OffsetDateTime.parse(expiry).toInstant().toEpochMilli()<=System.currentTimeMillis()))
                    throw PortError("PermissionDenied")
            }
            if(!manager.areNotificationsEnabled() || manager.getNotificationChannel(CHANNEL_ALERTS)?.importance==NotificationManager.IMPORTANCE_NONE)
                throw PortError("NotificationPermissionRequired")
            val key=input.optString("delivery_key").takeIf {it.isNotBlank()} ?: java.util.UUID.randomUUID().toString()
            val n=Notification.Builder(context,CHANNEL_ALERTS).setContentTitle("旦生提醒")
                .setContentText("有一条新的提醒，打开应用查看。").setSmallIcon(android.R.drawable.ic_dialog_info)
                .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true)
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                n.setContentIntent(PendingIntent.getActivity(context,0,it,PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
            manager.notify("core:"+key,1,n.build()); reply(Result.success(JSONObject().put("delivered",true)))
        } catch(e:Exception) { reply(Result.failure(if(e is PortError)e else PortError("NotificationUnavailable"))) }
    }

    fun ensureChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val jobsChannel = NotificationChannel(
                CHANNEL_JOBS,
                "定时任务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "正在后台执行的定时任务"
            }
            val alertsChannel = NotificationChannel(
                CHANNEL_ALERTS,
                "任务提醒",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "需要打开应用查看的结果"
            }
            manager.createNotificationChannel(jobsChannel)
            manager.createNotificationChannel(alertsChannel)
            manager.createNotificationChannel(NotificationChannel(PowerAlerts.CHANNEL,"寝室电量预警",NotificationManager.IMPORTANCE_DEFAULT)
                .apply{description="剩余电量达到设置阈值时提醒"})
        }
    }

    fun areNotificationsEnabled(): Boolean {
        return manager.areNotificationsEnabled()
    }

    fun isRuntimePermissionRequired(): Boolean {
        return Build.VERSION.SDK_INT >= 33 // TIRAMISU
    }

    /**
     * Notify user that a background job needs manual review / resumption.
     * Sanitized reason only; never log or display private payload, tokens or credentials.
     */
    fun notifyResumeRequired(spec: WakeSpec, reason: String) {
        val sanitizedMessage = when (reason) {
            "NeedsReconciliation" -> "上次提交结果未确定，请先核对"
            "AuthenticationRequired" -> "登录已失效，请重新验证账号"
            "ForegroundStartUnavailable" -> "系统限制了后台启动"
            "ProcessRestartRequiresReconciliation" -> "应用在执行中重启，请核对结果"
            "MissedWakeRequiresUserResume" -> "已错过执行时段，请查看任务"
            else -> "打开任务中心查看详情"
        }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("resume_job_id", spec.jobId)
        }

        val pendingIntent = if (launchIntent != null) {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            PendingIntent.getActivity(
                context,
                spec.jobId.hashCode(),
                launchIntent,
                flags
            )
        } else null

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ALERTS)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder.setContentTitle("Task Attention Required")
            .setContentText(sanitizedMessage)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setAutoCancel(true)

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        try {
            manager.notify(NOTIFICATION_ID_RESUME + (spec.jobId.hashCode() and 0x7FFF), builder.build())
        } catch (_: SecurityException) {
            // Notification permission denied
        }
    }
}
