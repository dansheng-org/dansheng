// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Activity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.dansheng.android.Authority
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

/** A first-party campus service. Only its adapter uses the mediated JS execution API. */
class CampusVenueHost(private val activity:Activity, private val runtime:RuntimeHost,
    private val sheet:ModernSheet=ModernSheet(activity)) {
    companion object {
        const val BUILTIN_PLUGIN_ID="official.fudan-venues"
        private val installLock=Any()
    }
    private val names=listOf("manifest.json","api.mjs","main.mjs","policy.mjs","host-policy.json","NOTICE.md","LICENSE")
    private val assets by lazy { names.associateWith { path ->
        try { activity.assets.open("builtin-venues/"+path).use { it.readBytes() } }
        catch(_:java.io.IOException){throw PortError("BuiltinAssetsMissing")}
    } }
    private val digest by lazy {
        val md=MessageDigest.getInstance("SHA-256")
        for(n in names.sorted()){md.update(n.toByteArray());md.update(0.toByte());md.update(MessageDigest.getInstance("SHA-256").digest(assets.getValue(n)))}
        md.digest().joinToString(""){"%02x".format(it)}
    }
    private val manifest by lazy {JSONObject(assets.getValue("manifest.json").toString(Charsets.UTF_8))}
    private val policy by lazy {JSONObject(assets.getValue("host-policy.json").toString(Charsets.UTF_8))}
    private val binding get()=activity.getSharedPreferences("builtin-venue-receipt",0)
    private fun ensureService(account:String)=synchronized(installLock) {
        if(runtime.account()!=account)throw PortError("AccountChanged")
        if(manifest.getString("id")!=BUILTIN_PLUGIN_ID)throw PortError("InvalidBuiltinPackage")
        val rows=runtime.request("plugins.list") as JSONArray
        val row=(0 until rows.length()).map{rows.getJSONObject(it)}.find{it.optString("id")==BUILTIN_PLUGIN_ID}
        val params=JSONObject().put("plugin_id",BUILTIN_PLUGIN_ID)
        val changed=row==null || binding.getString("digest","")!=digest ||
            PortUtils.canonicalJson(row.opt("manifest"))!=PortUtils.canonicalJson(manifest)
        if(changed){
            runtime.revoke(BUILTIN_PLUGIN_ID)
            val stage=Files.createTempDirectory(activity.cacheDir.toPath(),"venue-service-").toFile()
            try {
                for((name,bytes) in assets)File(stage,name).writeBytes(bytes)
                runtime.request("plugins.install",JSONObject().put("path",stage.absolutePath))
            }finally{stage.deleteRecursively()}
        }
        if(changed || row?.optBoolean("enabled")!=true || binding.getString("account","")!=account || runtime.grantGate.isRevoked(BUILTIN_PLUGIN_ID)){
            runtime.bindPackage(BUILTIN_PLUGIN_ID,manifest,policy,digest)
            val grant=JSONObject().put("capabilities",manifest.getJSONArray("capabilities"))
                .put("origins",manifest.getJSONArray("network")).put("account_ids",JSONArray().put(account))
            runtime.request("permissions.set",JSONObject().put("subject","plugin:"+BUILTIN_PLUGIN_ID).put("grant",grant))
            runtime.request("plugins.enable",params)
            runtime.activate(BUILTIN_PLUGIN_ID)
            check(binding.edit().putString("digest",digest).putString("account",account).commit())
        }
    }
    private fun run(action:String,input:JSONObject)=runtime.request("plugins.run",JSONObject()
        .put("plugin_id",BUILTIN_PLUGIN_ID).put("action",action).put("input",input))
    // Concurrent reads and the login button must never start two hidden logins.
    private val restoreLock=Mutex()
    private fun restorable(e:PortError,account:String)=e.code=="AuthenticationRequired" &&
        runtime.campusLogins.canRestoreVenue(account) && !runtime.visiblePage.silentBlocked(account)
    /** Only reads come through here: a mutating run is never retried. Shows no UI; a failure reaches Flutter's login button. */
    private suspend fun read(action:String,input:JSONObject,account:String):Any? {
        try{return run(action,input)}catch(e:PortError){if(!restorable(e,account))throw e}
        restoreLock.withLock {
            // A concurrent read may already have restored the session.
            try{return run(action,input)}catch(e:PortError){if(!restorable(e,account))throw e}
            restoreSilently(account)
        }
        return run(action,input)
    }
    private suspend fun restoreSilently(account:String) {
        repeat(3) {
            try {runtime.visiblePage.withoutPromptSuspending(account){foregroundLogin(account)};return}
            // Raised before any page exists: a request is in flight or another handoff owns the page.
            catch(e:PortError){if(e.code!="AccountBusy")throw e}
            delay(500)
        }
    }
    // loginFromUser is the only path that replaces an expired session while keeping viable
    // campus cookies; run("visibleLogin") returns early when a stale session object exists.
    private suspend fun foregroundLogin(account:String):JSONObject {
        val principal="plugin:$BUILTIN_PLUGIN_ID"
        if("browser.login" !in runtime.compositeDispatcher.capabilities || !runtime.grantGate.trustedVenueLogin(principal))throw PortError("PermissionDenied")
        val grant=runtime.request("permissions.get",JSONObject().put("subject",principal)) as JSONObject
        fun set(field:String)=grant.optJSONArray(field)?.let { a->(0 until a.length()).map(a::getString).toSet() } ?: emptySet()
        val authority=Authority(principal,false,set("capabilities"),set("account_ids"),set("origins"),
            grant.optString("expires_at").takeUnless {it.isEmpty() || it=="null"}?.let {java.time.Instant.parse(it).toEpochMilli()})
        val reply=CompletableDeferred<Result<JSONObject>>()
        runtime.browserPort.loginFromUser(authority,account,"https://booking.fudan.edu.cn/reservation/fe/site/special/special?id=48"){reply.complete(it)}
        val result=reply.await().getOrThrow()
        if(runtime.account()!=account || !runtime.grantGate.trustedVenueLogin(principal))throw PortError("AccountChanged")
        return result
    }
    suspend fun call(action:String,params:JSONObject):Any?=withContext(Dispatchers.IO){
        val account=runtime.account() ?: throw PortError("AccountRequired")
        ensureService(account)
        val input=JSONObject(params.toString()).put("account_id",account)
        when(action.removePrefix("venues.")){
            "visibleLogin"->if(runtime.visiblePage.hasForeground())restoreLock.withLock{foregroundLogin(account)} else run("visibleLogin",input)
            "venues","calendar","appointments","detail","journal","prepareCancel"->read(action.removePrefix("venues."),input,account)
            "pending"->pending(account)
            "reconcile"->{
                val task=input.getString("task_id")
                val result=run("reconcile",input) as JSONObject
                if(result.optString("status")=="reconciled_success" && result.optLong("appointment_id")>0){
                    val rows=pending(account)
                    for(i in 0 until rows.length()){
                        val row=rows.getJSONObject(i)
                        if(row.optString("task_id")==task){
                            runtime.request("jobs.reconcile",JSONObject().put("job_id",row.getString("id"))
                                .put("outcome","succeeded").put("evidence",JSONObject().put("task_id",task)
                                    .put("appointment_id",result.getLong("appointment_id")).put("source","authenticated_appointments")))
                        }
                    }
                }
                result
            }
            "reconcileCancel"->{
                val appointment=input.getLong("appointment_id")
                val result=run("reconcileCancel",JSONObject().put("account_id",account).put("appointment_id",appointment)) as JSONObject
                if(result.optString("status")=="reconciled_cancelled" && result.optLong("appointment_id")==appointment) {
                    val rows=pending(account)
                    for(i in 0 until rows.length()){
                        val row=rows.getJSONObject(i)
                        if(row.optString("action")=="cancel" && row.optLong("appointment_id")==appointment)
                            runtime.request("jobs.reconcile",JSONObject().put("job_id",row.getString("id")).put("outcome","succeeded")
                                .put("evidence",JSONObject().put("source","authenticated_appointments").put("cancelled_id",appointment)))
                    }
                }
                result
            }
            "cancel"->{
                val prepared=read("prepareCancel",JSONObject().put("account_id",account).put("appointment_id",input.getLong("appointment_id")),account) as JSONObject
                val canonical=prepared.getJSONObject("canonical_input")
                val args=JSONObject().put("plugin_id",BUILTIN_PLUGIN_ID).put("action","cancel").put("input",canonical)
                val hash=(runtime.request("actions.preview",args) as JSONObject).getString("input_sha256")
                sheet.confirm("取消这条预约？",prepared.getString("summary"),"取消预约")
                if(runtime.account()!=account)throw PortError("AccountChanged")
                runtime.recordConsent(BUILTIN_PLUGIN_ID,"cancel",canonical,hash)
                run("cancel",canonical)
            }
            "prepareManual"->{
                if(!input.has("task_id") || input.optString("task_id").isBlank())input.put("task_id","manual-"+java.util.UUID.randomUUID())
                run("prepareManual",input)
            }
            "reserve"->{
                // Never take user-facing review text or request fields on trust from Dart.
                val proposed=JSONObject((input.optJSONObject("canonical_input") ?: input).toString()).put("account_id",account)
                val prepared=run("prepareManual",proposed) as? JSONObject ?: throw PortError("InvalidPreview")
                val canonical=prepared.getJSONObject("canonical_input")
                val slots=(read("calendar",canonical,account) as JSONObject).getJSONArray("slots")
                val selected=(0 until slots.length()).map { slots.getJSONObject(it) }.find {
                    it.getInt("period_id")==canonical.getInt("period_id") && it.getInt("court_id")==canonical.getInt("court_id") &&
                        it.optString("time")==canonical.optString("time")
                } ?: throw PortError("SlotUnavailable")
                if(!selected.getBoolean("available"))throw PortError("CourtOccupied")
                val args=JSONObject().put("plugin_id",BUILTIN_PLUGIN_ID).put("action","reserve").put("input",canonical)
                val preview=runtime.request("actions.preview",args) as JSONObject
                val hash=preview.getString("input_sha256")
                if(input.has("input_sha256") && input.getString("input_sha256")!=hash)throw PortError("PreviewChanged")
                sheet.confirm("确认场馆预约",prepared.getString("summary"),"确认预约")
                if(runtime.account()!=account)throw PortError("AccountChanged")
                if((runtime.request("actions.preview",args) as JSONObject).getString("input_sha256")!=hash)throw PortError("PreviewChanged")
                runtime.recordConsent(BUILTIN_PLUGIN_ID,"reserve",canonical,hash)
                run("reserve",canonical)
            }
            else->throw PortError("MethodUnavailable")
        }
    }
    private fun pending(account:String):JSONArray {
        val jobs=runtime.request("jobs.status") as JSONArray
        val out=JSONArray()
        for(i in 0 until jobs.length()){
            val j=jobs.getJSONObject(i);val data=j.optJSONObject("data") ?: continue
            val input=data.optJSONObject("input") ?: continue
            if(data.optString("plugin_id")!=BUILTIN_PLUGIN_ID || data.optString("action") !in setOf("reserve","cancel") ||
                input.optString("account_id")!=account || j.optString("state")!="needs_reconciliation")continue
            out.put(JSONObject().put("id",j.getString("id")).put("action",data.getString("action")).put("task_id",input.optString("task_id"))
                .put("appointment_id",input.optLong("appointment_id"))
                .put("target_date",input.optString("target_date")).put("time",input.optString("time")))
        }
        return out
    }
}
