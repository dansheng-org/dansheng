package org.dansheng.app

import org.dansheng.android.PlatformDispatcher
import org.dansheng.android.PortError
import org.dansheng.android.PortReply
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/** Manual and scheduled entry points share the remote booking account. A second
 * entry point must not bypass the other entry point's durable uncertain outcome. */
internal class VenueWriteBoundary(private val delegate:PlatformDispatcher,private val jobs:()->JSONArray):PlatformDispatcher {
    override val capabilities get()=delegate.capabilities
    private val writers=ConcurrentHashMap.newKeySet<String>()
    private val ids=setOf("official.fudan-venues","official.fudan-sports")
    override fun dispatch(capability:String,mediated:JSONObject,reply:PortReply){
        val input=mediated.optJSONObject("input")
        val id=mediated.optJSONObject("principal")?.optString("id")?.removePrefix("plugin:")
        if(id !in ids || capability!="browser.request" || input?.optString("method")?.uppercase()!="POST"){
            delegate.dispatch(capability,mediated,reply);return
        }
        val account=input.optString("account_id")
        if(account.isBlank()){reply(Result.failure(PortError("PermissionDenied")));return}
        if(!writers.add(account)){reply(Result.failure(PortError("ApprovalRequired")));return}
        try {
            val entries=jobs()
            for(i in 0 until entries.length()){
                val job=entries.getJSONObject(i);val data=job.optJSONObject("data") ?: continue
                if(job.optString("state")=="needs_reconciliation" && data.optString("plugin_id") in ids &&
                    (data.optJSONObject("input")?.optString("account_id")==account || data.optString("account_id")==account)){
                    throw PortError("NeedsReconciliation")
                }
            }
            delegate.dispatch(capability,mediated){result->try{reply(result)}finally{writers.remove(account)}}
        }catch(e:Exception){writers.remove(account);reply(Result.failure(if(e is PortError)e else PortError("PlatformUnavailable")))}
    }
}
