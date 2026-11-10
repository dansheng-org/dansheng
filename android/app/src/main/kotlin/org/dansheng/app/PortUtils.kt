// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

object PortUtils {
    fun sha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun canonicalJson(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { key ->
            JSONObject.quote(key) + ":" + canonicalJson(value.get(key))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { i ->
            canonicalJson(value.get(i))
        }
        is String -> JSONObject.quote(value)
        is Number -> JSONObject.numberToString(value)
        is Boolean -> value.toString()
        else -> JSONObject.quote(value.toString())
    }

    fun sanitizeError(throwable: Throwable): PortError {
        return if (throwable is PortError) {
            throwable
        } else {
            val name = throwable.javaClass.simpleName
            val code = when {
                name.contains("Timeout") -> "DeadlineExceeded"
                name.contains("Security") -> "PermissionDenied"
                name.contains("State") -> "InvalidState"
                else -> "CoreUnavailable"
            }
            PortError(code)
        }
    }
}
