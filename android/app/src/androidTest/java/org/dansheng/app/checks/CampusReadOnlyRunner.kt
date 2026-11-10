package org.dansheng.app.checks

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.Context
import android.webkit.WebView
import android.os.Bundle
import kotlinx.coroutines.runBlocking
import org.dansheng.android.PortError
import org.dansheng.app.DanshengApplication
import org.dansheng.app.RuntimeHost
import org.dansheng.app.CampusVenueHost
import org.dansheng.app.MainActivity
import org.dansheng.app.VisiblePage
import org.json.JSONObject
import org.json.JSONArray
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.time.LocalDate
import java.time.ZoneId

/** Opt-in, separate test APK. Real connector plus Keystore; only allowlisted reads.
 * Credentials come from a one-shot adb-reversed loopback socket, never runner arguments. */
class CampusReadOnlyRunner: Instrumentation() {
    private lateinit var config:Bundle
    override fun newApplication(cl:ClassLoader,className:String,context:Context):android.app.Application =
        if(className==DanshengApplication::class.java.name)super.newApplication(LiveReadApplication::class.java.classLoader,LiveReadApplication::class.java.name,context)
        else super.newApplication(cl,className,context)
    override fun onCreate(arguments:Bundle?) {config=arguments?:Bundle();start()}
    override fun onStart() {
        val out=Bundle()
        try {
            val rt=(targetContext.applicationContext as DanshengApplication).runtime
            val stage=config.getString("phase")
            check(stage in listOf("seed","restart","forget"))
            if(stage=="forget"){
                val previous=rt.account()
                rt.setAccount("")
                if(previous!=null)for(kind in listOf("uis","forum","canvas"))check(rt.vault.get("campus-login/v1/$kind/$previous")==null)
                out.putString("result","forgotten");finish(Activity.RESULT_OK,out);return
            }
            val creds=if(stage=="seed") {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"),config.getString("port")!!.toInt()),5000)
                    socket.soTimeout=6000
                    val nonce=config.getString("nonce")!!
                    require(nonce.matches(Regex("[0-9a-f]{32}")))
                    socket.getOutputStream().write((nonce+"\n").toByteArray(Charsets.US_ASCII))
                    val data=socket.getInputStream().readNBytes(24*1024)
                    try { JSONObject(data.toString(Charsets.UTF_8)) } finally { data.fill(0) }
                }
            }else null
            if(creds!=null)rt.setAccount(creds.getString("user"))
            val account=rt.account() ?: error("NoActiveAccount")
            fun probe(tag:String, action:()->Any?):Any? {
                java.io.File(targetContext.cacheDir,"readonly-stage").writeText(tag)
                try {val value=action();out.putString(tag,"ok")
                    val n=when(value){is JSONArray->value.length();is JSONObject->arrayOf("records","courses","items","semesters","divisions","assignments","announcements","files","rooms").firstNotNullOfOrNull {value.optJSONArray(it)?.length()};else->null}
                    if(n!=null)out.putInt(tag+"_count",n)
                    return value
                }catch(e:PortError){out.putString(tag,e.code.takeIf{it.matches(Regex("[A-Za-z0-9_]{1,60}"))}?:"ServiceError");return null}
            }
            fun call(method:String,vararg params:Pair<String,Any?>)=rt.request(method,JSONObject().put("account_id",account).also {o->params.forEach{(k,v)->o.put(k,v)}})
            fun login(service:String):Any?=probe(service+"_login"){
                runBlocking {
                    if(creds==null)rt.campusLogins.connect(service,account)
                    else rt.campusLogins.connect(service,account) {
                        when(service){
                            "forum"->creds.getString("danxiuser") to creds.getString("danxipassword")
                            "canvas"->"" to creds.getString("canvastoken")
                            else->"" to creds.getString("password")
                        }
                    }
                }
            }
            if(config.getString("only")=="power") {
                if(login("power")!=null)probe("power_shape"){
                    val r=call("http.request","method" to "GET","url" to "https://zlapp.fudan.edu.cn/fudanelec/wap/default/info","follow_redirects" to false) as JSONObject
                    out.putInt("power_http",r.getInt("status"))
                    val obj=runCatching{JSONObject(r.getString("body"))}.getOrNull()
                    out.putString("power_body",if(obj==null)"non_json" else "json")
                    val d=obj?.opt("d");out.putString("power_d",d?.javaClass?.simpleName?:"missing")
                    val row=d as? JSONObject
                    if(row!=null)for(k in listOf("roomid","xq","ssmc","fjmc","fj_surplus","fj_used","fj_update_time")){
                        val field=row.opt(k)
                        val shape=when{field==null || field===JSONObject.NULL->"missing";field is Number->"number";field !is String->"other";field.isBlank()->"blank";k=="fj_update_time" && field.matches(Regex("[0-9]{10,13}"))->"epoch";k=="fj_update_time" && field.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}.*"))->"datetime";else->"string"}
                        out.putString("power_"+k,shape)
                    }
                    true
                }
                out.putString("result","completed");finish(Activity.RESULT_OK,out);return
            }
            if(config.getString("only")=="files") {
                check(login("ecard")!=null && login("canvas")!=null)
                val origin="https://elearning.fudan.edu.cn"
                fun site(url:String?):String {
                    if(url.isNullOrBlank())return "missing"
                    val u=runCatching{java.net.URI(url)}.getOrNull()?:return "invalid"
                    val host=u.host?:return "relative"
                    return if(host=="elearning.fudan.edu.cn")"canvas" else if(host.endsWith(".fudan.edu.cn"))host.replace('.','_') else "external"
                }
                val courses=call("canvas.courses.sync") as JSONArray
                for(i in 0 until minOf(courses.length(),6)){
                    val course=courses.getJSONObject(i).getJSONObject("payload").get("id").toString()
                    val items=probe("course_"+i){call("canvas.materials.sync","course_id" to course)} as? JSONArray?:continue
                    val file=(0 until items.length()).mapNotNull{items.optJSONObject(it)?.optJSONObject("payload")}.firstOrNull{it.optLong("size",-1) in 1..2_097_152}?:continue
                    val id=file.get("id").toString();check(id.matches(Regex("[0-9]+")))
                    val meta=call("http.request","url" to "$origin/api/v1/files/$id","method" to "GET","follow_redirects" to false) as JSONObject
                    out.putInt("metadata_http",meta.getInt("status"))
                    val json=JSONObject(meta.getString("body"));val url=json.optString("url")
                    out.putString("download_site",site(url));out.putString("locked",json.optBoolean("locked_for_user").toString())
                    if(site(url)=="canvas"){
                        val head=call("http.request","url" to url,"method" to "HEAD","follow_redirects" to false) as JSONObject
                        out.putInt("download_http",head.getInt("status"));out.putString("redirect_site",site(head.optJSONObject("headers")?.optString("location")))
                    }
                    if(out.getString("redirect_site")=="elearning_obs_fudan_edu_cn") {
                        call("canvas.configure","origin" to origin,"access" to "host_session",
                            "download_origins" to JSONArray(listOf(origin,"https://elearning.obs.fudan.edu.cn")))
                    }
                    val asset=probe("file_transfer"){call("canvas.material.download","course_id" to course,"file_id" to id)} as? JSONObject
                    if(asset!=null)probe("asset_open"){call("files.read","asset_id" to asset.getString("asset_id"),"offset" to 0,"length" to 1024)}
                    break
                }
                out.putString("result","completed");finish(Activity.RESULT_OK,out);return
            }
            val hasCampus=login("ecard")!=null
            if(creds!=null){
                probe("notices_ug"){call("fudan.notices")}
                probe("notices_pg"){call("fudan.notices","level" to "graduate")}
            }
            if(config.getString("only")!="venue") {
            if(creds!=null)probe("canvas_token"){runBlocking { rt.campusLogins.connect("canvas",account,true){"" to creds.getString("canvastoken")} }}
            if(login("forum")!=null){
                probe("forum_divisions"){call("community.tea.divisions")}
                val result=probe("forum_holes"){call("community.tea.holes","size" to 3,"page_size" to 3,"order" to "updated")}
                val holes=result as? JSONArray ?: (result as? JSONObject)?.optJSONArray("records")
                val record=holes?.optJSONObject(0); val row=record?.optJSONObject("payload")?:record
                val id=row?.optLong("hole_id")?.takeIf {it>0} ?: row?.optLong("id")?.takeIf{it>0}
                if(id!=null)probe("forum_floors"){call("community.tea.floors","hole_id" to id,"offset" to 0,"size" to 3,"page_size" to 3)}
            }
            if(login("canvas")!=null){
                val courses=probe("canvas_courses"){call("canvas.courses.sync")}
                val array=courses as? JSONArray ?: (courses as? JSONObject)?.optJSONArray("courses") ?: (courses as? JSONObject)?.optJSONArray("records")
                val row=array?.optJSONObject(0)
                val id=(row?.optJSONObject("payload")?.opt("id") ?: row?.opt("id"))?.toString()
                if(id!=null) for((label,m) in listOf("assignments" to "canvas.assignments.sync","announcements" to "canvas.announcements.sync","files" to "canvas.materials.sync"))
                    probe("canvas_"+label){call(m,"course_id" to id)}
                if(creds!=null && array!=null){
                    for(i in 1 until minOf(array.length(),6)){
                        val course=array.optJSONObject(i)?.optJSONObject("payload")?.opt("id")?.toString() ?:continue
                        val materials=probe("course_"+i+"_files"){call("canvas.materials.sync","course_id" to course)} as? JSONArray ?: continue
                        if(materials.length()==0)continue
                        out.putString("canvas_readable_files","ok")
                        val file=(0 until materials.length()).mapNotNull{materials.optJSONObject(it)?.optJSONObject("payload")}.firstOrNull{it.optLong("size",-1) in 1..2_097_152} ?: continue
                        probe("canvas_file_read"){val asset=call("canvas.material.download","course_id" to course,"file_id" to file.get("id").toString()) as JSONObject
                            val chunk=call("files.read","asset_id" to asset.getString("asset_id"),"offset" to 0,"length" to 1024) as JSONObject
                            check(chunk.getString("data").isNotEmpty());true}
                        break
                    }
                }
            }
            if(hasCampus){
                probe("ecard_balance"){call("fudan.ecard.balance")}
                if(creds!=null) {
                    if(login("academic")!=null){
                        probe("semesters"){call("fudan.semesters")}
                        probe("academic_landing"){
                            val r=call("http.request","method" to "GET","url" to "https://fdjwgl.fudan.edu.cn/student/for-std/course-table","follow_redirects" to false) as JSONObject
                            out.putInt("academic_landing_http",r.getInt("status"));true
                        }
                    }
                    if(login("bus")!=null)probe("bus"){call("fudan.bus","holiday" to false)}
                    if(login("power")!=null)probe("power"){call("fudan.electricity")}
                    if(login("dining")!=null)probe("dining"){call("fudan.dining.occupancy","area_code" to 0)}
                    probe("power_history"){call("fudan.electricity.history","offset" to 0,"size" to 5)}
                }
            }
            if(creds!=null){
                fun rooms()=call("fudan.rooms","building" to "H3","date" to LocalDate.now(ZoneId.of("Asia/Shanghai")).toString())
                if(probe("rooms"){rooms()}==null && login("webvpn")!=null)probe("rooms_webvpn"){rooms()}
                probe("library"){call("fudan.library.occupancy")}
                val prefs=targetContext.getSharedPreferences("dansheng-vault-v1",0).all.values.filterIsInstance<String>()
                val successful=listOf("ecard_login","canvas_login","forum_login").any{out.getString(it)=="ok"}
                if(successful)check(prefs.isNotEmpty())
                for(blob in prefs){
                    val envelope=JSONObject(blob); check(envelope.has("iv") && envelope.has("ciphertext"))
                    for(k in listOf("password","danxipassword","canvastoken"))check(!blob.contains(creds.getString(k)))
                }
                out.putString("at_rest","ciphertext")
            }
            }
            if(stage=="restart" && out.getString("ecard_login")=="ok" && config.getString("venues")=="yes") {
                java.io.File(targetContext.cacheDir,"readonly-stage").writeText("venue_activity")
                val activity=startActivitySync(Intent(targetContext,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) as MainActivity
                val foreground=config.getString("foreground")=="yes"
                val active=java.util.concurrent.atomic.AtomicBoolean(true)
                val cancel=if(foreground) kotlin.concurrent.thread(isDaemon=true){
                    try {Thread.sleep(70_000);if(active.get())sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)}
                    catch(_:InterruptedException){}
                }else null
                try {
                    rt.attach(if(foreground)activity else null)
                    out.putString("venue_mode",if(foreground)"foreground" else "background")
                    val venue=CampusVenueHost(activity,rt)
                    if(probe("venue_page_login"){runBlocking{venue.call("visibleLogin",JSONObject())}}!=null) {
                        val rows=probe("venue_list"){runBlocking{venue.call("venues",JSONObject())}} as? JSONArray
                        val id=rows?.optJSONObject(0)?.optInt("id") ?: 0
                        if(id>0)probe("venue_slots"){runBlocking{venue.call("calendar",JSONObject().put("venue_id",id)
                            .put("target_date",LocalDate.now(ZoneId.of("Asia/Shanghai")).toString()))}}
                    }
                    out.putString("venue_identity",LiveReadApplication.venueIdentity)
                    out.putString("venue_dialog",LiveReadApplication.venueDialog)
                    out.putString("venue_login_site",LiveReadApplication.venueSite)
                    out.putString("venue_route",LiveReadApplication.venueRoute.joinToString("_"))
                    out.putString("venue_identity_http",LiveReadApplication.identityHttp)
                    out.putString("venue_list_http",LiveReadApplication.listHttp)
                    out.putString("venue_idp_form",LiveReadApplication.idpForm)
                }finally { active.set(false);cancel?.interrupt();runOnMainSync {activity.finish()} }
            }
            out.putString("result","completed");finish(Activity.RESULT_OK,out)
        }catch(e:Exception){out.putString("result","failed");out.putString("reason",e.javaClass.simpleName);finish(Activity.RESULT_CANCELED,out)}
    }
}

