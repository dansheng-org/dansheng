// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

interface PlatformDispatcher {
    val capabilities: Set<String>
    fun dispatch(capability: String, mediated: JSONObject, reply: PortReply)
}

class BrowserDispatcher(private val browser: WebViewBrowserPort) : PlatformDispatcher {
    // browser.write is a permission/capability marker, not another operation.
    override val capabilities = setOf("browser.open", "browser.navigate", "browser.login", "browser.close", "browser.request", "browser.write", "browser.evaluate")
    override fun dispatch(capability: String, mediated: JSONObject, reply: PortReply) {
        try {
            val principal = mediated.getJSONObject("principal")
            val grant = mediated.getJSONObject("grant")
            fun strings(name: String): Set<String> = grant.optJSONArray(name)?.let { a ->
                (0 until a.length()).map { a.getString(it) }.toSet() } ?: emptySet()
            val authority = Authority(principal.getString("id"),
                principal.optString("kind") == "owner" && principal.optString("id") == "owner",
                strings("capabilities"), strings("account_ids"), strings("origins"),
                grant.optString("expires_at").takeIf { it.isNotEmpty() && it != "null" }?.let(::epochMillis))
            browser.call(capability, authority, mediated.getJSONObject("input"), reply)
        } catch (_: Exception) { reply(Result.failure(PortError("InvalidPlatformEnvelope"))) }
    }
}

/** Own this alongside the engine. Stop polling BEFORE closing the engine; browser lifecycle
 * cancellation is host-owned. There are no Rust callbacks into JNI threads or UI threads.
 */
class PlatformPump(private val engine: Long, private val dispatcher: PlatformDispatcher) : AutoCloseable {
    private val executor = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var stopped = false
    fun start() {
        executor.scheduleWithFixedDelay({
            if (!stopped) try {
                repeat(16) {
                    val bytes = NativeCore.platformPoll(engine) ?: return@scheduleWithFixedDelay
                    val event = JSONObject(bytes.toString(Charsets.UTF_8))
                    val id = event.getString("id")
                    dispatcher.dispatch(event.getString("capability"), event.getJSONObject("input")) { result ->
                        if (!stopped) {
                            val response = JSONObject().put("id", id)
                            result.fold({ response.put("result", it) }, { e ->
                                response.put("error", JSONObject().put("code", (e as? PortError)?.code ?: "PlatformError")
                                    .put("message", "Platform operation did not complete"))
                            })
                            NativeCore.platformRespond(engine, id.toLong(), response.toString().toByteArray(Charsets.UTF_8))
                        }
                    }
                }
            } catch (_: Exception) { /* Never log payloads, credentials or page content. */ }
        }, 0, 10, TimeUnit.MILLISECONDS)
    }
    override fun close() { stopped = true; executor.shutdownNow() }
}
