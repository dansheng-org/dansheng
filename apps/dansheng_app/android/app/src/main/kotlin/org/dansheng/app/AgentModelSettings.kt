// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.KeystoreVault
import org.dansheng.android.PortError
import org.json.JSONObject
import java.net.URI

/** One device-level model profile, accessible only through the local App bridge. */
internal object AgentModelSettings {
    private const val KEY = "agent-model-settings/v1"

    fun call(vault: KeystoreVault, method: String, params: JSONObject): JSONObject? = when (method) {
        "agent.settings.get" -> vault.get(KEY)?.let { JSONObject(it) }
        "agent.settings.set" -> {
            val fields = listOf("provider", "base_url", "model", "api_key")
            if (fields.any { params.opt(it) !is String }) throw PortError("InvalidInput")
            val provider = params.getString("provider")
            val address = params.getString("base_url")
            val model = params.getString("model")
            val key = params.getString("api_key")
            val searchKey = params.opt("search_api_key")
            val modelLabel = params.opt("model_label")
            if (provider !in setOf("openAi", "anthropic") || address.length !in 1..2048 ||
                model.length !in 1..256 || model.isBlank() || key.length !in 1..4096 ||
                key.any { it.code !in 33..126 }
            ) throw PortError("InvalidInput")
            if (searchKey != null && (searchKey !is String ||
                searchKey.length !in 1..4096 || searchKey.any { it.code !in 33..126 })
            ) throw PortError("InvalidInput")
            if (modelLabel != null && (modelLabel !is String ||
                modelLabel.isBlank() || modelLabel.length > 256 || modelLabel.any { Character.isISOControl(it) })
            ) throw PortError("InvalidInput")
            val uri = try { URI(address) } catch (_: Exception) { throw PortError("InvalidInput") }
            if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.rawUserInfo != null ||
                uri.rawQuery != null || uri.rawFragment != null ||
                (uri.port != -1 && uri.port !in 1..65535)
            ) throw PortError("InvalidInput")
            vault.set(KEY, JSONObject().also { value ->
                fields.forEach { field -> value.put(field, params.getString(field)) }
                if (searchKey != null) value.put("search_api_key", searchKey)
                if (modelLabel != null) value.put("model_label", modelLabel)
            }.toString())
            JSONObject().put("saved", true)
        }
        "agent.settings.clear" -> {
            vault.delete(KEY)
            JSONObject().put("cleared", true)
        }
        else -> throw PortError("MethodUnavailable")
    }
}
