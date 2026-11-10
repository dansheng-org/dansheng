package org.dansheng.app.checks

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.Process
import org.dansheng.app.DanshengApplication
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Instant
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Runs in the real product process; cases contain only synthetic data. */
class ProductRunner : Instrumentation() {
    override fun newApplication(cl:ClassLoader,className:String,context:android.content.Context):android.app.Application {
        if(className==DanshengApplication::class.java.name) {
            return super.newApplication(OfflineApplication::class.java.classLoader,OfflineApplication::class.java.name,context)
        }
        return super.newApplication(cl,className,context)
    }
    private lateinit var options:Bundle
    private val rt get()=(targetContext.applicationContext as DanshengApplication).runtime
    private val account="fixture-account"
    override fun onCreate(arguments:Bundle?) { options=arguments ?: Bundle(); start() }
    private fun args(vararg items:Pair<String,Any?>)=JSONObject().also { j->items.forEach{j.put(it.first,it.second)} }
    private fun setup(folder:String):String {
        val dir=File(targetContext.cacheDir,"qa-packages/"+folder).apply{mkdirs()}
        for(file in context.assets.list(folder) ?: emptyArray()) {
            context.assets.open(folder+"/"+file).use { src->File(dir,file).outputStream().use(src::copyTo) }
        }
        val m=JSONObject(File(dir,"manifest.json").readText()); val id=m.getString("id")
        val p=args("plugin_id" to id)
        val installed=rt.request("plugins.install",args("path" to dir.absolutePath)) as JSONObject
        check(!installed.getBoolean("enabled"))
        rt.bindPackage(id,m,null,org.dansheng.app.PackageImport.digest(File(dir,"manifest.json")))
        val disabled=runCatching{plugin(id, m.getJSONObject("actions").keys().next(),args("account_id" to account))}
        check(disabled.exceptionOrNull() is PortError)
        rt.request("permissions.set",args("subject" to "plugin:"+id,"grant" to args("account_ids" to JSONArray().put(account),
            "origins" to m.getJSONArray("network"),"capabilities" to m.getJSONArray("capabilities"),"allow_private_network" to (folder=="closed-loop"))))
        rt.request("plugins.enable",p); rt.activate(id)
        return id
    }
    private fun plugin(id:String,action:String,input:JSONObject):Any? =
        rt.request("plugins.run",args("plugin_id" to id,"action" to action,"input" to input))
    override fun onStart() {
        val output=Bundle().apply{putInt("pid",Process.myPid())}; var step="initialization"
        try {
            val phase=options.getString("phase") ?: "seed"
            val input=args("account_id" to account)
            step="open"; val info=rt.request("core.info") as JSONObject; check(info.length()>0)
            when(phase) {
                "workbench" -> { step="manual venue + optional scheduled extension"; CampusWorkbenchProbe.run(this,rt,output) }
                "agentProbe" -> { step="authenticated loopback MCP"; runAgentProbe(targetContext,rt) }
                "campusData" -> { step="calendar and private course-file reader";verifyCampusData(this,rt,output) }
                "coldVenueSeed" -> {
                    val active=rt.account()!!
                    check(active.startsWith("fixture-sports-") && rt.grantGate.trustedVenueLogin("plugin:official.fudan-sports"))
                    rt.vault.set("campus-login/v1/uis/$active",JSONObject().put("email","").put("secret","fixture-only").toString())
                    targetContext.getSharedPreferences("cold-fixture",0).edit().putInt("seed_pid",Process.myPid()).commit()
                }
                "coldVenueRestore" -> {
                    val active=rt.account()!!
                    check(active.startsWith("fixture-sports-") && targetContext.getSharedPreferences("cold-fixture",0).getInt("seed_pid",0)!=Process.myPid())
                    step="recover signed venue session without an Activity"
                    rt.attach(null)
                    OfflineApplication.setSyntheticIdentity(active)
                    fun read(action:String)=rt.request("plugins.run",JSONObject().put("plugin_id","official.fudan-sports").put("action",action)
                        .put("input",JSONObject().put("account_id",active)))
                    val login=try {rt.visiblePage.withoutPrompt(active){read("visibleLogin")} as JSONObject}
                    catch(e:PortError){output.putString("cold_probe",OfflineApplication.lastProbeCode);output.putBoolean("trusted",rt.grantGate.trustedVenueLogin("plugin:official.fudan-sports"));output.putBoolean("saved",rt.campusLogins.canRestoreVenue(active));throw e}
                    check(login.optBoolean("authenticated") && login.optString("account_id")==active)
                    check((read("venueOptions") as JSONArray).length()>0)
                    val posts=CompletableFuture<String>()
                    runOnMainSync { OfflineApplication.lastLoadedWebView!!.evaluateJavascript("window.fixtureCalls.filter(c=>c.method==='POST').length") { posts.complete(it) } }
                    check(posts.get(4,TimeUnit.SECONDS)=="0")
                    rt.vault.delete("campus-login/v1/uis/$active")
                    output.putString("cold_venue_session","authenticated_without_visible_activity")
                    output.putInt("cold_venue_posts",0)
                }
                "ports" -> {
                    step="Keystore corrupt ciphertext"
                    val vault=rt.vault; val key="qa-vault-"+java.util.UUID.randomUUID()
                    val prefs=targetContext.getSharedPreferences("dansheng-vault-v1",0); val previous=prefs.all.keys.toSet()
                    try {
                        vault.set(key,"synthetic-only"); check(vault.get(key)=="synthetic-only")
                        val entry=(prefs.all.keys-previous).single()
                        check(prefs.edit().putString(entry,"corrupted-fixture").commit())
                        check(runCatching{vault.get(key)}.exceptionOrNull() is PortError)
                    } finally { vault.delete(key) }
                    if(android.os.Build.VERSION.SDK_INT>=33) {
                        step="notification permission denied"
                        check(!rt.permissions().getBoolean("notifications_available"))
                        val denied=runCatching{rt.request("notifications.show",JSONObject())}.exceptionOrNull()
                        check((denied as? PortError)?.code=="NotificationPermissionRequired")
                    }
                    step="foreground service start denied (injected)"
                    val blocked=object:android.content.ContextWrapper(targetContext){
                        override fun startForegroundService(service:android.content.Intent):android.content.ComponentName? {
                            throw IllegalStateException("synthetic background-start denial")
                        }
                    }
                    val wake=org.dansheng.android.AndroidWakePort(blocked)
                    val id="qa-denied-"+java.util.UUID.randomUUID()
                    val now=System.currentTimeMillis()
                    val spec=org.dansheng.android.WakeSpec(id,null,"owner",now-1,now+5000,precision="inexact")
                    try {
                        wake.schedule(spec); wake.deliver(id,spec.generation)
                        check(!wake.claimed(spec))
                        check(targetContext.getSharedPreferences("dansheng-app-state-v1",0)
                            .getString("resume:"+id,null)=="ForegroundStartUnavailable")
                        output.putString("injected_fgs_denial","needs_user_resume")
                    } finally { wake.cancel(id,"owner") }
                }
                "seedClock" -> {
                    step="install local wake fixture"
                    rt.setAccount(account); setup("local-clock")
                }
                "seed" -> {
                    step="fresh"; val pre=rt.request("plugins.list") as JSONArray
                    check((0 until pre.length()).none{pre.getJSONObject(it).getString("id")=="official.fudan-sports"})
                    rt.setAccount(account)
                    rt.request("accounts.upsert",args("account_id" to account,"label" to "Synthetic","provider" to "fixture"))
                    step="install"; val id=setup("closed-loop"); setup("local-clock")
                    step="sync without session"; val missing=plugin(id,"sync",input) as JSONObject
                    check(missing.getString("status")=="auth_required")
                    step="local session"; rt.request("auth.session.set",args("account_id" to account,"origin" to "http://127.0.0.1:19765",
                        "bearer" to "synthetic-fixture-bearer","persist" to false))
                    val received=CompletableFuture<Boolean>()
                    ServerSocket(19765,1,InetAddress.getByName("127.0.0.1")).use{server->
                        server.soTimeout=15000
                        Thread {
                            try {
                                server.accept().use { conn->
                                    conn.soTimeout=10000; val reader=conn.getInputStream().bufferedReader()
                                    val path=reader.readLine(); var auth=false
                                    while(true){ val line=reader.readLine() ?: break; if(line.isEmpty())break
                                        if(line.equals("authorization: Bearer synthetic-fixture-bearer",true))auth=true }
                                    val body="""{"account_id":"fixture-account","id":"course-1","title":"Synthetic course","count":2}"""
                                    val wire="HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "+body.length+"\r\n\r\n"+body
                                    conn.getOutputStream().write(wire.toByteArray()); conn.getOutputStream().flush()
                                    received.complete(auth && path.startsWith("GET /fixture "))
                                }
                            } catch(e:Exception){received.completeExceptionally(e)}
                        }.start()
                        step="authenticated fixture GET"; check((plugin(id,"sync",input) as JSONObject).getString("status")=="synced")
                        check(received.get(5,TimeUnit.SECONDS))
                    }
                    step="card"; val card=rt.request("ui.get",args("principal" to "plugin:"+id,"id" to "summary")) as JSONObject
                    check(card.getInt("value")==2); output.putString("card","synthetic-count=2")
                }
                "reopen" -> {
                    step="cache after process death"; check(rt.account()==account)
                    check((plugin("fixture.closed-loop","readCache",input) as JSONObject).getInt("count")==2)
                    check(!(rt.request("auth.status",input) as JSONObject).getBoolean("authenticated"))
                    step="disable"; rt.request("plugins.disable",args("plugin_id" to "fixture.closed-loop"))
                    check(runCatching{plugin("fixture.closed-loop","readCache",input)}.exceptionOrNull() is PortError)
                }
                "arm","armDenied" -> {
                    output.putString("offset_parser", runCatching { Instant.parse("2026-11-08T19:00:00.123456+00:00"); "supported" }.getOrElse { it.javaClass.simpleName })
                    val key=options.getString("clock_key") ?: error("missing clock key")
                    val now=Instant.now(); val delay=options.getString("delay")?.toLong() ?: 35L
                    step="arm exact"; val scheduled=plugin("fixture.local-clock","schedule",args("account_id" to account,"key" to key,
                        "prepare_at" to now.plusSeconds(delay-5).toString(),"run_at" to now.plusSeconds(delay).toString(),
                        "deadline_at" to now.plusSeconds(delay+50).toString())) as JSONObject
                    val wake=scheduled.getJSONObject("wake_up")
                    output.putString("wake_state",wake.optString("state"))
                    output.putString("wake_error",wake.optJSONObject("error")?.optString("code"))
                    if(phase=="armDenied") {
                        check(wake.optString("state")=="not_armed" && wake.optJSONObject("error")?.optString("code")=="ExactAlarmPermissionRequired")
                    } else check(wake.optBoolean("scheduled")) { "NotArmed" }
                    output.putString("job_id",scheduled.getString("job_id")); output.putString("run_at",scheduled.getString("run_at"))
                }
                "checkWake","disableClock" -> {
                    val job=options.getString("job_id") ?: error("Missing expected job")
                    if(phase=="disableClock"){
                        rt.request("plugins.disable",args("plugin_id" to "fixture.local-clock")); rt.revoke("fixture.local-clock")
                    }
                    val subs=rt.subscriptions()
                    val armed=(0 until subs.length()).map{subs.getJSONObject(it)}.any{it.optString("job_id")==job && it.optBoolean("scheduled")}
                    check(armed==(phase=="checkWake"))
                    if(phase=="disableClock")check((rt.request("jobs.status",args("job_id" to job)) as JSONObject).getString("state")=="cancelled")
                    output.putString("armed",armed.toString())
                }
                "count" -> {
                    step="wake count"; val result=plugin("fixture.local-clock","read",args("account_id" to account,"key" to options.getString("clock_key"))) as JSONObject
                    check(result.getInt("count")==1); output.putLong("executed_at",result.getLong("at"))
                }
                "external" -> {
                    step="independent package staging"
                    val name="official.fudan-sports-0.2.0.dspack"
                    val root=context.assets.open(name).use { org.dansheng.app.PackageImport.stage(targetContext,it) }
                    try {
                        val pkg=File(root,"package"); val manifest=JSONObject(File(pkg,"manifest.json").readText())
                        val id=manifest.getString("id"); val p=args("plugin_id" to id)
                        step="install disabled"
                        check(!(rt.request("plugins.install",args("path" to pkg.absolutePath)) as JSONObject).getBoolean("enabled"))
                        rt.revoke(id); rt.bindPackage(id,manifest,JSONObject(File(pkg,"host-policy.json").readText()),org.dansheng.app.PackageImport.digest(File(root,"download.zip")))
                        if(rt.account()!=account)rt.setAccount(account)
                        val rejected=runCatching { plugin(id,"listTasks",input) }
                        check(rejected.exceptionOrNull() is PortError)
                        rt.request("permissions.set",args("subject" to "plugin:"+id,"grant" to args("capabilities" to manifest.getJSONArray("capabilities"),
                            "origins" to manifest.getJSONArray("network"),"account_ids" to JSONArray().put(account))))
                        step="run actual QuickJS package"
                        rt.request("plugins.enable",p); rt.activate(id)
                        val summary=plugin(id,"listTasks",input)
                        check(summary is JSONArray || summary is JSONObject)
                        step="disable, uninstall"
                        rt.request("plugins.disable",p); rt.revoke(id)
                        check(runCatching{plugin(id,"listTasks",input)}.exceptionOrNull() is PortError)
                        rt.request("plugins.uninstall",p)
                        val rows=rt.request("plugins.list") as JSONArray
                        check((0 until rows.length()).none{rows.getJSONObject(it).getString("id")==id})
                        output.putString("plugin",id); output.putInt("declared_pages",manifest.getJSONArray("ui").length())
                    } finally {root.deleteRecursively()}
                }
                "sports","sportsLoss","sportsCold" -> { step=phase; ProductSports.run(this,rt,output,phase) }
                "coldResult" -> {
                    step="school page session lost after process death"
                    val job=rt.request("jobs.status",args("job_id" to options.getString("job_id"))) as JSONObject
                    output.putString("job_state",job.getString("state"))
                    output.putString("job_error",job.optJSONObject("result")?.optJSONObject("error")?.optString("code"))
                    check(job.getString("state")=="waiting_for_auth")
                    val claims=targetContext.getSharedPreferences("dansheng-mutations-v1",0).all.size
                    check(claims==options.getString("claims_before")?.toInt())
                    output.putInt("new_write_claims",0)
                }
                "verifyFence" -> {
                    step="persistent uncertain job"
                    val job=args("job_id" to options.getString("job_id"))
                    check((rt.request("jobs.status",job) as JSONObject).getString("state")=="needs_reconciliation")
                    check((runCatching{rt.request("jobs.cancel",job)}.exceptionOrNull() as? PortError)?.code=="NeedsReconciliation")
                }
                else -> error("invalid phase")
            }
            output.putString("result","passed"); finish(Activity.RESULT_OK,output)
        } catch(e:Throwable) {
            output.putString("result","failed"); if(!output.containsKey("step"))output.putString("step",step)
            e.stackTrace.firstOrNull{it.fileName=="AgentProbe.kt" || it.fileName=="CampusAgent.kt"}?.let {
                output.putString("failed_at","${it.fileName}:${it.lineNumber}")
            }
            output.putString("reason",if(e is PortError)e.code else e.javaClass.simpleName); finish(Activity.RESULT_CANCELED,output)
        }
    }
}
