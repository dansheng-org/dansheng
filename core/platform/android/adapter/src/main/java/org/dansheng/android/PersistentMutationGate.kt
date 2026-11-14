// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Generic durable duplicate guard. The host supplies CURRENT concrete approval checks
 * against its approved operation; no approval is accepted from plugin JSON. Store only
 * hashes, never session handles, form bodies, credentials or full operation keys.
 */
class PersistentMutationGate(context: Context,
    private val approvedNow: (principal: String, account: String, request: JSONObject, now: Long) -> Boolean
) : MutationAuthorizer {
    companion object { private val lock = Any() }
    private val prefs = context.getSharedPreferences("dansheng-mutations-v1", Context.MODE_PRIVATE)
    private fun key(principal: String, account: String, operation: String): String {
        val bytes = JSONArray().put(principal).put(account).put(operation).toString().toByteArray(Charsets.UTF_8)
        return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
    /** SharedPreferences is process-private; instantiate one gate in the dedicated browser process. */
    override fun allowed(principal: String, account: String, request: JSONObject): Boolean = synchronized(lock) {
        val operation = request.optString("mutation_key")
        if (operation.isBlank() || operation.length > 512) throw PortError("InvalidMutationKey")
        val now = System.currentTimeMillis()
        if (request.optLong("deadline_epoch_ms", 0) <= now) throw PortError("DeadlineExceeded")
        val key = key(principal, account, operation)
        if (prefs.contains(key)) throw PortError("NeedsReconciliation")
        if (!approvedNow(principal, account, request, now)) return@synchronized false
        if (!prefs.edit().putString(key, "in_flight").commit()) throw PortError("StorageError")
        true
    }
    /** HOST ONLY. Clear solely after authoritative reconciliation proves no effect AND
     * concrete approval still permits a new attempt. Empty/lagging history is insufficient.
     */
    fun clearAfterAuthoritativeAbsence(principal: String, account: String, operation: String) = synchronized(lock) {
        if (!prefs.edit().remove(key(principal, account, operation)).commit()) throw PortError("StorageError")
    }
}
