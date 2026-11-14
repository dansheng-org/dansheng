package org.dansheng.app.checks

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.pdf.PdfDocument
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import org.dansheng.app.CampusAgenda
import org.dansheng.app.CampusFileReaderActivity
import org.dansheng.app.PortUtils
import org.dansheng.app.RuntimeHost
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

internal fun verifyCampusData(test:Instrumentation,rt:RuntimeHost,out:Bundle){
    val account="reader-"+UUID.randomUUID().toString().take(8)
    rt.setAccount(account)
    val day="2099-03-12"
    val event=CampusAgenda.call(rt,account,"add",JSONObject().put("title","线下资料讨论").put("start_at",day+"T13:00:00+08:00").put("end_at",day+"T14:00:00+08:00")) as JSONObject
    val events=CampusAgenda.call(rt,account,"list",JSONObject().put("date",day)) as JSONArray
    check(events.length()==1 && events.getJSONObject(0).getString("id")==event.getString("id"))
    check((CampusAgenda.call(rt,account,"list",JSONObject().put("date","2099-03-13")) as JSONArray).length()==0)
    CampusAgenda.call(rt,account,"remove",JSONObject().put("id",event.getString("id")))
    check((CampusAgenda.call(rt,account,"list",JSONObject().put("date",day)) as JSONArray).length()==0)
    out.putString("personal_agenda","created, day-filtered, removed")
    val folder=File(test.targetContext.cacheDir,"course-reader/"+PortUtils.sha256(account.toByteArray(Charsets.UTF_8))+"/synthetic").apply{mkdirs()}
    fun nodes(view:View):Sequence<View> = sequence {
        yield(view); if(view is ViewGroup)for(i in 0 until view.childCount)yieldAll(nodes(view.getChildAt(i)))
    }
    fun checkReader(file:File,mime:String,match:(View)->Boolean){
        val intent=Intent(test.targetContext,CampusFileReaderActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("account_id",account).putExtra("path",file.absolutePath).putExtra("name",file.name).putExtra("mime",mime)
        val activity=test.startActivitySync(intent) as Activity
        var rendered=false
        try {
            val timeout=android.os.SystemClock.elapsedRealtime()+20000
            while(!rendered && android.os.SystemClock.elapsedRealtime()<timeout){
                test.runOnMainSync { rendered=nodes(activity.window.decorView).any(match) }
                if(!rendered)Thread.sleep(80)
            }
            check(rendered)
        }finally{test.runOnMainSync{activity.finish()}}
    }
    try{
        val txt=File(folder,"handout.txt").apply{writeText("教学资料正文 012345")}
        checkReader(txt,"text/plain"){it is TextView && it.text.contains("教学资料正文 012345")}
        val pdf=File(folder,"handout.pdf")
        val document=PdfDocument()
        try{val page=document.startPage(PdfDocument.PageInfo.Builder(320,480,1).create())
            page.canvas.drawText("COURSE 1",24f,55f,android.graphics.Paint().apply{textSize=18f})
            document.finishPage(page);pdf.outputStream().use(document::writeTo)
        }finally{document.close()}
        checkReader(pdf,"application/pdf"){it is ImageView && it.drawable!=null && it.width>80 && it.height>100}
        out.putString("course_reader","text and PDF rendered from scoped private cache")
    }finally{folder.deleteRecursively()}
}
