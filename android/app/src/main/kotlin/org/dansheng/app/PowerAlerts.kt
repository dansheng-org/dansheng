package org.dansheng.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.app.job.JobService
import android.app.job.JobParameters
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import org.dansheng.android.PortError
import org.json.JSONObject

/** Android scheduling and delivery; Core owns threshold and episode state. */
internal class PowerAlerts(private val context:Context,private val rt:RuntimeHost){
    companion object {const val PERIODIC_JOB=7133;const val IMMEDIATE_JOB=7134;const val CHANNEL="dansheng-power-alerts"}
    private val running=AtomicBoolean(false)
    private val scheduler get()=context.getSystemService(JobScheduler::class.java)
    private val notices get()=context.getSystemService(NotificationManager::class.java)
    private fun checkAccount(account:String,epoch:Long){if(rt.account()!=account||rt.accountEpoch!=epoch)throw PortError("AccountChanged")}
    private fun state(account:String)=rt.request("fudan.electricity.alert.get",JSONObject().put("account_id",account)) as JSONObject
    fun status():JSONObject{
        val account=rt.account() ?: throw PortError("AccountRequired")
        return state(account).put("notifications_available",notificationsAllowed())
            .put("background_scheduled",scheduler.getPendingJob(PERIODIC_JOB)!=null)
    }
    fun configure(enabled:Boolean,threshold:Double):JSONObject=synchronized(rt.authGuard){
        val account=rt.account() ?: throw PortError("AccountRequired")
        if(enabled&&!notificationsAllowed())throw PortError("NotificationPermissionRequired")
        val result=rt.request("fudan.electricity.alert.set",JSONObject().put("account_id",account)
            .put("enabled",enabled).put("threshold_kwh",threshold)) as JSONObject
        schedule(result)
        if(enabled)requestCheck() else cancelNotice()
        status()
    }
    fun restore(){
        val account=rt.account()
        if(account==null){cancel();return}
        synchronized(rt.authGuard){if(rt.account()==account)schedule(state(account))}
    }
    private fun schedule(state:JSONObject){
        if(!state.optBoolean("enabled")){cancel();return}
        val interval=state.getLong("check_interval_seconds")*1000L
        val existing=scheduler.getPendingJob(PERIODIC_JOB)
        if(existing!=null&&existing.intervalMillis==interval&&existing.isPersisted)return
        val job=JobInfo.Builder(PERIODIC_JOB,ComponentName(context,PowerAlertJobService::class.java))
            .setPeriodic(interval).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPersisted(true).build()
        if(scheduler.schedule(job)!=JobScheduler.RESULT_SUCCESS)throw PortError("BackgroundScheduleUnavailable")
    }
    fun requestCheck(){
        val job=JobInfo.Builder(IMMEDIATE_JOB,ComponentName(context,PowerAlertJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).build()
        if(scheduler.schedule(job)!=JobScheduler.RESULT_SUCCESS)throw PortError("BackgroundScheduleUnavailable")
    }
    fun cancel(){scheduler.cancel(PERIODIC_JOB);scheduler.cancel(IMMEDIATE_JOB);cancelNotice()}
    private fun cancelNotice(){notices.cancel("electricity-low",7135)}
    fun notificationsAllowed():Boolean=notices.areNotificationsEnabled()&&
        notices.getNotificationChannel(CHANNEL)?.importance!=NotificationManager.IMPORTANCE_NONE
    fun check(active:()->Boolean={true}):JSONObject{
        if(!running.compareAndSet(false,true))return status()
        try{
            val account=rt.account() ?: throw PortError("AccountRequired")
            val epoch=rt.accountEpoch
            val args=JSONObject().put("account_id",account)
            var result=rt.request("fudan.electricity.alert.check",args) as JSONObject
            checkAccount(account,epoch)
            if(result.optString("last_error")=="AuthenticationRequired"&&active()){
                // Shared UIS vault and suspension guard; never prompt or delete a saved secret.
                synchronized(rt.authGuard){
                    checkAccount(account,epoch)
                    rt.campusLogins.savedUisForVenue(account)?.let { secret->
                        try{
                            rt.request("fudan.life.login",JSONObject().put("account_id",account).put("service","power").put("password",secret))
                            checkAccount(account,epoch)
                            rt.campusLogins.clearVenueSuspension(account)
                        }catch(e:PortError){
                            if(e.code=="InvalidCredentials")rt.campusLogins.suspendVenuePassword(account)
                            if(e.code=="Cancelled"||e.code=="AccountChanged")throw e
                        }
                    }
                }
                result=rt.request("fudan.electricity.alert.check",args) as JSONObject
            }
            if(!active()||Thread.currentThread().isInterrupted)return result
            synchronized(rt.authGuard){
                checkAccount(account,epoch)
                val fresh=state(account)
                val delivery=fresh.optString("pending_delivery").takeUnless {it.isBlank()||it=="null"}
                if(active()&&fresh.optBoolean("enabled")&&delivery!=null&&
                    fresh.opt("last_error") in listOf(null,JSONObject.NULL)&&notificationsAllowed()){
                    notifyLow(delivery)
                    rt.request("fudan.electricity.alert.ack",JSONObject().put("account_id",account).put("delivery_key",delivery))
                }
            }
            return status()
        }finally{running.set(false)}
    }
    internal fun notifyLow(delivery:String){
        val previous=notices.activeNotifications.firstOrNull{it.tag=="electricity-low"&&it.id==7135}
        if(previous!=null&&previous.notification.extras.getString("delivery_key")!=delivery)cancelNotice()
        val launch=context.packageManager.getLaunchIntentForPackage(context.packageName) ?: throw PortError("NotificationUnavailable")
        launch.flags=Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        val pending=PendingIntent.getActivity(context,7135,launch,PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val note=Notification.Builder(context,CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("寝室电量预警").setContentText("剩余电量已达到预警阈值，打开应用查看。")
            .setContentIntent(pending).setAutoCancel(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setExtras(android.os.Bundle().apply{putString("delivery_key",delivery)}).build()
        notices.notify("electricity-low",7135,note)
    }
    fun openNotificationSettings(){
        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
class PowerAlertJobService:JobService(){
    private data class Work(val active:AtomicBoolean,val thread:Thread)
    private val work=ConcurrentHashMap<Int,Work>()
    override fun onStartJob(params:JobParameters):Boolean{
        val active=AtomicBoolean(true)
        val thread=Thread({
            try{(application as DanshengApplication).runtime.powerAlerts.check{active.get()}}
            catch(_:Exception){/* Core retains check status; no background UI or fake zero. */}
            finally{
                work.computeIfPresent(params.jobId){_,current->if(current.active===active)null else current}
                if(active.get())jobFinished(params,false)
            }
        },"electricity-alert-check")
        work[params.jobId]=Work(active,thread);thread.start();return true
    }
    override fun onStopJob(params:JobParameters):Boolean{
        work.remove(params.jobId)?.let{it.active.set(false);it.thread.interrupt()};return true
    }
}
