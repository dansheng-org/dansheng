// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject

/** Orchestrates already reviewed candidates; booking policy and journals remain in Core. */
internal object VenuePlanRunner {
    suspend fun run(
        plans:List<List<JSONObject>>,
        checked:()->Unit,
        pause:suspend ()->Unit,
        attempt:suspend (JSONObject)->JSONObject,
    ):JSONObject {
        val successes=JSONArray()
        var message="未成功预约"
        for(choices in plans){
            for(choice in choices){
                checked()
                val result=try {attempt(choice)}catch(e:PortError){
                    if(e.code in setOf("CourtOccupied","SlotUnavailable")){message="这个场地已不可约";continue}
                    throw e
                }
                checked()
                val status=result.optString("status")
                message=result.optString("message",status)
                if(status in setOf("uncertain","needs_reconciliation"))throw PortError("NeedsReconciliation")
                if(status in setOf("success","OK")){successes.put(choice);break}
                if(status=="existingReservation")return JSONObject().put("successes",successes).put("message",message)
                if(status=="throttled")pause()
            }
        }
        return JSONObject().put("successes",successes).put("message",message)
    }
}