/** Real WebView (unchanged navigation); emit only typed status and a known site label. */
class LiveReadApplication:DanshengApplication(){
    override fun createRuntime()=RuntimeHost(this,browserIsolated){ gate->
        object:VisiblePage(gate){
            override fun onInteractiveShown(accountId:String){venueDialog="shown"}
            override fun showAuthorized(principal:String,accountId:String,url:String,webView:WebView,complete:(Result<String>)->Unit){
                val watching=java.util.concurrent.atomic.AtomicBoolean(true)
                val h=android.os.Handler(android.os.Looper.getMainLooper())
                val watch=object:Runnable{override fun run(){
                    if(!watching.get())return
                    val u=webView.url?.let(android.net.Uri::parse)
                    val site=when(u?.host){"booking.fudan.edu.cn"->if(u.path=="/reservation/api/login/main")"sso" else "booking";"uis.fudan.edu.cn"->"uis";"id.fudan.edu.cn"->"id";null->"none";else->"other"}
                    if(venueRoute.lastOrNull()!=site && venueRoute.size<20)venueRoute.add(site)
                    if(site=="id" || site=="uis")webView.evaluateJavascript("""(()=>{
                      const p=[...document.querySelectorAll('input[type=password]')].find(x=>x.offsetParent!==null);
                      const f=p?.form,otp=[...document.querySelectorAll('input')].some(x=>x.offsetParent!==null && /动态码|验证码|短信/.test(x.placeholder||''));
                      return [p?'pwd':'nopwd',f?(f.method==='post'?'post':'get'):'noform',f?new URL(f.action,location.href).origin===location.origin?'same':'other':'na',
                       window.__ds_login_injected?'bridge':'idle',window.__ds_login_submitted?'submitted':'none',otp?'otp':'nootp'].join('_')})()"""){v->
                        val label=v.trim('"');if(label.matches(Regex("(pwd|nopwd)_(post|get|noform)_(same|other|na)_(bridge|idle)_(submitted|none)_(otp|nootp)")))idpForm=label
                    }
                    if(site=="booking"){
                        webView.evaluateJavascript("""(()=>{if(location.origin!=='https://booking.fudan.edu.cn')return null;
                        if(!window.__dsAudit){window.__dsAudit={};for(const [k,p] of [['who','/reservation/site/user/detail'],['list','/reservation/api/topic/resource-list?id=48&pageSize=1']]){
                        fetch(p,{credentials:'same-origin',headers:{'Accept':'application/json','sign-key':p.split('?')[0]+'get'}}).then(async r=>{
                        let j;try{j=await r.json()}catch{};window.__dsAudit[k]=String(r.status)+'_'+(!j?'html':j.e==='OK'?'ok':'other');
                        }).catch(()=>window.__dsAudit[k]='network');}}return window.__dsAudit})()"""){raw->
                            val j=runCatching{JSONObject(raw)}.getOrNull()
                            fun safe(k:String)=j?.optString(k)?.takeIf{it.matches(Regex("(?:[1-5][0-9]{2}_(?:html|ok|other)|network)"))}
                            safe("who")?.let{identityHttp=it};safe("list")?.let{listHttp=it}
                        }
                    };h.postDelayed(this,900)
                }}
                h.post(watch)
                super.showAuthorized(principal,accountId,url,webView){r->
                    watching.set(false);h.removeCallbacks(watch)
                    venueIdentity=(r.exceptionOrNull() as? PortError)?.code ?: if(r.isSuccess)"verified" else "unknown"
                    venueSite=when(runCatching{android.net.Uri.parse(webView.url).host}.getOrNull()){
                        "booking.fudan.edu.cn"->"booking";"id.fudan.edu.cn"->"id";"uis.fudan.edu.cn"->"uis";null->"none";else->"other"
                    }
                    complete(r)
                }
            }
        }
    }
    companion object {@Volatile var venueIdentity="not_started"; @Volatile var venueSite="none"; @Volatile var venueDialog="none"
        val venueRoute=mutableListOf<String>(); @Volatile var identityHttp="unknown"; @Volatile var listHttp="unknown";@Volatile var idpForm="unknown"}
}
