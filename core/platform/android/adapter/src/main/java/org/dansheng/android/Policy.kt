// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import java.net.URI
import java.util.UUID

class PortError(val code: String) : RuntimeException(code)

fun origin(url: String): String {
    val u = try { URI(url) } catch (_: Exception) { throw PortError("InvalidUrl") }
    if (u.scheme != "https" || u.host == null || u.rawUserInfo != null || u.rawFragment != null ||
        u.rawPath.split('/').any { it == ".." || it == "." } || url.contains('\\')) throw PortError("InvalidUrl")
    return "https://${u.host.lowercase()}" + if (u.port == -1 || u.port == 443) "" else ":${u.port}"
}

/** Only unchanged caller query fields can survive a page response. Removed,
 * duplicated or changed identity filters must never be reconstructed, and a
 * redirect cannot add authentication material to the returned URL.
 */
internal fun safePageResponseUrl(url: String, requested: String, expectedOrigin: String): String {
    if (origin(url.substringBefore('#')) != expectedOrigin || origin(requested) != expectedOrigin)
        throw PortError("OriginMismatch")
    val actual = URI(url)
    val original = URI(requested)
    fun fields(query: String?): Map<String, List<String>> = (query ?: "").split('&')
        .filter { it.isNotEmpty() }.groupBy { field ->
            java.net.URLDecoder.decode(field.substringBefore('='), "UTF-8")
        }
    val before = fields(original.rawQuery)
    val safe = fields(actual.rawQuery).filter { (key, values) ->
        val name = key.lowercase()
        key.none { it.isISOControl() } &&
            listOf("token", "ticket", "signature", "password", "credential", "session", "secret", "auth")
                .none { name.contains(it) } &&
            name !in setOf("api_key", "apikey", "sig", "verifier") &&
            !name.startsWith("x-amz-") && !name.startsWith("x-goog-") &&
            before[key]?.sorted() == values.sorted()
    }.values.flatten().joinToString("&")
    return expectedOrigin + (actual.rawPath ?: "/") + if (safe.isEmpty()) "" else "?$safe"
}

data class Authority(val principalId: String, val owner: Boolean, val capabilities: Set<String>,
    val accounts: Set<String>, val origins: Set<String>, val expiresAt: Long? = null) {
    fun check(capability: String, account: String, url: String?, now: Long) {
        if (account.isBlank() || principalId.isBlank()) throw PortError("PermissionDenied")
        if (!owner && (capability !in capabilities || account !in accounts ||
                    (expiresAt != null && now >= expiresAt))) throw PortError("PermissionDenied")
        if (url != null && !owner && origin(url) !in origins) throw PortError("PermissionDenied")
        if (url != null) origin(url)
    }
}

/** One account per dedicated WebView process/profile. Call reset only AFTER cookie/storage clearing. */
class SessionLedger {
    data class Session(val handle: String, val account: String, val origin: String, val generation: Long)
    private var active: Session? = null
    private var generation = 0L
    var resetting = false; private set
    @Synchronized fun issue(account: String, url: String): Session {
        if (resetting) throw PortError("SessionResetting")
        if (active != null) throw PortError("AccountBusy")
        return Session(UUID.randomUUID().toString(), account, origin(url), ++generation).also { active = it }
    }
    @Synchronized fun require(account: String, handle: String): Session {
        val s = active ?: throw PortError("AuthenticationRequired")
        if (resetting || s.account != account || s.handle != handle) throw PortError("SessionOwnershipMismatch")
        return s
    }
    @Synchronized fun status(account: String): Session? = active?.takeIf { !resetting && it.account == account }
    @Synchronized fun beginReset() { active = null; generation++; resetting = true }
    @Synchronized fun finishReset() { resetting = false }
}

data class WakeSpec(val jobId: String, val account: String?, val owner: String, val runAt: Long,
    val deadline: Long, val generation: String = UUID.randomUUID().toString(),
    val executeAt: Long = runAt, val precision: String = "exact") {
    fun validate(now: Long) {
        if (jobId.isBlank() || account?.isBlank() == true || owner.isBlank() || runAt < 0 ||
            executeAt < runAt || deadline <= executeAt || precision !in setOf("exact", "inexact"))
            throw PortError("InvalidWake")
        if (now >= deadline) throw PortError("DeadlineExceeded")
    }
    fun mayRun(now: Long, activeAccount: String?, currentGeneration: String?): Boolean =
        now >= runAt && now < deadline && (account == null || account == activeAccount) && generation == currentGeneration
}

/** Wall deadlines also have a monotonic bound, so clock rollback cannot extend an active operation. */
class Deadline(val epoch: Long, wallNow: Long, elapsedNow: Long) {
    private val monotonicEnd = elapsedNow + (epoch - wallNow).coerceIn(0, 600_000)
    fun remaining(wallNow: Long, elapsedNow: Long): Long =
        minOf(epoch - wallNow, monotonicEnd - elapsedNow).coerceAtLeast(0)
}
// Android 9's Instant.parse rejects valid RFC3339 numeric offsets produced by chrono.
internal fun epochMillis(timestamp:String):Long = java.time.OffsetDateTime.parse(timestamp).toInstant().toEpochMilli()
