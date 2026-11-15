package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Shape and size rules for the saved eHall arrangement. The document is opaque here; Dart reads it leniently. */
internal object BoardLayoutStore {
    const val KEY="ui:ehall-layout"
    const val MAX_CHARS=16*1024

    /** The stored document as an object (a String result would reach Dart JSON-quoted), or null. */
    fun read(stored:String?):JSONObject? =
        stored?.let { try{JSONObject(it).takeIf{doc->doc.opt("tiles") is JSONArray}}catch(_:JSONException){null} }

    /** The text to store for [layout], or a PortError naming what is wrong with it. */
    fun validate(layout:JSONObject?):String {
        if(layout==null || layout.opt("tiles") !is JSONArray)throw PortError("InvalidLayout")
        val text=layout.toString()
        if(text.length>MAX_CHARS)throw PortError("LayoutTooLarge")
        return text
    }
}
