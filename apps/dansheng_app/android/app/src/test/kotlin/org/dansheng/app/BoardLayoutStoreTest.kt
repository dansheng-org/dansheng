package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class BoardLayoutStoreTest {
    private fun layout(tiles:Int=2)=JSONObject().put("v",1).put("tiles",JSONArray().apply {
        repeat(tiles){put(JSONObject().put("id","tile$it").put("size","small").put("shown",true))}
    })

    private fun code(block:()->Unit):String {
        try{block()}catch(e:PortError){return e.code}
        fail("expected PortError");return ""
    }

    @Test fun roundTripKeepsTheDocument() {
        val text=BoardLayoutStore.validate(layout())
        val back=BoardLayoutStore.read(text)!!
        assertEquals(2,back.getJSONArray("tiles").length())
        assertEquals("tile1",back.getJSONArray("tiles").getJSONObject(1).getString("id"))
    }

    @Test fun nothingStoredOrCorruptReadsAsNull() {
        assertNull(BoardLayoutStore.read(null))
        assertNull(BoardLayoutStore.read("not json"))
        assertNull(BoardLayoutStore.read("{\"v\":1}"))
        assertNull(BoardLayoutStore.read("{\"tiles\":\"no\"}"))
    }

    @Test fun rejectsMissingOrMalformedLayouts() {
        assertEquals("InvalidLayout",code{BoardLayoutStore.validate(null)})
        assertEquals("InvalidLayout",code{BoardLayoutStore.validate(JSONObject().put("v",1))})
        assertEquals("InvalidLayout",code{BoardLayoutStore.validate(JSONObject().put("tiles",JSONObject()))})
    }

    @Test fun rejectsOversizedLayouts() {
        assertEquals("LayoutTooLarge",code{BoardLayoutStore.validate(layout(2000))})
    }
}
