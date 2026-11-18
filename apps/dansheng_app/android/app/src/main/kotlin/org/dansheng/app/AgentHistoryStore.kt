// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.KeystoreVault
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException

internal fun requireAgentAccount(account: String?, params: JSONObject) {
    val suppliedAccount = params.opt("account_id")
    if (suppliedAccount !== JSONObject.NULL && suppliedAccount !is String) throw PortError("InvalidInput")
    if ((suppliedAccount as? String) != account) throw PortError("AccountMismatch")
}

/** Local Agent transcripts. Call with the verified account while holding RuntimeHost.authGuard. */
internal class AgentHistoryStore(
    private val read: (String) -> String?,
    private val exists: (String) -> Boolean,
    private val write: (String, String) -> Unit,
    private val remove: (String) -> Unit,
) {
    constructor(vault: KeystoreVault) : this(vault::get, vault::contains, vault::set, vault::delete)

    fun call(account: String?, method: String, params: JSONObject): Any? {
        val scope = if (account == null) "guest" else "account/$account"
        val history = History("agent-history/v1/$scope")
        return when (method) {
            "agent.history.list" -> {
                params.fields(setOf("account_id"))
                history.list()
            }
            "agent.history.get" -> {
                params.fields(setOf("account_id", "id"))
                history.get(id(params.opt("id")))
            }
            "agent.history.save" -> {
                params.fields(setOf("account_id", "conversation", "create"))
                val create = params.opt("create") as? Boolean ?: invalid()
                val record = params.opt("conversation") as? JSONObject ?: invalid()
                val id = validateRecord(record)
                val created = history.save(id, encode(record), create)
                JSONObject().put("saved", true).put("created", created)
            }
            "agent.history.rename" -> {
                params.fields(setOf("account_id", "id", "title", "updated_at"))
                history.rename(id(params.opt("id")), title(params), timestamp(params))
                JSONObject().put("saved", true)
            }
            "agent.history.delete" -> {
                params.fields(setOf("account_id", "id"))
                history.delete(id(params.opt("id")))
                JSONObject().put("deleted", true)
            }
            else -> throw PortError("MethodUnavailable")
        }
    }

    private inner class History(private val prefix: String) {
        private val indexKey = "$prefix/index"
        private fun recordKey(id: String) = "$prefix/thread/$id"

        fun list(): JSONArray {
            val summaries = index().mapNotNull { id ->
                record(id)?.let {
                    JSONObject().put("id", id).put("title", it.getString("title"))
                        .put("updated_at", it.getLong("updated_at"))
                }
            }
            return JSONArray(summaries.sortedByDescending { it.getLong("updated_at") })
        }

        fun get(id: String): JSONObject? = if (id in index()) record(id) else null

        fun save(id: String, encoded: String, create: Boolean): Boolean {
            val ids = index()
            val key = recordKey(id)
            val present = id in ids && record(id) != null
            if (!create) {
                if (!present) throw PortError("ConversationMissing")
                storage { write(key, encoded) }
                return false
            }
            if (present) return false

            val liveIds = storage { ids.filter { exists(recordKey(it)) } }
            if (liveIds.size >= MAX_THREADS) throw PortError("AgentHistoryFull")
            try {
                storage { write(key, encoded) }
                replaceIndex(ids, liveIds + id)
            } catch (error: PortError) {
                runCatching { remove(key) }
                throw error
            }
            return true
        }

        fun rename(id: String, title: String, updatedAt: Long) {
            val record = get(id) ?: throw PortError("ConversationMissing")
            record.put("title", title).put("updated_at", updatedAt)
            val encoded = encode(record)
            storage { write(recordKey(id), encoded) }
        }

        fun delete(id: String) {
            val ids = index()
            // Removing the record first lets a retry finish removing its index entry.
            storage { remove(recordKey(id)) }
            if (id in ids) replaceIndex(ids, ids - id)
        }

        private fun index(): List<String> = storage {
            val encoded = read(indexKey) ?: return@storage emptyList()
            val value = JSONArray(encoded)
            check(value.length() <= MAX_THREADS)
            val ids = List(value.length()) { id(value.opt(it)) }
            check(ids.toSet().size == ids.size)
            ids
        }

        private fun record(id: String): JSONObject? = storage {
            val encoded = read(recordKey(id)) ?: return@storage null
            JSONObject(encoded).also { check(validateRecord(it) == id) }
        }

        private fun writeIndex(ids: List<String>) {
            if (ids.isEmpty()) remove(indexKey) else write(indexKey, JSONArray(ids).toString())
        }

        private fun replaceIndex(previous: List<String>, next: List<String>) {
            storage {
                try {
                    writeIndex(next)
                } catch (error: Exception) {
                    // SharedPreferences can update its in-memory value before a failed commit.
                    runCatching { writeIndex(previous) }
                    throw error
                }
            }
        }
    }

    private companion object {
        const val MAX_THREADS = 100
        const val MAX_RECORD_BYTES = 220 * 1024
        const val MAX_TURNS = 1024
        const val MAX_ATTACHMENTS = 3
        const val MAX_WEB_LINKS = 64
        const val MAX_CAMPUS_LINKS = 24
        const val MAX_TIMESTAMP = 8_640_000_000_000_000L // Dart DateTime limit.

        val threadId = Regex("[0-9a-f]{32}")
        val linkAuthority = Regex("[A-Za-z0-9._~-]+(?::([0-9]+))?")
        val recordFields = setOf("id", "title", "updated_at", "turns")
        val turnFields = setOf("question", "remember", "attachments", "web_links")
        val optionalTurnFields = setOf("answer", "notice", "model", "destination", "campus_links")
        val linkFields = setOf("title", "url")

        fun validateRecord(record: JSONObject): String {
            record.fields(recordFields)
            val id = id(record.opt("id"))
            title(record)
            timestamp(record)
            record.array("turns", MAX_TURNS) { validateTurn(it as? JSONObject ?: invalid()) }
            return id
        }

        fun validateTurn(turn: JSONObject) {
            turn.fields(turnFields, optionalTurnFields)
            // Transcript text and the destination label share the encoded record limit.
            if (turn.opt("question") !is String) invalid()
            for (key in listOf("answer", "notice", "destination")) {
                if (turn.has(key) && turn.opt(key) !is String) invalid()
            }
            if (turn.has("model")) turn.string("model", 256)
            if (turn.opt("remember") !is Boolean) invalid()
            turn.array("attachments", MAX_ATTACHMENTS) { item ->
                val name = item as? String ?: invalid()
                if (name.isBlank() || name.length > 255 || name == "." || name == ".." ||
                    name.any { it == '/' || it == '\\' || it == ':' || Character.isISOControl(it) }
                ) invalid()
            }
            turn.array("web_links", MAX_WEB_LINKS) { validateWebLink(linkUri(it)) }
            if (turn.has("campus_links")) {
                turn.array("campus_links", MAX_CAMPUS_LINKS) { validateCampusLink(linkUri(it)) }
            }
        }

        fun linkUri(value: Any?): URI {
            val link = value as? JSONObject ?: invalid()
            link.fields(linkFields)
            if (link.string("title", 512).isBlank()) invalid()
            return try {
                URI(link.string("url", 2048))
            } catch (_: URISyntaxException) {
                invalid()
            }
        }

        fun validateWebLink(uri: URI) {
            if (uri.scheme != "https" || uri.rawUserInfo != null) invalid()
            val port = if (uri.host != null) uri.port else {
                // URI.host rejects some valid reg-names (for example, hosts with underscores).
                val authority = linkAuthority.matchEntire(uri.rawAuthority.orEmpty()) ?: invalid()
                authority.groups[1]?.value?.let { it.toIntOrNull() ?: invalid() } ?: -1
            }
            if (port != -1 && port !in 1..65535) invalid()
        }

        fun validateCampusLink(uri: URI) {
            val path = uri.rawPath.orEmpty()
            if (uri.scheme != "dansheng" || uri.rawAuthority != "agent" ||
                uri.rawQuery != null || uri.rawFragment != null || !path.startsWith('/') || path.length < 2
            ) invalid()
        }

        fun id(value: Any?): String = (value as? String)?.takeIf(threadId::matches) ?: invalid()

        fun title(record: JSONObject): String = record.string("title", 72).takeUnless(String::isBlank)
            ?: invalid()

        fun timestamp(record: JSONObject): Long {
            val raw = record.opt("updated_at") as? Number ?: invalid()
            if (raw !is Int && raw !is Long) invalid()
            val value = raw.toLong()
            if (value !in 0..MAX_TIMESTAMP) invalid()
            return value
        }

        fun JSONObject.fields(required: Set<String>, optional: Set<String> = emptySet()) {
            if (!required.all(::has) || keys().asSequence().any { it !in required && it !in optional }) {
                invalid()
            }
        }

        fun JSONObject.string(key: String, maxLength: Int): String =
            (opt(key) as? String)?.takeIf { it.length <= maxLength } ?: invalid()

        fun JSONObject.array(key: String, maxLength: Int, validateItem: (Any?) -> Unit) {
            val value = opt(key) as? JSONArray ?: invalid()
            if (value.length() > maxLength) invalid()
            for (i in 0 until value.length()) validateItem(value.opt(i))
        }

        fun encode(record: JSONObject): String {
            val encoded = record.toString()
            if (encoded.length > MAX_RECORD_BYTES) throw PortError("AgentConversationTooLarge")
            val size = try {
                Charsets.UTF_8.newEncoder().encode(CharBuffer.wrap(encoded)).remaining()
            } catch (_: CharacterCodingException) {
                invalid()
            }
            if (size > MAX_RECORD_BYTES) throw PortError("AgentConversationTooLarge")
            return encoded
        }

        fun invalid(): Nothing = throw PortError("InvalidInput")

        inline fun <T> storage(operation: () -> T): T = try {
            operation()
        } catch (_: Exception) {
            throw PortError("AgentHistoryUnavailable")
        }
    }
}
