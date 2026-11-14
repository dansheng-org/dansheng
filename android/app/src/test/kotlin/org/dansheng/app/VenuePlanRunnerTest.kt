package org.dansheng.app

import kotlinx.coroutines.runBlocking
import org.dansheng.android.PortError
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VenuePlanRunnerTest {
    private fun item(id:Int)=JSONObject().put("court_id",id)
    private fun status(s:String)=JSONObject().put("status",s)

    @Test fun priorityStopsAfterOneSuccessPerPeriod()=runBlocking {
        val visited=mutableListOf<Int>()
        val result=VenuePlanRunner.run(listOf(listOf(item(1),item(2),item(3)),listOf(item(4))),{}, {}) {
            val id=it.getInt("court_id");visited+=id
            status(if(id==1)"gone" else "success")
        }
        assertEquals(listOf(1,2,4),visited)
        assertEquals(2,result.getJSONArray("successes").length())
    }
    @Test fun existingReservationStopsAllOtherPeriods()=runBlocking {
        var attempts=0
        VenuePlanRunner.run(listOf(listOf(item(1),item(2)),listOf(item(3))),{}, {}) {
            attempts++;status("existingReservation")
        }
        assertEquals(1,attempts)
    }
    @Test fun throttlingPausesBeforeNextCandidate()=runBlocking {
        val events=mutableListOf<String>()
        VenuePlanRunner.run(listOf(listOf(item(1),item(2))),{}, {events+="pause"}) {
            val id=it.getInt("court_id");events+="court$id"
            status(if(id==1)"throttled" else "success")
        }
        assertEquals(listOf("court1","pause","court2"),events)
    }
    @Test fun unknownWriteStopsWithoutFallback()=runBlocking {
        var attempts=0
        try {
            VenuePlanRunner.run(listOf(listOf(item(1),item(2))),{}, {}) {
                attempts++;throw PortError("NeedsReconciliation")
            }
            fail("must stop")
        }catch(e:PortError){assertEquals("NeedsReconciliation",e.code)}
        assertEquals(1,attempts)
    }
    @Test fun accountChangePreventsNextWrite()=runBlocking {
        var checks=0
        var attempts=0
        try {
            VenuePlanRunner.run(listOf(listOf(item(1),item(2))),{if(++checks>1)throw PortError("AccountChanged")}, {}) {
                attempts++;status("gone")
            }
            fail("must stop")
        }catch(e:PortError){assertEquals("AccountChanged",e.code)}
        assertEquals(1,attempts)
    }
}
