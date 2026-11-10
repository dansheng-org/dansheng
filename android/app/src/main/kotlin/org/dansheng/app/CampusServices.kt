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
) {
    private val venues=CampusVenueHost(activity,rt,sheet)
    private val reads=setOf(
        "fudan.rooms","fudan.electricity","fudan.electricity.history","fudan.ecard.transactions","fudan.library.occupancy","fudan.dining.occupancy","fudan.bus","fudan.notices",
        "fudan.semesters","fudan.timetable.sync","fudan.postgraduate.sync","fudan.student_association","fudan.exams","fudan.grades","fudan.gpa","fudan.pe",
        "canvas.courses.sync","canvas.announcements.sync","canvas.assignments.sync","canvas.materials.sync","canvas.modules.sync","canvas.module_items.sync","canvas.folders.sync","canvas.pages.sync","canvas.page.read",
        "community.tea.divisions","community.tea.holes","community.tea.hole","community.tea.floors","community.danke.search","community.danke.group","community.danke.reviews",
    )
    private fun digest(s:String)=MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString(""){"%02x".format(it)}
    private fun cacheKey(m:String,p:JSONObject)= "campus:"+digest(m+"\n"+PortUtils.canonicalJson(p))
    private fun checked(account:String){if(account!=rt.account())throw PortError("AccountChanged")}
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
        if(method.startsWith("agent."))return CampusAgent.call(rt,method.removePrefix("agent."),supplied)
        val account=rt.account() ?: throw PortError("AccountRequired")
        if(supplied.has("account_id") && supplied.optString("account_id")!=account)throw PortError("AccountMismatch")
        val p=JSONObject(supplied.toString()).put("account_id",account)
        if(method.startsWith("agenda."))return CampusAgenda.call(rt,account,method.removePrefix("agenda."),p).also{checked(account)}
        if(method=="campus.login")return login(p.getString("service"),account,p.optBoolean("replace"))
        if(method=="campus.verifyDining")return verifyPortal(account,
            if(p.optString("service")=="power_history")"power_history" else "dining")
        if(method=="venues.visibleLogin" && rt.visiblePage.hasForeground() && !rt.campusLogins.canRestoreVenue(account)){
            // Only a password the school just accepted is saved for the hidden login. If this
            // sign-in cannot finish natively (2FA, network), the school's own page remains.
            // A suspended password is not tried again; the person types the current one.
            try{login("ecard",account,rt.campusLogins.venuePasswordSuspended(account))}catch(e:PortError){
                if(e.code in setOf("Cancelled","InvalidCredentials","AccountChanged"))throw e
            }
            checked(account)
        }
        if(method.startsWith("venues."))return venues.call(method.removePrefix("venues."),p).also{checked(account)}
        if(method=="campus.cached") {
            val source=p.getString("method"); require(source in reads);p.remove("method")
            return rt.request("storage.get",JSONObject().put("key",cacheKey(source,p))).also{checked(account)}
        }
        if(method in reads){
            val result=read(method,p,account);checked(account)
            if(result!=null && result.toString().length<=512*1024){
                rt.request("storage.set",JSONObject().put("key",cacheKey(method,p)).put("value",result))
            }
            return result
        }
        if(method=="forum.search")return read("community.tea.search",p,account).also{checked(account)}
        if(method=="forum.reconcile")return rt.request("community.tea.reconcile",p).also{checked(account)}
        if(method=="forum.publish" || method=="forum.reply") {
            val content=p.getString("content").trim()
            require(content.length in 1..8000)
            val target=if(method=="forum.publish") "分区 #"+p.getLong("division_id") else "树洞 #"+p.getLong("hole_id")
            confirm(if(method=="forum.publish")"发布匿名树洞" else "发送回复", "$target\n\n$content")
            checked(account)
            return rt.request(if(method=="forum.publish")"community.tea.publish" else "community.tea.reply",p).also{checked(account)}
        }
        if(method=="canvas.material.download"){
            val result=read(method,p,account) as JSONObject;checked(account)
            val id=result.getString("asset_id")
            rt.request("storage.set",JSONObject().put("key",cacheKey("asset",JSONObject().put("account_id",account).put("id",id))).put("value",JSONObject()
                .put("name",result.optString("name","课程文件")).put("mime",result.optString("mime_type","application/octet-stream"))))
            return result
        }
        if(method=="campus.openFile")return openFile(account,p.optString("asset_id",p.optString("file_id")))
        throw PortError("MethodUnavailable")
    }
    /** Only a read can be retried after restoring its login. No UI is opened in the background. */
    private suspend fun read(method:String, p:JSONObject, account:String):Any? {
        try{return rt.request(method,p)}catch(e:PortError){
            if(e.code!="AuthenticationRequired" && !(method.startsWith("canvas.") && e.code=="ConfigurationRequired") &&
                !(method=="fudan.rooms" && e.code in setOf("PermissionDenied","SourceTransportUnavailable","Timeout")))throw e
            val service=when {
                method.startsWith("canvas.") -> "canvas"
                method.startsWith("community.tea.") -> "forum"
                method=="fudan.ecard.transactions" -> "ecard"
                method=="fudan.electricity" -> "power"
                method=="fudan.dining.occupancy" || method=="fudan.electricity.history" -> "dining"
                method=="fudan.bus" -> "bus"
                method=="fudan.rooms" -> "webvpn"
                method in setOf("fudan.semesters","fudan.timetable.sync","fudan.student_association","fudan.grades","fudan.exams","fudan.gpa","fudan.pe") -> "academic"
                else -> throw e
            }
            checked(account)
            rt.campusLogins.connect(service,account)
            checked(account)
            return rt.request(method,p)
        }
    }
    private suspend fun openFile(account:String,id:String):JSONObject {
        if(id.isBlank())throw PortError("FileUnavailable")
        val reference=rt.request("storage.get",JSONObject().put("key",cacheKey("asset",JSONObject().put("account_id",account).put("id",id)))) as? JSONObject ?: throw PortError("FileUnavailable")
        val root=File(activity.cacheDir,"course-reader/"+digest(account)+"/"+digest(id)).apply { mkdirs() }
        val name=reference.getString("name").replace(Regex("[\\p{Cntrl}/\\\\:]"),"_").take(96).trim('.',' ').ifBlank { "课程文件" }
        val file=File(root,name); var offset=0L
        val temp=java.nio.file.Files.createTempFile(root.toPath(),".read-",".part").toFile()
        try {temp.outputStream().use { out->
            while(true) {
                checked(account)
                val chunk=rt.request("files.read",JSONObject().put("asset_id",id).put("account_id",account).put("offset",offset).put("length",131072)) as JSONObject
                val bytes=Base64.decode(chunk.getString("data"),Base64.DEFAULT)
                val next=chunk.getLong("next_offset")
                if(next!=offset+bytes.size || (!chunk.getBoolean("eof") && bytes.isEmpty()))throw PortError("FileUnavailable")
                out.write(bytes);offset=next
                if(chunk.getBoolean("eof"))break
            }
        }; java.nio.file.Files.move(temp.toPath(),file.toPath(),java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        } finally { temp.delete() }
        checked(account)
        val uri=FileProvider.getUriForFile(activity,activity.packageName+".coursefiles",file)
        withContext(Dispatchers.Main) {
            checked(account)
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
