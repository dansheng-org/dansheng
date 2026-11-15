package org.dansheng.app

import android.app.Activity
import android.content.Intent
import android.util.Base64
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.dansheng.android.PortError
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** The mobile UI is a trusted local client; never expose arbitrary owner methods to the UI or to MCP. */
internal class CampusServices(
    private val activity:Activity, private val rt:RuntimeHost,
    private val login:suspend (String,String,Boolean)->Any?,
    private val confirm:suspend (String,String)->Unit,
    sheet:ModernSheet,
    private val verifyPortal:suspend (String,String)->Any?,
    private val pickDocument:suspend ()->android.net.Uri,
) {
    private val venues=CampusVenueHost(activity,rt,sheet)
    private val reads=setOf(
        "fudan.ecard.statement","fudan.ecard.statistics","fudan.electricity.statistics",
        "fudan.rooms","fudan.electricity","fudan.electricity.history","fudan.ecard.transactions","fudan.library.occupancy","fudan.dining.occupancy","fudan.bus","fudan.notices",
        "fudan.semesters","fudan.postgraduate.semester","fudan.timetable.sync","fudan.postgraduate.sync","fudan.student_association","fudan.exams","fudan.grades","fudan.gpa","fudan.pe",
        "canvas.courses.sync","canvas.announcements.sync","canvas.assignments.sync","canvas.materials.sync","canvas.modules.sync","canvas.module_items.sync","canvas.folders.sync","canvas.pages.sync","canvas.page.read",
        "canvas.quizzes.sync","canvas.quiz.read","canvas.discussions.sync","canvas.discussion.read","canvas.discussion.view",
        "canvas.assignment_groups.sync","canvas.submission.self","canvas.grades.self","fudan.catalog.syllabus",
        "fudan.cloud.roots","fudan.cloud.list","fudan.notice.attachments","webdav.servers","webdav.list",
        "community.tea.divisions","community.tea.holes","community.tea.hole","community.tea.floors","community.danke.search","community.danke.group","community.danke.reviews",
    )
    /** Drive writes: run exactly once after a UI action, never cached or retried. */
    private val writes=setOf(
        "fudan.cloud.mkdir","fudan.cloud.rename","fudan.cloud.delete","fudan.cloud.upload","fudan.cloud.share","fudan.cloud.unshare",
        "webdav.server.add","webdav.server.remove","webdav.mkdir","webdav.rename","webdav.delete","webdav.upload",
    )
    private fun digest(s:String)=MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString(""){"%02x".format(it)}
    private fun cacheKey(m:String,p:JSONObject)= "campus:"+digest(m+"\n"+PortUtils.canonicalJson(p))
    private fun checked(account:String,epoch:Long){if(account!=rt.account() || epoch!=rt.accountEpoch)throw PortError("AccountChanged")}
    suspend fun call(method:String, supplied:JSONObject):Any? {
        if(method=="campus.openNotice"){
            val url=supplied.getString("url")
            val uri=android.net.Uri.parse(url)
            if(uri.scheme!="https" || uri.host !in setOf("jwc.fudan.edu.cn","gs.fudan.edu.cn") || uri.userInfo!=null || uri.port !in setOf(-1,443))throw PortError("UntrustedOrigin")
            withContext(Dispatchers.Main){
                try{activity.startActivity(Intent(Intent.ACTION_VIEW,uri))}
                catch(_:android.content.ActivityNotFoundException){activity.startActivity(Intent(activity,CampusPortalActivity::class.java).putExtra("notice",url))}
            }
            return JSONObject().put("opened",true)
        }
        // The eHall arrangement is a device-level interface preference: readable signed out, shared
        // by every account, holding no campus data, and kept out of Core's account-bound cache.
        if(method=="ehall.layout.get")return BoardLayoutStore.read(rt.prefs.getString(BoardLayoutStore.KEY,null))
        if(method=="ehall.layout.set"){
            val text=BoardLayoutStore.validate(supplied.optJSONObject("layout"))
            check(rt.prefs.edit().putString(BoardLayoutStore.KEY,text).commit())
            return JSONObject().put("saved",true)
        }
        if(method.startsWith("agent."))return CampusAgent.call(rt,method.removePrefix("agent."),supplied)
        val (account,epoch)=synchronized(rt.authGuard) {
            (rt.account() ?: throw PortError("AccountRequired")) to rt.accountEpoch
        }
        if(supplied.has("account_id") && supplied.optString("account_id")!=account)throw PortError("AccountMismatch")
        val p=JSONObject(supplied.toString()).put("account_id",account)
        // A restored native session or saved password must not bypass the login notice.
        if(method.startsWith("community.tea.") || method.startsWith("forum."))
            rt.campusLogins.requireForumConsent(account)
        if(method=="forum.openLink") {
            val uri=android.net.Uri.parse(p.getString("url"))
            if(uri.scheme !in setOf("http","https") || uri.host.isNullOrBlank() || uri.userInfo!=null)
                throw PortError("UntrustedOrigin")
            withContext(Dispatchers.Main) {
                checked(account,epoch)
                try { activity.startActivity(Intent(Intent.ACTION_VIEW,uri).addCategory(Intent.CATEGORY_BROWSABLE)) }
                catch(_:android.content.ActivityNotFoundException){throw PortError("ViewerUnavailable")}
            }
            return JSONObject().put("opened",true)
        }
        if(method.startsWith("powerAlert.")){
            return when(method.removePrefix("powerAlert.")){
                "get"->rt.powerAlerts.status()
                "set"->rt.powerAlerts.configure(p.getBoolean("enabled"),p.getDouble("threshold_kwh"))
                "check"->rt.powerAlerts.check()
                "notificationSettings"->{rt.powerAlerts.openNotificationSettings();rt.permissions()}
                else->throw PortError("MethodUnavailable")
            }.also{checked(account,epoch)}
        }
        if(method.startsWith("agenda."))return CampusAgenda.call(rt,account,method.removePrefix("agenda."),p).also{checked(account,epoch)}
        if(method=="campus.login")return login(p.getString("service"),account,p.optBoolean("replace"))
        // WebVPN switch from settings: only the mode is chosen here; the routed
        // campus origins stay the adapter's fixed defaults.
        if(method=="fudan.webvpn.status")return rt.request(method,JSONObject().put("account_id",account)).also{checked(account,epoch)}
        if(method=="fudan.webvpn.configure"){
            val mode=p.optString("mode","auto")
            if(mode !in setOf("auto","gateway","direct"))throw PortError("InvalidInput")
            checked(account,epoch)
            return rt.request(method,JSONObject().put("account_id",account).put("mode",mode)).also{checked(account,epoch)}
        }
        // Private inbox data bypasses the generic persistent UI cache. Only reads
        // may restore login and retry; sends run exactly once after the UI action.
        if(method in setOf("canvas.conversations.sync","canvas.conversation.read","canvas.recipients.search","canvas.course_users.sync")){
            return read(method,p,account,epoch).also{checked(account,epoch)}
        }
        if(method=="webdav.server.remove")return synchronized(rt.authGuard) {
            checked(account,epoch)
            val result=rt.request(method,p)
            rt.campusLogins.forgetWebdav(account,p.getString("id"),epoch)
            result
        }
        if(method in writes){
            checked(account,epoch)
            val result=rt.request(method,p)
            if(account!=rt.account() || epoch!=rt.accountEpoch)throw PortError("NeedsReconciliation")
            return result
        }
        if(method=="campus.uploadLocalFile")return uploadLocalFile(p,account,epoch)
        if(method in setOf("canvas.conversation.reply","canvas.conversation.create")){
            checked(account,epoch)
            val result=rt.request(method,p)
            // A successful send followed by an account switch is still a send.
            // Report uncertainty instead of suggesting it is safe to retry.
            if(account!=rt.account() || epoch!=rt.accountEpoch)throw PortError("NeedsReconciliation")
            return result
        }
        if(method=="campus.verifyDining")return verifyPortal(account,
            if(p.optString("service")=="power_history")"power_history" else "dining")
        if(method=="venues.visibleLogin" && rt.visiblePage.hasForeground() && !rt.campusLogins.canRestoreVenue(account)){
            // Only a password the school just accepted is saved for the hidden login. If this
            // sign-in cannot finish natively (2FA, network), the school's own page remains.
            // A suspended password is not tried again; the person types the current one.
            try{login("ecard",account,rt.campusLogins.venuePasswordSuspended(account))}catch(e:PortError){
                if(e.code in setOf("Cancelled","InvalidCredentials","AccountChanged"))throw e
            }
            checked(account,epoch)
        }
        if(method.startsWith("venues."))return venues.call(method.removePrefix("venues."),p).also{checked(account,epoch)}
        if(method=="campus.cached") {
            val source=p.getString("method"); require(source in reads);p.remove("method")
            if(source.startsWith("community.tea."))rt.campusLogins.requireForumConsent(account)
            return rt.request("storage.get",JSONObject().put("key",cacheKey(source,p))).also{checked(account,epoch)}
        }
        if(method in reads){
            val result=read(method,p,account,epoch);checked(account,epoch)
            if(result!=null && result.toString().length<=512*1024){
                rt.request("storage.set",JSONObject().put("key",cacheKey(method,p)).put("value",result))
            }
            return result
        }
        if(method=="forum.search")return read("community.tea.search",p,account,epoch).also{checked(account,epoch)}
        if(method=="forum.reconcile")return rt.request("community.tea.reconcile",p).also{checked(account,epoch)}
        if(method=="forum.publish" || method=="forum.reply") {
            val content=p.getString("content").trim()
            require(content.length in 1..8000)
            val target=if(method=="forum.publish") "分区 #"+p.getLong("division_id") else "树洞 #"+p.getLong("hole_id")
            confirm(if(method=="forum.publish")"发布匿名树洞" else "发送回复", "$target\n\n$content")
            checked(account,epoch)
            return rt.request(if(method=="forum.publish")"community.tea.publish" else "community.tea.reply",p).also{checked(account,epoch)}
        }
        if(method in setOf("canvas.material.download","fudan.cloud.download","webdav.download","fudan.notice.attachment.download")){
            val result=read(method,p,account,epoch) as JSONObject;checked(account,epoch)
            val id=result.getString("asset_id")
            rt.request("storage.set",JSONObject().put("key",cacheKey("asset",JSONObject().put("account_id",account).put("id",id))).put("value",JSONObject()
                .put("name",result.optString("name",if(method=="canvas.material.download")"课程文件" else "文件")).put("mime",result.optString("mime_type","application/octet-stream"))))
            return result
        }
        if(method=="campus.openFile")return openFile(account,epoch,p.optString("asset_id",p.optString("file_id")))
        throw PortError("MethodUnavailable")
    }
    /** Only a read can be retried after restoring its login. No UI is opened in the background. */
    private suspend fun read(method:String, p:JSONObject, account:String,epoch:Long):Any? {
        try{checked(account,epoch);return rt.request(method,p)}catch(e:PortError){
            if(e.code!="AuthenticationRequired" && !(method.startsWith("canvas.") && e.code=="ConfigurationRequired") &&
                !(method=="fudan.rooms" && e.code in setOf("PermissionDenied","SourceTransportUnavailable","Timeout")))throw e
            val service=when {
                method.startsWith("canvas.") -> "canvas"
                method.startsWith("fudan.cloud.") -> "cloud"
                method.startsWith("webdav.") && p.optString("id").matches(Regex("[0-9a-f]{12}")) -> "webdav:"+p.getString("id")
                method.startsWith("community.tea.") -> "forum"
                method.startsWith("fudan.ecard.") -> "ecard"
                method=="fudan.electricity" -> "power"
                method=="fudan.dining.occupancy" || method=="fudan.electricity.history" || method=="fudan.electricity.statistics" -> "dining"
                method=="fudan.bus" -> "bus"
                method=="fudan.rooms" -> "webvpn"
                method in setOf("fudan.semesters","fudan.timetable.sync","fudan.postgraduate.sync","fudan.student_association","fudan.grades","fudan.exams","fudan.gpa","fudan.pe") -> "academic"
                else -> throw e
            }
            checked(account,epoch)
            rt.campusLogins.connect(service,account,epoch=epoch)
            checked(account,epoch)
            return rt.request(method,p)
        }
    }
    /** Picks a local document and uploads it to a drive. Bytes stay on the native side. */
    private suspend fun uploadLocalFile(p:JSONObject,account:String,epoch:Long):Any? {
        val target=p.getString("target")
        if(target !in setOf("fudan.cloud.upload","webdav.upload"))throw PortError("MethodUnavailable")
        val uri=pickDocument()
        checked(account,epoch)
        val resolver=activity.contentResolver
        var name="文件"; var size=-1L
        withContext(Dispatchers.IO){
            resolver.query(uri,arrayOf(android.provider.OpenableColumns.DISPLAY_NAME,android.provider.OpenableColumns.SIZE),null,null,null)?.use {
                if(it.moveToFirst()){
                    it.getString(0)?.takeIf{n->n.isNotBlank()}?.let{n->name=n}
                    if(!it.isNull(1))size=it.getLong(1)
                }
            }
        }
        CampusUploadPolicy.checkLocalSize(size)
        val bytes=withContext(Dispatchers.IO){
            resolver.openInputStream(uri)?.use { input ->
                val out=java.io.ByteArrayOutputStream(); val buffer=ByteArray(65536)
                while(true){
                    val n=input.read(buffer); if(n<0)break
                    out.write(buffer,0,n)
                    CampusUploadPolicy.checkLocalSize(out.size().toLong())
                }
                out.toByteArray()
            } ?: throw PortError("FileUnavailable")
        }
        checked(account,epoch)
        val q=JSONObject().put("account_id",account).put("path",p.getString("path"))
            .put("name",name.take(200)).put("content_type",resolver.getType(uri)?:"application/octet-stream")
            .put("data_base64",Base64.encodeToString(bytes,Base64.NO_WRAP))
        if(target=="webdav.upload")q.put("id",p.getString("id"))
        val result=rt.request(target,q)
        if(account!=rt.account() || epoch!=rt.accountEpoch)throw PortError("NeedsReconciliation")
        return result
    }
    private suspend fun openFile(account:String,epoch:Long,id:String):JSONObject {
        if(id.isBlank())throw PortError("FileUnavailable")
        val reference=rt.request("storage.get",JSONObject().put("key",cacheKey("asset",JSONObject().put("account_id",account).put("id",id)))) as? JSONObject ?: throw PortError("FileUnavailable")
        val root=File(activity.cacheDir,"course-reader/"+digest(account)+"/"+digest(id)).apply { mkdirs() }
        val name=reference.getString("name").replace(Regex("[\\p{Cntrl}/\\\\:]"),"_").take(96).trim('.',' ').ifBlank { "课程文件" }
        val file=File(root,name); var offset=0L
        val temp=java.nio.file.Files.createTempFile(root.toPath(),".read-",".part").toFile()
        try {temp.outputStream().use { out->
            while(true) {
                checked(account,epoch)
                val chunk=rt.request("files.read",JSONObject().put("asset_id",id).put("account_id",account).put("offset",offset).put("length",131072)) as JSONObject
                val bytes=Base64.decode(chunk.getString("data"),Base64.DEFAULT)
                val next=chunk.getLong("next_offset")
                if(next!=offset+bytes.size || (!chunk.getBoolean("eof") && bytes.isEmpty()))throw PortError("FileUnavailable")
                out.write(bytes);offset=next
                if(chunk.getBoolean("eof"))break
            }
        }; java.nio.file.Files.move(temp.toPath(),file.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        } finally { temp.delete() }
        checked(account,epoch)
        val uri=FileProvider.getUriForFile(activity,activity.packageName+".coursefiles",file)
        withContext(Dispatchers.Main) {
            checked(account,epoch)
            val mime=reference.getString("mime").substringBefore(';').lowercase(java.util.Locale.ROOT)
            val extension=file.extension.lowercase(java.util.Locale.ROOT)
            if(mime=="application/pdf" || mime.startsWith("text/") || mime.startsWith("image/") ||
                extension in setOf("pdf","txt","md","csv","png","jpg","jpeg","webp")){
                activity.startActivity(Intent(activity,CampusFileReaderActivity::class.java)
                    .putExtra("path",file.absolutePath).putExtra("name",name).putExtra("mime",mime).putExtra("account_id",account))
            }else{
                val view=Intent(Intent.ACTION_VIEW).setDataAndType(uri,mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if(view.resolveActivity(activity.packageManager)==null)throw PortError("ViewerUnavailable")
                try { activity.startActivity(Intent.createChooser(view,"打开课程文件")) }
                catch(_:android.content.ActivityNotFoundException){throw PortError("ViewerUnavailable")}
            }
        }
        return JSONObject().put("opened",true)
    }
}
