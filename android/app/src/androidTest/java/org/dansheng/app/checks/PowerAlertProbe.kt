package org.dansheng.app.checks

import android.app.Instrumentation
import android.app.NotificationManager
import android.app.job.JobScheduler
import android.os.Bundle
import org.dansheng.app.PowerAlerts
import org.dansheng.app.RuntimeHost
import org.json.JSONObject
import java.io.FileInputStream

internal fun verifyPowerAlertPlatform(test:Instrumentation,rt:RuntimeHost,out:Bundle){
    val scheduler=test.targetContext.getSystemService(JobScheduler::class.java)
    val manager=test.targetContext.getSystemService(NotificationManager::class.java)
    rt.request("fudan.electricity.alert.set",JSONObject().put("account_id",rt.account())
        .put("enabled",true).put("threshold_kwh",5.0))
    rt.powerAlerts.restore()
    val job=scheduler.getPendingJob(PowerAlerts.PERIODIC_JOB) ?: error("MissingPeriodicJob")
    check(job.intervalMillis==3600000L&&job.isPersisted)
    out.putString("power_job","hourly_persisted")
    rt.powerAlerts.configure(false,5.0)
    rt.powerAlerts.notifyLow("synthetic-first")
    rt.powerAlerts.notifyLow("synthetic-first")
    fun notices()=manager.activeNotifications.filter{it.tag=="electricity-low"}
    check(notices().size==1)
    rt.powerAlerts.notifyLow("synthetic-next")
    check(notices().single().notification.extras.getString("delivery_key")=="synthetic-next")
    rt.powerAlerts.cancel()
    check(notices().isEmpty())
    out.putString("power_notification_platform","posted_replaced_cleared")
}

internal fun verifyRealPowerAlertJob(test:Instrumentation,rt:RuntimeHost,out:Bundle){
    val account=rt.account() ?: error("MissingAccount")
    val manager=test.targetContext.getSystemService(NotificationManager::class.java)
    fun state()=rt.request("fudan.electricity.alert.get",JSONObject().put("account_id",account)) as JSONObject
    fun force(){
        test.uiAutomation.executeShellCommand("cmd jobscheduler run -f org.dansheng.app 7133").use{
            FileInputStream(it.fileDescriptor).use { input -> input.readBytes() }
        }
    }
    fun waitFor(predicate:(JSONObject)->Boolean):JSONObject{
        val deadline=System.currentTimeMillis()+110000
        while(System.currentTimeMillis()<deadline){
            val current=state()
            if(predicate(current))return current
            Thread.sleep(500)
        }
        val current=state()
        out.putString("power_background_error",current.optString("last_error").takeUnless{it.isBlank()||it=="null"}?:"Timeout")
        return current
    }
    val before=state().optLong("last_notified_ms")
    rt.powerAlerts.configure(true,100000.0)
    try{
        force()
        val first=waitFor{it.optLong("last_notified_ms")>before}
        if(first.optLong("last_notified_ms")<=before)return
        check(manager.activeNotifications.count{it.tag=="electricity-low"}==1)
        val checked=first.getLong("last_checked_ms")
        val notified=first.getLong("last_notified_ms")
        Thread.sleep(300)
        force()
        val second=waitFor{it.optLong("last_checked_ms")>checked&&it.opt("last_error") in listOf(null,JSONObject.NULL)}
        check(second.optLong("last_checked_ms")>checked)
        check(second.getLong("last_notified_ms")==notified)
        check(manager.activeNotifications.count{it.tag=="electricity-low"}==1)
        out.putString("power_background_read","ok")
        out.putString("power_background_notification","delivered_once")
    }finally{rt.powerAlerts.configure(false,5.0)}
}
