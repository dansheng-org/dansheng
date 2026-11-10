// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.os.Bundle
import android.test.InstrumentationTestCase
import org.dansheng.android.NativeCore
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Same unchanged package as Windows release. All HTTP and identity are synthetic loopback. */
@Suppress("DEPRECATION")
class ClosedLoopInstrumentationTest : InstrumentationTestCase() {
    private fun await(op: Long): JSONObject {
        val end = System.currentTimeMillis() + 10000
        while (System.currentTimeMillis() < end) {
            NativeCore.poll(op)?.let { return JSONObject(it.toString(Charsets.UTF_8)) }
            Thread.sleep(10)
        }
        fail("closed-loop native operation exceeded deadline"); throw IllegalStateException()
    }
    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.get(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        is Number -> JSONObject.numberToString(value)
        is Boolean -> value.toString()
        else -> throw IllegalArgumentException("Unexpected fixture JSON type")
    }
    private fun digest(value: Any?) = sha256(canonical(value).toByteArray(Charsets.UTF_8))

    fun testSamePackageNativeHttpAuthStorageSourcesUiAndReopen() {
        // An exclusive loopback bind is also the atomic availability check.
        // If another process owns the port, fail without stopping or contacting it.
        val listener = ServerSocket()
        try {
            listener.reuseAddress = false
            listener.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 19765), 1)
            listener.soTimeout = 1000
        } catch (_: Exception) {
            listener.close()
            fail("Synthetic fixture cannot exclusively bind 127.0.0.1:19765; no other process was touched")
        }
        val requests = AtomicInteger()
        val authenticated = AtomicInteger()
        val serverFailure = AtomicReference<Throwable>()
        val server = Thread({
            try {
                while (!listener.isClosed) {
                    val socket = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                    socket.use {
                        it.soTimeout = 3000
                        val reader = it.getInputStream().bufferedReader(Charsets.US_ASCII)
                        val requestLine = reader.readLine()
                        var authorization: String? = null
                        var size = requestLine?.length ?: 0
                        var lines = 0
                        while (true) {
                            val line = reader.readLine() ?: throw IllegalStateException("Incomplete synthetic HTTP headers")
                            if (line.isEmpty()) break
                            size += line.length; lines++
                            check(size <= 8192 && lines <= 64) { "Synthetic HTTP headers exceeded limit" }
                            if (line.substringBefore(':').equals("Authorization", ignoreCase = true)) {
                                authorization = line.substringAfter(':').trim()
                            }
                        }
                        requests.incrementAndGet()
                        check(requestLine == "GET /fixture HTTP/1.1") { "Unexpected synthetic HTTP method or path" }
                        check(authorization == "Bearer synthetic-fixture-bearer") { "Synthetic authorization did not match" }
                        authenticated.incrementAndGet()
                        val body = """{"account_id":"fixture-account","id":"course-1","title":"Synthetic course","count":2}""".toByteArray(Charsets.UTF_8)
                        val header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                        it.getOutputStream().apply { write(header.toByteArray(Charsets.US_ASCII)); write(body); flush() }
                    }
                }
            } catch (error: Throwable) {
                if (!listener.isClosed) serverFailure.set(error)
            }
        }, "dansheng-synthetic-loopback").apply { isDaemon = true; start() }
        var engine = 0L
        try {
            val root = instrumentation.targetContext.filesDir.resolve("closed-loop-" + UUID.randomUUID()).apply { mkdirs() }
            val source = root.resolve("package").apply { mkdirs() }
            for (name in instrumentation.targetContext.assets.list("closed-loop")!!) {
                instrumentation.targetContext.assets.open("closed-loop/$name").use { input ->
                    source.resolve(name).outputStream().use { input.copyTo(it) }
                }
            }
            val files = source.listFiles()!!.sortedBy { it.name }
            assertEquals(4, files.size)
            val inventory = files.joinToString("") { sha256(it.readBytes()) + "  " + it.name + "\n" }
            val packageHash = sha256(inventory.toByteArray(Charsets.UTF_8))
            assertEquals("unchanged shared fixture package", "eb037c94a2bd146d0c7d50ec098597e99ba27f2c9ea7852f6bd70e1ec5b6bc1a", packageHash)
            val options = JSONObject().put("data_dir", root.resolve("core").absolutePath).toString().toByteArray(Charsets.UTF_8)
            NativeCore.load()
            fun open(): Long {
                val result = await(NativeCore.open(options))
                assertFalse("synthetic core open failed", result.has("error"))
                return result.getJSONObject("result").getLong("engine")
            }
            engine = open()
            fun core(method: String, params: JSONObject): JSONObject {
                val result = await(NativeCore.request(engine, JSONObject().put("id", method).put("method", method)
                    .put("params", params).toString().toByteArray(Charsets.UTF_8)))
                assertFalse("closed-loop $method: " + result.optJSONObject("error")?.optString("code"), result.has("error"))
                return result
            }
            val input = JSONObject().put("account_id", "fixture-account")
            val plugin = JSONObject().put("plugin_id", "fixture.closed-loop")
            fun run(action: String): Any = core("plugins.run", JSONObject().put("plugin_id", "fixture.closed-loop")
                .put("action", action).put("input", input)).get("result")
            core("accounts.upsert", JSONObject().put("account_id", "fixture-account").put("label", "Synthetic fixture").put("provider", "fixture"))
            core("plugins.install", JSONObject().put("path", source.absolutePath))
            val manifest = JSONObject(source.resolve("manifest.json").readText())
            core("permissions.set", JSONObject().put("subject", "plugin:fixture.closed-loop").put("grant", JSONObject()
                .put("capabilities", manifest.getJSONArray("capabilities")).put("origins", manifest.getJSONArray("network"))
                .put("account_ids", JSONArray().put("fixture-account")).put("allow_private_network", true)))
            core("plugins.enable", plugin)
            assertEquals("62128b5d15f52caad96d16e2bc9f9b3913d0dd48477b7ad5eab6a0f328e3f783", digest(run("sync")))
            assertEquals(JSONObject.NULL, run("readCache")); assertEquals(0, requests.get())
            val session = core("auth.session.set", JSONObject().put("account_id", "fixture-account")
                .put("origin", "http://127.0.0.1:19765").put("bearer", "synthetic-fixture-bearer").put("persist", false)).getJSONObject("result")
            assertTrue(session.getBoolean("authenticated")); assertFalse(session.getBoolean("persisted"))
            assertEquals("local_credentials_only", session.getString("verification"))
            assertFalse(core("auth.status", JSONObject().put("account_id", "another-synthetic-account")).getJSONObject("result").getBoolean("authenticated"))
            val synced = run("sync")
            assertEquals("e8f8458c1ab8c5864c3e7d983dccc1107ddaa1fe23132ec79c91c4368c2925c9", digest(synced))
            assertEquals(1, requests.get()); assertEquals(1, authenticated.get())
            val sourceQuery = JSONObject().put("account_id", "fixture-account").put("source_id", "fixture.closed-loop.courses")
                .put("external_id", "fixture-account:course-1")
            val uiQuery = JSONObject().put("principal", "plugin:fixture.closed-loop").put("id", "summary")
            fun checkSaved(): Pair<JSONObject, JSONObject> {
                assertEquals("14c04bd2996116423701fc518b14662367f912246ae88d7135b9182e56c3bc73", digest(run("readCache")))
                val rows = core("sources.query", sourceQuery).getJSONArray("result")
                assertEquals(1, rows.length())
                val row = JSONObject(rows.getJSONObject(0).toString()).apply { remove("updated_at") }
                assertEquals("839ef6414c2ba5b33bee9108c1278aeed856dde4fdda203c4dde136750c14a22", digest(row))
                val ui = core("ui.get", uiQuery).getJSONObject("result")
                assertEquals("acf91676775b524d47fc804fbcd858ea7fddca570682bde0a05edb46f14d9ff8", digest(ui))
                return row to ui
            }
            checkSaved()
            assertTrue(await(NativeCore.close(engine)).getJSONObject("result").getBoolean("closed")); engine = 0
            engine = open()
            core("plugins.enable", plugin)
            assertFalse(core("auth.status", input).getJSONObject("result").getBoolean("authenticated"))
            val (row, ui) = checkSaved()
            assertEquals(1, requests.get()); assertEquals(1, authenticated.get())
            assertNull("synthetic loopback server must finish without errors", serverFailure.get())
            val cached = run("readCache")
            val normalized = JSONObject().put("sync", synced).put("cache", cached).put("source", row).put("ui", ui)
            instrumentation.sendStatus(0, Bundle().apply {
                putString("closed_loop_package_sha256", packageHash)
                putString("closed_loop_normalized", canonical(normalized))
                putString("closed_loop_normalized_sha256", digest(normalized))
                putString("closed_loop_sync", canonical(synced)); putString("closed_loop_sync_sha256", digest(synced))
                putString("closed_loop_cache_sha256", digest(cached))
                putString("closed_loop_source", canonical(row)); putString("closed_loop_source_sha256", digest(row))
                putString("closed_loop_ui", canonical(ui)); putString("closed_loop_ui_sha256", digest(ui))
                putInt("closed_loop_http_requests", requests.get()); putBoolean("closed_loop_synthetic_auth_matched", true)
                putBoolean("closed_loop_reopen_persisted_data", true); putBoolean("closed_loop_real_school_login", false)
            })
        } finally {
            try { if (engine != 0L) assertTrue(await(NativeCore.close(engine)).getJSONObject("result").getBoolean("closed")) }
            finally { listener.close(); server.join(4000) }
        }
        assertFalse("synthetic loopback thread stopped", server.isAlive)
    }
}
