package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId

/** The organizer is profile-local. Never list or edit items outside this account's mobile index. */
internal object CampusAgenda {
    private val zone=ZoneId.of("Asia/Shanghai")
    @Synchronized fun call(rt:RuntimeHost,account:String,action:String,p:JSONObject):Any {
        if(rt.account()!=account)throw PortError("AccountChanged")
        val key="mobile-agenda-v1:"+account
        val ids=rt.request("storage.get",JSONObject().put("key",key)) as? JSONArray ?: JSONArray()
        fun save(rows:JSONArray){rt.request("storage.set",JSONObject().put("key",key).put("value",rows))}
        return when(action) {
            "list"->{
                val day=LocalDate.parse(p.getString("date"))
                val lo=day.atStartOfDay(zone).toInstant(); val hi=day.plusDays(1).atStartOfDay(zone).toInstant()
                val found=JSONArray()
                // Index stores event ids and intervals, avoiding an all-profile calendar scan.
                for(i in 0 until ids.length()) {
                    val row=ids.optJSONObject(i) ?: continue
                    if(OffsetDateTime.parse(row.getString("start_at")).toInstant()<hi && OffsetDateTime.parse(row.getString("end_at")).toInstant()>lo){
                        try{found.put(rt.request("calendar.get",JSONObject().put("id",row.getString("id"))))}
                        catch(e:PortError){if(e.code!="NotFound")throw e}
                    }
                }
                found
            }
            "add"->{
                val title=p.getString("title").trim();require(title.length in 1..200 && ids.length()<4096)
                val data=JSONObject().put("title",title).put("timezone",zone.id)
                    .put("start_at",p.getString("start_at")).put("end_at",p.getString("end_at"))
                val made=rt.request("calendar.create",data) as JSONObject
                val id=made.getString("id")
                try{save(ids.put(JSONObject().put("id",id).put("start_at",data.getString("start_at")).put("end_at",data.getString("end_at"))))}
                catch(e:Exception){rt.request("calendar.delete",JSONObject().put("id",id));throw e}
                made
            }
            "remove"->{
                val id=p.getString("id")
                require((0 until ids.length()).any { ids.getJSONObject(it).optString("id")==id })
                rt.request("calendar.delete",JSONObject().put("id",id))
                save(JSONArray((0 until ids.length()).map{ids.getJSONObject(it)}.filter{it.optString("id")!=id}))
                JSONObject().put("deleted",true)
            }
            else->throw PortError("MethodUnavailable")
        }
    }
}
