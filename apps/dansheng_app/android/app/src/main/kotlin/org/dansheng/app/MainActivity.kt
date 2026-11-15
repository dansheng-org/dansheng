package org.dansheng.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterActivity(), DanshengApi {
    private val rt get() = (application as DanshengApplication).runtime
    private val campus by lazy { CampusServices(this,rt,::serviceLogin,::confirm,sheet,::verifyPortal) }
    private var portalResult:CompletableDeferred<Intent>?=null
    private var picker: CompletableDeferred<Uri>? = null
    private val sheet by lazy { ModernSheet(this) }
    private var notificationReply: CompletableDeferred<Boolean>? = null
    private val taskLink = java.util.concurrent.atomic.AtomicBoolean(false)
    override fun onCreate(savedInstanceState:android.os.Bundle?) {
        taskLink.set(intent?.hasExtra("resume_job_id")==true)
        super.onCreate(savedInstanceState)
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent)
        if(intent.hasExtra("resume_job_id")) taskLink.set(true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DanshengApi.setUp(flutterEngine.dartExecutor.binaryMessenger, this)
    }
    override fun onResume() { super.onResume(); rt.attach(this); rt.onForeground() }
    override fun onPause() { rt.attach(null); super.onPause() }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DanshengApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        super.cleanUpFlutterEngine(flutterEngine)
    }
    override fun onDestroy() {
        portalResult?.completeExceptionally(PortError("Cancelled"));portalResult=null
        picker?.completeExceptionally(PortError("Cancelled")); picker = null
        notificationReply?.complete(false); notificationReply = null
        sheet.close(); super.onDestroy()
    }

    override suspend fun invoke(command: HostCommand, payload: String): String = withContext(Dispatchers.IO) {
        try {
            require(payload.length <= 512 * 1024)
            val p = JSONObject(payload)
            if(p.optString("plugin_id")=="official.fudan-venues")throw PortError("ReservedService")
            val result: Any? = when (command) {
                HostCommand.CAMPUS -> campus.call(p.getString("method"),p.optJSONObject("params") ?: JSONObject())
                HostCommand.INFO -> rt.request("core.info")
                HostCommand.PLUGINS -> {
                    val rows=rt.request("plugins.list") as JSONArray
                    JSONArray((0 until rows.length()).map { rows.getJSONObject(it) }.filter{it.optString("id")!="official.fudan-venues"})
                }
                HostCommand.IMPORT_PACKAGE -> importPackage()
                HostCommand.ENABLE_PLUGIN -> enable(p.getString("plugin_id"))
                HostCommand.DISABLE_PLUGIN -> disable(p.getString("plugin_id"))
                HostCommand.REMOVE_PLUGIN -> {
                    val id = p.getString("plugin_id")
                    confirm("卸载插件？", id)
                    disable(id); rt.request("plugins.uninstall", pluginParam(id))
                }
                HostCommand.COMPONENT -> {
                    val id = p.getString("plugin_id"); val row = installed(id, true)
                    val componentId = p.getString("id")
                    val ui = row.getJSONObject("manifest").optJSONArray("ui") ?: JSONArray()
                    require((0 until ui.length()).any { ui.getJSONObject(it).optString("id") == componentId })
                    rt.request("ui.get", JSONObject().put("principal", "plugin:"+id).put("id", componentId))
                }
                HostCommand.PREVIEW, HostCommand.RUN_ACTION -> {
                    val id = p.getString("plugin_id"); val action = p.getString("action")
                    val row = installed(id, true); val manifest = row.getJSONObject("manifest")
                    val descriptor = manifest.getJSONObject("actions").getJSONObject(action)
                    val input = p.optJSONObject("input") ?: JSONObject()
                    require(!input.has("account_id") || input.getString("account_id") == rt.account())
                    val args = pluginParam(id).put("action", action).put("input", input)
                    if (command == HostCommand.PREVIEW) rt.request("actions.preview", args)
                    else {
                        if (descriptor.optBoolean("mutating")) {
                            val preview = rt.request("actions.preview", args) as JSONObject
                            val hash = preview.getString("input_sha256")
                            if (hash != p.optString("input_sha256")) throw PortError("PreviewChanged")
                            if(id=="official.fudan-sports" && action=="schedule"){
                                val rows=input.getJSONArray("plans")
                                val summary=buildString {
                                    append("账号：").append(input.getString("account_id"))
                                    append("\n场馆：#").append(input.get("venue_id"))
                                    append("\n预约日期：").append(input.getString("target_date"))
                                    append("\n开始时间：").append(input.getString("release_at"))
                                    for(i in 0 until rows.length()){
                                        val row=rows.getJSONObject(i)
                                        append("\n").append(row.getString("time")).append(" · 场地 ").append(row.getJSONArray("courts").join("、"))
                                    }
                                }
                                confirm("创建定时任务",summary)
                            } else confirm("确认执行操作", id+" · "+action+"\n"+input.toString(2))
                            installed(id, true)
                            if (input.has("account_id") && input.getString("account_id") != rt.account()) throw PortError("AccountChanged")
                            rt.recordConsent(id, action, input, hash)
                        }
                        rt.request("plugins.run", args)
                    }
                }
                HostCommand.JOBS -> scopedJobs()
                HostCommand.EVENTS -> {
                    val out = rt.request("events.poll", JSONObject().put("after",p.optLong("after")).put("limit",100)) as JSONObject
                    // Events only invalidate snapshots in the UI. Owner event bodies can contain private data.
                    val raw = out.getJSONArray("events"); val invalidations = JSONArray()
                    for (i in 0 until raw.length()) {
                        val e=raw.getJSONObject(i)
                        if(e.optString("kind")=="audit") continue
                        val event=JSONObject().put("sequence",e.optLong("sequence")).put("kind",e.optString("kind"))
                        if(e.optString("kind")=="ui_changed") {
                            val d=e.optJSONObject("data")
                            event.put("principal",d?.optString("principal")).put("id",d?.optString("id"))
                        }
                        invalidations.put(event)
                    }
                    out.put("events",invalidations).put("open_tasks",taskLink.getAndSet(false))
                }
                HostCommand.ACCOUNT -> JSONObject().put("account_id", rt.account() ?: JSONObject.NULL)
                HostCommand.SET_ACCOUNT -> {
                    val account = p.getString("account_id").trim()
                    if(account.isNotEmpty() && !account.matches(Regex("^[A-Za-z0-9_.:@-]{1,128}$"))) throw PortError("InvalidAccount")
                    if (account != rt.account()) {
                        val rows = rt.request("plugins.list") as JSONArray
                        for(i in 0 until rows.length()) {
                            val row = rows.getJSONObject(i); if(row.getBoolean("enabled")) disable(row.getString("id"))
                        }
                        rt.setAccount(account)
                    }
                    JSONObject().put("account_id",rt.account() ?: JSONObject.NULL)
                }
                HostCommand.PERMISSIONS -> rt.permissions()
                HostCommand.OPEN_ALARM_SETTINGS -> {
                    if (Build.VERSION.SDK_INT >= 31) withContext(Dispatchers.Main) {
                        startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:"+packageName)))
                    }
                    rt.permissions()
                }
                HostCommand.REQUEST_NOTIFICATIONS -> { requestNotice(); rt.permissions() }
                HostCommand.BALANCE -> {
                    val account = rt.account() ?: throw PortError("AuthenticationRequired")
                    val args = JSONObject().put("account_id",account)
                    try {
                        val session = rt.request("fudan.ecard.session",args) as JSONObject
                        if(!session.getBoolean("has_session") || p.optBoolean("sign_in")) cardLogin(account)
                        val record=try { rt.request("fudan.ecard.balance",args) as JSONObject } catch(e:PortError){
                            if(e.code!="AuthenticationRequired" || !session.getBoolean("has_session") || p.optBoolean("sign_in")) throw e
                            cardLogin(account); rt.request("fudan.ecard.balance",args) as JSONObject
                        }
                        cardAmount(record,account,false)
                    } catch(e:PortError){
                        if(rt.account()!=account || e.code=="Cancelled") throw e
                        val rows=rt.request("sources.query",JSONObject().put("account_id",account)
                            .put("source_id","official.fudan.ecard.balance").put("external_id","ecard-balance")) as JSONArray
                        val cached=rows.optJSONObject(0) ?: throw e
                        cardAmount(cached,account,true).put("refresh_error",e.code)
                    }
                }
            }
            JSONArray().put(result ?: JSONObject.NULL).toString().let { it.substring(1,it.length-1) }
        } catch (e: PortError) { throw FlutterError(e.code, e.code) }
          catch (e: FlutterError) { throw e }
          catch (e: Exception) { throw FlutterError("HostOperationFailed","无法完成操作") }
    }
    private fun cardAmount(record:JSONObject,account:String,stale:Boolean):JSONObject {
        if(rt.account()!=account || record.optString("account_id")!=account) throw PortError("AccountMismatch")
        val money=(record.optJSONObject("payload") ?: record.getJSONObject("data")).getJSONObject("balance")
        val amount=java.math.BigDecimal.valueOf(money.getLong("cents"),2).toPlainString()
        return JSONObject().put("balance",amount).put("currency",money.getString("currency"))
            .put("stale",stale).put("updated_at",record.optString("observed_at",record.optString("updated_at")))
    }
    private suspend fun cardLogin(account:String) {
        serviceLogin("ecard",account,false)
    }
    private suspend fun serviceLogin(service:String,account:String,replace:Boolean):Any? {
        val confirmForumRisk: (suspend () -> Unit)? = if(service=="forum") ({
            sheet.confirm(ForumRiskConsent.TITLE,ForumRiskConsent.MESSAGE,"同意并继续",
                acknowledgement=ForumRiskConsent.ACKNOWLEDGEMENT,
                link=ForumRiskConsent.AGREEMENT_LABEL to ForumRiskConsent.AGREEMENT_URL)
        }) else null
        return rt.campusLogins.connect(service,account,replace,confirmForumRisk) { previous ->
            val forum=service=="forum"
            val emails=if(forum)CampusLogins.forumEmails(account) else emptyList()
            val title=when(service) { "forum"->"登录树洞"; "canvas"->"连接 Canvas"; else->"统一身份认证" }
            val secret=when(service) { "forum"->"树洞密码"; "canvas"->"Canvas 访问令牌"; else->"统一身份认证密码" }
            sheet.credentials(title,"登录后加密保存在本机",if(forum)"注册邮箱" else null,secret,
                previous.ifBlank { emails.firstOrNull().orEmpty() }, emails)
        }
    }

    private fun scopedJobs(): JSONArray {
        val jobs = rt.request("jobs.status") as JSONArray
        val wakes = rt.subscriptions()
        val account = rt.account()
        val out = JSONArray()
        for (i in 0 until jobs.length()) {
            val job = jobs.getJSONObject(i); val data = job.optJSONObject("data") ?: continue
            if(data.optString("plugin_id")=="official.fudan-venues" || (!data.has("run_at") && !data.has("deadline_at"))) continue
            val input = data.optJSONObject("input")
            val bound = input?.optString("account_id")?.takeIf { it.isNotBlank() } ?: data.optString("account_id")
            if(bound.isBlank() || bound != account) continue
            val row = JSONObject()
            for (key in listOf("id","state","run_at","updated_at")) if(job.has(key)) row.put(key,job.get(key))
            row.put("plugin_id",data.optString("plugin_id")).put("action",data.optString("action"))
                .put("account_id",bound).put("task_id",input?.optString("task_id"))
            for(j in 0 until wakes.length()) if(wakes.getJSONObject(j).optString("job_id")==job.optString("id"))
                row.put("wake_up",wakes.getJSONObject(j))
            out.put(row)
        }
        return out
    }
    private fun pluginParam(id:String) = JSONObject().put("plugin_id",id)
    private fun installed(id:String, enabled:Boolean = false):JSONObject {
        val plugins = rt.request("plugins.list") as JSONArray
        val row = (0 until plugins.length()).map { plugins.getJSONObject(it) }.firstOrNull { it.getString("id")==id } ?: throw PortError("NotInstalled")
        if(enabled && !row.getBoolean("enabled")) throw PortError("PluginDisabled")
        return row
    }
    private fun grant(id:String,g:JSONObject) = rt.request("permissions.set",JSONObject().put("subject","plugin:"+id).put("grant",g))
    private fun disable(id:String):Any? {
        val result = rt.request("plugins.disable",pluginParam(id))
        rt.revoke(id); grant(id,JSONObject()); return result
    }
    private suspend fun enable(id:String):Any? {
        val row=installed(id); val m=row.getJSONObject("manifest")
        val account=rt.account() ?: throw PortError("AccountRequired")
        val caps=m.getJSONArray("capabilities"); val origins=m.optJSONArray("network") ?: JSONArray()
        val description=if(id=="official.fudan-sports")
            "为账号 $account 开启定时预约。它可以使用当前场馆登录状态；每个定时计划仍需你确认。"
            else "账号：$account\n请求的能力："+(0 until caps.length()).joinToString("、"){caps.getString(it)}
        confirm(if(id=="official.fudan-sports")"启用定时抢场" else "启用插件",description)
        if(rt.account()!=account || installed(id).getJSONObject("manifest").toString()!=m.toString()) throw PortError("PluginChanged")
        val g=JSONObject().put("account_ids",JSONArray().put(account)).put("origins",origins).put("capabilities",caps)
        grant(id,g)
        try {
            val result = rt.request("plugins.enable",pluginParam(id))
            rt.activate(id); return result
        } catch(e:Exception) { disable(id); throw e }
    }
    private suspend fun importPackage():Any? {
        val uri=pick()
        val tmp=PackageImport.stage(this,uri)
        try {
            val pkg=File(tmp,"package")
            val m=JSONObject(File(pkg,"manifest.json").readText())
            val id=m.getString("id")
            if(id=="official.fudan-venues")throw PortError("ReservedService")
            val hash=PackageImport.digest(File(tmp,"download.zip"))
            val policyFile=File(pkg,"host-policy.json")
            val recognized=OfficialSports.recognized(id,m.getString("version"),hash)
            val accepted=sheet.review(m,hash,recognized,policyFile.isFile)
            val descriptor=if(accepted && policyFile.isFile) {
                require(policyFile.length()<=128*1024); JSONObject(policyFile.readText())
            } else null
            val result=rt.request("plugins.install",JSONObject().put("path",pkg.absolutePath))
            rt.revoke(id); grant(id,JSONObject())
            rt.bindPackage(id,m,descriptor,hash)
            return result
        } finally { tmp.deleteRecursively() }
    }
    private suspend fun confirm(title:String,message:String) = sheet.confirm(title,message)
    private suspend fun verifyPortal(account:String,service:String):Any? {
        val epoch=rt.accountEpoch
        val data=withContext(Dispatchers.Main){
            if(portalResult!=null)throw PortError("Busy")
            val deferred=CompletableDeferred<Intent>();portalResult=deferred
            try {
                startActivityForResult(Intent(this@MainActivity,CampusPortalActivity::class.java).putExtra("account",account)
                    .putExtra("autofill",rt.campusLogins.canRestoreVenue(account)),733)
                deferred.await()
            }finally{portalResult=null}
        }
        return synchronized(rt.authGuard){
            if(rt.account()!=account || rt.accountEpoch!=epoch)throw PortError("AccountChanged")
            rt.request("fudan.portal.bind",JSONObject().put("account_id",account).put("service",service)
                .put("portal",data.getStringExtra("portal")).put("identity",data.getStringExtra("identity")))
        }
    }
    private suspend fun pick():Uri = withContext(Dispatchers.Main) {
        if (picker!=null) throw PortError("PickerBusy")
        val pending=CompletableDeferred<Uri>(); picker=pending
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE),731)
            pending.await()
        } finally { picker=null }
    }
    @Deprecated("Compatibility with FlutterActivity")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==733){
            if(resultCode==Activity.RESULT_OK && data!=null)portalResult?.complete(data)
            else {
                // The portal names its account; a restarted app has no in-memory record of who opened it.
                val who=data?.getStringExtra("account")
                if(data?.getBooleanExtra("passwordSent",false)==true && !data.getBooleanExtra("passwordAccepted",false) &&
                    who!=null && who==rt.account())rt.campusLogins.suspendVenuePassword(who)
                portalResult?.completeExceptionally(PortError("Cancelled"))
            }
        }
        if(requestCode==731) {
            val uri=data?.data
            if(resultCode==Activity.RESULT_OK && uri!=null) picker?.complete(uri) else picker?.completeExceptionally(PortError("Cancelled"))
        }
    }
    private suspend fun requestNotice() = withContext(Dispatchers.Main) {
        if(Build.VERSION.SDK_INT>=33) {
            if(notificationReply!=null) throw PortError("PermissionRequestBusy")
            val p=CompletableDeferred<Boolean>(); notificationReply=p
            try { requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),732); p.await() }
            finally { notificationReply=null }
        }
        Unit
    }
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<String>,grantResults:IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==732) notificationReply?.complete(grantResults.firstOrNull()==android.content.pm.PackageManager.PERMISSION_GRANTED)
    }
}
