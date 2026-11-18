// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.KeystoreVault
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException

/** Local grants for one account or guest. Call while holding RuntimeHost.authGuard. */
internal object AgentApprovalStore {
    private const val MAX_DESTINATIONS = 32
    private const val MAX_URL_LENGTH = 2048
    private val providers = setOf("openAi", "anthropic")
    private val permissions = setOf("learning", "files", "forum", "campus", "web", "web_provider", "attachment")

    fun call(vault: KeystoreVault, account: String?, method: String, params: JSONObject): Any {
        val fields = when (method) {
            "agent.approvals.get" -> setOf("account_id", "destination")
            "agent.approvals.allow", "agent.approvals.revoke" ->
                setOf("account_id", "destination", "permission")
            "agent.approvals.clear" -> setOf("account_id")
            else -> throw PortError("MethodUnavailable")
        }
        if (params.keys().asSequence().toSet() != fields) invalid()
        val suppliedAccount = when (val value = params.opt("account_id")) {
            is String -> value
            JSONObject.NULL -> null
            else -> invalid()
        }
        if (suppliedAccount != account) throw PortError("AccountMismatch")

        val scope = if (account == null) "guest" else "account/$account"
        val key = "agent-approvals/v1/$scope"
        if (method == "agent.approvals.clear") {
            storage { vault.delete(key) }
            return JSONObject().put("cleared", true)
        }

        val destination = destination(params.opt("destination"))
        val permission = if (method == "agent.approvals.get") null
            else permission(params.opt("permission"))
        val previous = storage { vault.get(key) }
        val grants = storage { read(previous) }
        val allowed = grants[destination].orEmpty()
        if (permission == null) return JSONArray(allowed)

        val updated = if (method == "agent.approvals.allow") allowed + permission else allowed - permission
        if (updated != allowed) {
            if (updated.isEmpty()) {
                grants.remove(destination)
            } else {
                if (destination !in grants && grants.size >= MAX_DESTINATIONS) {
                    throw PortError("AgentApprovalsFull")
                }
                grants[destination] = updated
            }
            storage {
                try {
                    if (grants.isEmpty()) vault.delete(key)
                    else vault.set(key, encode(grants))
                } catch (error: Exception) {
                    // A failed preferences commit may have already changed the in-memory value.
                    runCatching {
                        if (previous == null) vault.delete(key) else vault.set(key, previous)
                    }
                    throw error
                }
            }
        }
        return JSONObject().put("saved", true)
    }

    private fun read(encoded: String?): MutableMap<String, Set<String>> {
        val grants = mutableMapOf<String, Set<String>>()
        if (encoded == null) return grants
        val value = JSONObject(encoded)
        check(value.length() <= MAX_DESTINATIONS)
        for (key in value.keys()) {
            destination(key)
            val allowed = value.getJSONArray(key)
            check(allowed.length() in 1..permissions.size)
            grants[key] = buildSet {
                for (index in 0 until allowed.length()) check(add(permission(allowed.opt(index))))
            }
        }
        return grants
    }

    private fun encode(grants: Map<String, Set<String>>): String = JSONObject().apply {
        for ((destination, allowed) in grants) put(destination, JSONArray(allowed))
    }.toString()

    private fun destination(value: Any?): String {
        val destination = value as? String ?: invalid()
        val separator = destination.indexOf(':')
        if (separator !in 1..9 || destination.substring(0, separator) !in providers ||
            destination.length - separator - 1 > MAX_URL_LENGTH
        ) invalid()
        val address = destination.substring(separator + 1)
        if (address.any { it.code !in 33..126 }) invalid()
        val uri = try {
            URI(address)
        } catch (_: URISyntaxException) {
            invalid()
        }
        if (uri.scheme != "https" || uri.host.isNullOrEmpty() || uri.rawUserInfo != null ||
            uri.rawQuery != null || uri.rawFragment != null || uri.rawAuthority.endsWith(':') ||
            (uri.port != -1 && uri.port !in 1..65535) || uri.rawPath.endsWith('/')
        ) invalid()
        return destination
    }

    private fun permission(value: Any?): String =
        (value as? String)?.takeIf { it in permissions } ?: invalid()

    private fun invalid(): Nothing = throw PortError("InvalidInput")

    private inline fun <T> storage(action: () -> T): T = try {
        action()
    } catch (_: Exception) {
        throw PortError("AgentApprovalsUnavailable")
    }
}
