// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.os.Looper
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Singleton campus agent engine:
 * 1. Offline, strictly account-scoped Rust search.query hits with safe typing and zero cross-account leakage.
 * 2. Practical 'ask' evidence synthesis with labeled local source references and readable excerpts.
 * 3. Opt-in OFF-by-default loopback HTTP MCP server (2025-11-25) with ephemeral bearer token (only exposed on explicit copy).
 * 4. Immediate thread-safe termination on account change (accountChanged()).
 */
object CampusAgent {
    private val lock = Any()
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var serverThread: Thread? = null
    @Volatile private var executor: ThreadPoolExecutor? = null
    @Volatile private var boundAccount: String? = null
    @Volatile private var bearerToken: String? = null
    @Volatile private var serverPort: Int = 0
    private val isRunning = AtomicBoolean(false)
    private val clients=java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()

    /**
     * Public thread-safe callback invoked by RuntimeHost.setAccount or upon account invalidation.
     * Stops the loopback MCP server immediately and closes all sockets.
     */
    fun accountChanged() = synchronized(lock) {
        stopMcpInternal()
    }

    /**
     * Dispatch agent commands off the main thread.
     */
    fun call(rt: RuntimeHost, action: String, params: JSONObject): Any? {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw PortError("BlockingCallOnMainThread")
        }
        val act = action.removePrefix("agent.")
        return when (act) {
            "query", "search" -> {
                val account = rt.account()?.takeIf { it.isNotBlank() } ?: throw PortError("AccountRequired")
                if (params.has("account_id") && params.optString("account_id") != account) {
                    throw PortError("AccountMismatch")
                }
                val query = params.optString("query", params.optString("q", "")).trim()
                val limit = params.optInt("limit", 20).coerceIn(1, 100)
                searchLocal(rt, account, query, limit)
            }
            "ask" -> {
                val account = rt.account()?.takeIf { it.isNotBlank() } ?: throw PortError("AccountRequired")
                if (params.has("account_id") && params.optString("account_id") != account) {
                    throw PortError("AccountMismatch")
                }
                val question = params.optString("question", params.optString("query", "")).trim()
                askLocal(rt, account, question)
            }
            "mcp.start", "start" -> {
                val account = rt.account()?.takeIf { it.isNotBlank() } ?: throw PortError("AccountRequired")
                val port = params.optInt("port", 0)
                startMcpServer(rt, account, port)
            }
            "mcp.stop", "stop" -> {
                stopMcpServer()
            }
            "mcp.status", "status" -> {
                getMcpStatus(rt)
            }
            "mcp.token", "mcp.credentials", "mcp.copy" -> {
                getMcpToken(rt)
            }
            else -> throw PortError("MethodUnavailable")
        }
    }

    private fun inferKind(sourceId: String): String {
        return when {
            sourceId.contains("ecard") || sourceId.contains("card") || sourceId.contains("balance") -> "card"
            sourceId.contains("course") || sourceId.contains("canvas") || sourceId.contains("timetable") -> "course"
            sourceId.contains("calendar") || sourceId.contains("sports") || sourceId.contains("venue") -> "calendar"
            sourceId.contains("todo") || sourceId.contains("task") || sourceId.contains("job") -> "task"
            sourceId.contains("notice") || sourceId.contains("news") || sourceId.contains("announcement") -> "notice"
            else -> "record"
        }
    }

    private fun searchLocal(rt: RuntimeHost, account: String, query: String, limit: Int): JSONObject {
        require(account.isNotBlank())
        val initialAccount = rt.account()
        if (initialAccount.isNullOrBlank() || initialAccount != account) {
            throw PortError("AccountMismatch")
        }

        val searchParams = JSONObject()
            .put("account_id", account)
            .put("query", query)
            .put("limit", limit)

        // Directly call search.query without swallowing errors as empty
        val res = rt.request("search.query", searchParams)

        // Strict re-check: account must not have changed while search was in-flight
        val postAccount = rt.account()
        if (postAccount.isNullOrBlank() || postAccount != account) {
            throw PortError("AccountMismatch")
        }

        val rawHits: JSONArray = when (res) {
            is JSONArray -> res
            is JSONObject -> res.optJSONArray("hits") ?: res.optJSONArray("records") ?: JSONArray()
            else -> JSONArray()
        }

        val sanitizedHits = JSONArray()
        for (i in 0 until rawHits.length()) {
            val hit = rawHits.optJSONObject(i) ?: continue
            val hitAccount = hit.optString("account_id").trim()

            // Strict account isolation: EXCLUDE blank, unknown-scope, or cross-account rows!
            // Never return raw owner private records without an explicit bound account match.
            if (hitAccount.isEmpty() || hitAccount != account) continue

            val owner = hit.optString("owner").trim()
            // Do not return arbitrary caller filters or ungranted owner private internal items
            if (owner.startsWith("internal:") || owner == "untrusted") continue

            val sourceId = hit.optString("source_id", "local.search")
            val externalId = hit.optString("external_id", "")
            val kind = hit.optString("kind", inferKind(sourceId))
            val rawData = hit.optJSONObject("data") ?: hit.optJSONObject("payload") ?: JSONObject()

            // Read core Store.records_json summary projection keys: title, snippet, asset_id
            val title = rawData.optString("title", externalId.ifBlank { "本地记录" }).take(256)
            val snippet = rawData.optString("snippet", rawData.optString("summary", rawData.optString("content", ""))).take(512)

            val cleanData = JSONObject()
                .put("title", title)
                .put("snippet", snippet)

            if (rawData.has("asset_id") && !rawData.isNull("asset_id")) {
                cleanData.put("asset_id", rawData.getString("asset_id"))
            }

            val cleanHit = JSONObject()
                .put("source_id", sourceId)
                .put("external_id", externalId)
                .put("account_id", account)
                .put("kind", kind)
                .put("title", title)
                .put("snippet", snippet)
                .put("data", cleanData)
                .put("updated_at", hit.optString("updated_at", hit.optString("observed_at", "")))

            sanitizedHits.put(cleanHit)
        }

        return JSONObject()
            .put("account_id", account)
            .put("query", query)
            .put("hits", sanitizedHits)
    }

    private fun askLocal(rt: RuntimeHost, account: String, question: String): JSONObject {
        require(account.isNotBlank())
        val searchResult = searchLocal(rt, account, question, 10)
        val hits = searchResult.getJSONArray("hits")

        // If asking about card balance, check cached official.fudan.ecard.balance
        var balanceErrorText: String? = null
        if (question.contains("卡") || question.contains("余额") || question.contains("钱")) {
            val hasCardHit = (0 until hits.length()).any { hits.getJSONObject(it).optString("kind") == "card" }
            if (!hasCardHit) {
                try {
                    val rows = rt.request("sources.query", JSONObject()
                        .put("account_id", account)
                        .put("source_id", "official.fudan.ecard.balance")
                        .put("external_id", "ecard-balance")
                        .put("limit", 1)
                    ) as? JSONArray
                    val card = rows?.optJSONObject(0)
                    if (card != null && card.optString("account_id") == account) {
                        val d = card.optJSONObject("payload") ?: card.optJSONObject("data")
                        val m = d?.optJSONObject("balance")
                        if (m != null && m.has("cents")) {
                            val amount = java.math.BigDecimal.valueOf(m.optLong("cents", 0), 2).toPlainString()
                            val curr = m.optString("currency", "CNY")
                            val updateTime = card.optString("observed_at", card.optString("updated_at", ""))
                            val cardHit = JSONObject()
                                .put("source_id", "official.fudan.ecard.balance")
                                .put("external_id", "ecard-balance")
                                .put("account_id", account)
                                .put("kind", "card")
                                .put("title", "校园卡余额")
                                .put("snippet", "当前卡内余额：$amount $curr")
                                .put("data", JSONObject().put("title", "校园卡余额").put("snippet", "当前卡内余额：$amount $curr"))
                                .put("updated_at", updateTime)
                            hits.put(cardHit)
                        } else {
                            balanceErrorText = "本地缓存的校园卡记录格式异常，无有效金额数据"
                        }
                    } else {
                        balanceErrorText = "本地暂无校园卡余额缓存，请在卡包中刷新同步"
                    }
                } catch (e: Exception) {
                    balanceErrorText = "读取校园卡缓存失败（${(e as? PortError)?.code ?: "错误"}）"
                }
            }
        }

        val sourcesArray = JSONArray()
        val answerText: String
        if (hits.length() == 0) {
            val extra = if (balanceErrorText != null) "\n补充说明：$balanceErrorText。" else ""
            answerText = "在当前账号（$account）的本地离线数据中，未检索到与「$question」相关的内容。$extra\n\n提示：校园助手仅检索当前账号在本地已同步的记录，不调用远程大模型，不虚构信息。"
        } else {
            val sb = StringBuilder()
            sb.append("根据当前账号（").append(account).append("）的本地离线数据，检索到以下相关证据：\n\n")
            for (i in 0 until hits.length()) {
                val hit = hits.getJSONObject(i)
                val idx = i + 1
                val title = hit.optString("title", "本地记录")
                val snippet = hit.optString("snippet", "")
                val sourceId = hit.optString("source_id")
                val kind = hit.optString("kind")
                val updatedAt = hit.optString("updated_at")

                sb.append("【证据 ").append(idx).append("】").append(title)
                if (snippet.isNotBlank()) sb.append("\n  摘录：").append(snippet)
                if (updatedAt.isNotBlank()) sb.append("\n  更新时间：").append(updatedAt)
                sb.append("\n\n")

                val srcObj = JSONObject()
                    .put("index", idx)
                    .put("label", "[$idx] $title · $sourceId")
                    .put("title", title)
                    .put("source_id", sourceId)
                    .put("external_id", hit.optString("external_id"))
                    .put("kind", kind)
                    .put("snippet", snippet)
                    .put("updated_at", updatedAt)
                sourcesArray.put(srcObj)
            }
            if (balanceErrorText != null) {
                sb.append("注：").append(balanceErrorText).append("\n\n")
            }
            sb.append("提示：以上回答均由本地离线证据总结生成，不含远程大模型推测。")
            answerText = sb.toString().trim()
        }

        return JSONObject()
            .put("question", question)
            .put("account_id", account)
            .put("answer", answerText)
            .put("sources", sourcesArray)
            .put("evidence_count", hits.length())
    }

    private fun startMcpServer(rt: RuntimeHost, account: String, requestedPort: Int): JSONObject = synchronized(lock) {
        if (isRunning.get() && boundAccount == account && serverSocket != null && !serverSocket!!.isClosed) {
            return JSONObject()
                .put("running", true)
                .put("port", serverPort)
                .put("account_id", account)
                .put("url", "http://127.0.0.1:$serverPort/mcp")
                .put("adb_command", "adb forward tcp:$serverPort tcp:$serverPort")
        }

        stopMcpInternal()

        // Per start crypto random token (32 bytes -> 64 hex characters)
        val tokenBytes = ByteArray(32)
        SecureRandom().nextBytes(tokenBytes)
        val token = tokenBytes.joinToString("") { "%02x".format(it) }

        // Bind strictly to loopback 127.0.0.1, preventing LAN/WiFi exposure
        val s = ServerSocket(requestedPort, 50, InetAddress.getByName("127.0.0.1"))
        s.soTimeout=350
        serverSocket = s
        serverPort = s.localPort
        bearerToken = token
        boundAccount = account
        isRunning.set(true)

        // Bounded executor with strictly bounded queue (no arbitrary unbounded queue)
        val exec = ThreadPoolExecutor(
            2,
            4,
            15L,
            TimeUnit.SECONDS,
            ArrayBlockingQueue<Runnable>(8),
            ThreadPoolExecutor.AbortPolicy()
        )
        executor = exec

        val t = Thread({
            while (isRunning.get() && !s.isClosed) {
                try {
                    val clientSocket = s.accept()
                    if(!isRunning.get() || serverSocket!==s){clientSocket.close();break}
                    clients.add(clientSocket)
                    try {
                        exec.submit {
                            try {handleClientSocket(clientSocket, rt, account, token)}
                            finally {clients.remove(clientSocket);runCatching { clientSocket.close() }}
                        }
                    } catch (_: RejectedExecutionException) {
                        // Queue saturated, immediately close with 503
                        try {
                            clientSocket.soTimeout = 2000
                            sendHttpResponse(clientSocket.getOutputStream(), 503, "Service Unavailable", "application/json", """{"error":"Service Saturated"}""")
                            clientSocket.close()
                        } catch (_: Exception) {} finally {clients.remove(clientSocket);runCatching{clientSocket.close()}}
                    }
                } catch (_: java.net.SocketTimeoutException) {
                    continue
                } catch (_: SocketException) {
                    break
                } catch (_: Exception) {}
            }
        }, "CampusAgent-MCP-Loopback")
        t.isDaemon = true
        serverThread = t
        t.start()

        // Notice: Do NOT return bearer on mcp.start (only on explicit copy command)
        return JSONObject()
            .put("running", true)
            .put("port", serverPort)
            .put("account_id", account)
            .put("url", "http://127.0.0.1:$serverPort/mcp")
            .put("adb_command", "adb forward tcp:$serverPort tcp:$serverPort")
    }

    private fun stopMcpServer(): JSONObject = synchronized(lock) {
        stopMcpInternal()
        return JSONObject().put("running", false)
    }

    private fun stopMcpInternal() {
        isRunning.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null
        clients.forEach{runCatching{it.close()}};clients.clear()
        try {
            executor?.shutdownNow()
        } catch (_: Exception) {}
        executor = null
        val accepting=serverThread
        if(accepting!==Thread.currentThread())runCatching{accepting?.join(750)}
        serverThread = null
        bearerToken = null
        boundAccount = null
        serverPort = 0
    }

    private fun getMcpStatus(rt: RuntimeHost): JSONObject = synchronized(lock) {
        val currentAccount = rt.account()
        // Stop/disallow on switch
        if (isRunning.get() && (currentAccount.isNullOrBlank() || currentAccount != boundAccount)) {
            stopMcpInternal()
        }

        val runningNow = isRunning.get() && serverSocket != null && !serverSocket!!.isClosed
        val res = JSONObject().put("running", runningNow)
        if (runningNow) {
            res.put("port", serverPort)
            res.put("account_id", boundAccount)
            res.put("url", "http://127.0.0.1:$serverPort/mcp")
            res.put("adb_command", "adb forward tcp:$serverPort tcp:$serverPort")
        } else {
            res.put("port", 0)
            res.put("account_id", currentAccount ?: JSONObject.NULL)
            res.put("url", "")
            res.put("adb_command", "")
        }
        // Notice: Do NOT return bearer on mcp.status
        return res
    }

    private fun getMcpToken(rt: RuntimeHost): JSONObject = synchronized(lock) {
        val currentAccount = rt.account()
        if (!isRunning.get() || boundAccount == null || bearerToken == null) {
            throw PortError("McpNotRunning")
        }
        if (currentAccount.isNullOrBlank() || currentAccount != boundAccount) {
            stopMcpInternal()
            throw PortError("AccountMismatch")
        }
        // Return pairing credential ONLY on explicit copy command
        JSONObject().put("token", bearerToken)
    }

    /**
     * Bounded line reader that strictly prevents memory exhaustion from infinite byte streams.
     * Throws PortError("HeaderLineTooLarge") if any single header line exceeds maxBytes before newline.
     */
    private fun readBoundedLine(input: InputStream, maxBytes: Int = 4096): String? {
        val buffer = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b == -1) {
                return if (buffer.size() == 0) null else buffer.toString(Charsets.UTF_8.name())
            }
            if (b == '\n'.code) {
                val bytes = buffer.toByteArray()
                val len = if (bytes.isNotEmpty() && bytes.last() == '\r'.code.toByte()) bytes.size - 1 else bytes.size
                return String(bytes, 0, len, Charsets.UTF_8)
            }
            if (buffer.size() >= maxBytes) {
                throw PortError("HeaderLineTooLarge")
            }
            buffer.write(b)
        }
    }

    private fun handleClientSocket(socket: Socket, rt: RuntimeHost, account: String, token: String) {
        socket.use { s ->
            s.soTimeout = 5000
            val input = s.getInputStream()
            val output = s.getOutputStream()

            val requestLine = try {
                readBoundedLine(input, 4096) ?: return
            } catch (_: Exception) {
                sendHttpResponse(output, 431, "Request Header Fields Too Large", "application/json", """{"error":"Header line too large"}""")
                return
            }

            val reqParts = requestLine.split(" ")
            if (reqParts.size < 3) {
                sendHttpResponse(output, 400, "Bad Request", "application/json", """{"error":"Bad Request"}""")
                return
            }

            val httpMethod = reqParts[0].uppercase()
            val rawPath = reqParts[1]
            val path = rawPath.substringBefore('?')

            // Read headers with bounded lines and bounded length per line
            var hostHeader: String? = null
            var originHeader: String? = null
            var authHeader: String? = null
            var contentLength = 0
            var headerCount = 0

            try {
                while (headerCount++ < 60) {
                    val line = readBoundedLine(input, 4096) ?: break
                    if (line.isEmpty()) break
                    val idx = line.indexOf(':')
                    if (idx > 0) {
                        val name = line.substring(0, idx).trim().lowercase()
                        val value = line.substring(idx + 1).trim()
                        when (name) {
                            "host" -> hostHeader = value
                            "origin" -> originHeader = value
                            "authorization" -> authHeader = value
                            "content-length" -> contentLength = value.toIntOrNull() ?: 0
                        }
                    }
                }
            } catch (_: Exception) {
                sendHttpResponse(output, 431, "Request Header Fields Too Large", "application/json", """{"error":"Header line too large"}""")
                return
            }

            // Path validation: bounded POST /mcp (or GET/OPTIONS /mcp)
            if (path != "/mcp") {
                sendHttpResponse(output, 404, "Not Found", "application/json", """{"error":"Not Found"}""")
                return
            }

            // Validate Host: exact literal 127.0.0.1 or localhost WITH exact serverPort
            val expectedHost1 = "127.0.0.1:$serverPort"
            val expectedHost2 = "localhost:$serverPort"
            if (hostHeader == null || (!hostHeader.equals(expectedHost1, ignoreCase = true) && !hostHeader.equals(expectedHost2, ignoreCase = true))) {
                sendHttpResponse(output, 403, "Forbidden", "application/json", """{"error":"Forbidden: invalid host"}""")
                return
            }

            // Validate Origin: exact literal 127.0.0.1 or localhost WITH exact serverPort
            if (originHeader != null && originHeader.isNotBlank() && originHeader != "null") {
                val expectedOrigin1 = "http://127.0.0.1:$serverPort"
                val expectedOrigin2 = "http://localhost:$serverPort"
                if (!originHeader.equals(expectedOrigin1, ignoreCase = true) && !originHeader.equals(expectedOrigin2, ignoreCase = true)) {
                    sendHttpResponse(output, 403, "Forbidden", "application/json", """{"error":"Forbidden: invalid origin"}""")
                    return
                }
            }

            // OPTIONS preflight support
            if (httpMethod == "OPTIONS") {
                sendHttpResponse(output, 204, "No Content", "text/plain", "", mapOf("Allow" to "POST, GET, OPTIONS"))
                return
            }

            // Authenticated local bearer client check
            val expectedAuth = "Bearer $token"
            if (authHeader == null || authHeader != expectedAuth) {
                sendHttpResponse(output, 401, "Unauthorized", "application/json", """{"error":"Unauthorized"}""")
                return
            }

            // In-flight account check BEFORE processing request
            val activeAccountBefore = rt.account()
            if (activeAccountBefore.isNullOrBlank() || activeAccountBefore != account) {
                accountChanged()
                sendHttpResponse(output, 403, "Forbidden", "application/json", """{"error":"Account switched or session revoked"}""")
                return
            }

            // GET status query
            if (httpMethod == "GET") {
                val info = JSONObject()
                    .put("status", "ok")
                    .put("server", "dansheng-campus-agent")
                    .put("version", "0.1.0")
                    .put("protocolVersion", "2025-11-25")
                    .put("account_id", account)
                sendHttpResponse(output, 200, "OK", "application/json", info.toString())
                return
            }

            if (httpMethod != "POST") {
                sendHttpResponse(output, 405, "Method Not Allowed", "application/json", """{"error":"Method Not Allowed"}""")
                return
            }

            // Bounded request size: max 64 KB
            if (contentLength > 65536) {
                sendHttpResponse(output, 413, "Payload Too Large", "application/json", """{"error":"Payload Too Large"}""")
                return
            }

            val bodyBytes = ByteArray(contentLength)
            var readTotal = 0
            while (readTotal < contentLength) {
                val count = input.read(bodyBytes, readTotal, contentLength - readTotal)
                if (count == -1) break
                readTotal += count
            }
            val body = String(bodyBytes, 0, readTotal, Charsets.UTF_8)

            val rpc = try {
                JSONObject(body)
            } catch (_: Exception) {
                sendHttpResponse(output, 400, "Bad Request", "application/json", """{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"},"id":null}""")
                return
            }

            val mcpMethod = rpc.optString("method")
            val hasId = rpc.has("id")
            val id = rpc.opt("id")
            val params = rpc.optJSONObject("params") ?: JSONObject()

            // In-flight account check BEFORE handling MCP method
            val activeAccountMid = rt.account()
            if (activeAccountMid.isNullOrBlank() || activeAccountMid != account) {
                accountChanged()
                sendHttpResponse(output, 403, "Forbidden", "application/json", """{"error":"Account switched or session revoked"}""")
                return
            }

            val (code, replyJson) = handleMcpMethod(rt, account, mcpMethod, params, hasId, id)

            // In-flight account check AFTER handling MCP method and before writing response
            val activeAccountAfter = rt.account()
            if (activeAccountAfter.isNullOrBlank() || activeAccountAfter != account) {
                accountChanged()
                sendHttpResponse(output, 403, "Forbidden", "application/json", """{"error":"Account switched or session revoked"}""")
                return
            }

            sendHttpResponse(output, code, if (code == 202) "Accepted" else "OK", "application/json", replyJson)
        }
    }

    private fun handleMcpMethod(
        rt: RuntimeHost,
        account: String,
        method: String,
        params: JSONObject,
        hasId: Boolean,
        id: Any?
    ): Pair<Int, String> {
        return when (method) {
            "initialize" -> {
                val clientProto = params.optString("protocolVersion", "2025-11-25")
                val supportedProto = if (clientProto == "2024-11-05") "2024-11-05" else "2025-11-25"
                val result = JSONObject()
                    .put("protocolVersion", supportedProto)
                    .put("capabilities", JSONObject().put("tools", JSONObject().put("listChanged", false)))
                    .put("serverInfo", JSONObject().put("name", "dansheng-campus-agent").put("version", "0.1.0"))
                    .put("instructions", "Dansheng campus agent local read-only MCP server. Session bound to account $account.")
                val resp = JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", result)
                Pair(200, resp.toString())
            }
            "notifications/initialized" -> {
                Pair(202, """{"status":"accepted"}""")
            }
            "ping" -> {
                val resp = JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", JSONObject())
                Pair(200, resp.toString())
            }
            "tools/list" -> {
                val tools = JSONArray()
                tools.put(JSONObject()
                    .put("name", "search_local_records")
                    .put("description", "Search cached local records for the active bound account (read-only, offline)")
                    .put("inputSchema", JSONObject()
                        .put("type", "object")
                        .put("properties", JSONObject()
                            .put("query", JSONObject().put("type", "string").put("description", "Search keywords"))
                            .put("limit", JSONObject().put("type", "integer").put("description", "Max results (1-50)"))
                        )
                        .put("required", JSONArray().put("query"))
                    )
                )
                tools.put(JSONObject()
                    .put("name", "get_calendar_summary")
                    .put("description", "Get summary of local schedule and appointments strictly for the active account")
                    .put("inputSchema", JSONObject()
                        .put("type", "object")
                        .put("properties", JSONObject()
                            .put("limit", JSONObject().put("type", "integer").put("description", "Max entries"))
                        )
                    )
                )
                tools.put(JSONObject()
                    .put("name", "get_course_summary")
                    .put("description", "Get cached course summaries and assignments for the active account via strict named read operations")
                    .put("inputSchema", JSONObject()
                        .put("type", "object")
                        .put("properties", JSONObject()
                            .put("query", JSONObject().put("type", "string").put("description", "Course keyword or name"))
                        )
                    )
                )
                tools.put(JSONObject()
                    .put("name", "get_card_summary")
                    .put("description", "Get cached campus card balance and status summary for the active account (offline only)")
                    .put("inputSchema", JSONObject().put("type", "object").put("properties", JSONObject()))
                )
                val resp = JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", JSONObject().put("tools", tools))
                Pair(200, resp.toString())
            }
            "tools/call" -> {
                val toolName = params.optString("name")
                val args = params.optJSONObject("arguments") ?: JSONObject()
                val textOutput = when (toolName) {
                    "search_local_records" -> {
                        val q = args.optString("query")
                        val lim = args.optInt("limit", 20).coerceIn(1, 50)
                        val res = searchLocal(rt, account, q, lim)
                        formatHitsText(res.getJSONArray("hits"))
                    }
                    "get_calendar_summary" -> {
                        val lim = args.optInt("limit", 20).coerceIn(1, 50)
                        val res = searchLocal(rt, account, "日程", lim)
                        val hits = res.getJSONArray("hits")
                        if (hits.length() == 0) "暂无当前账号的本地日程或预约缓存" else formatHitsText(hits)
                    }
                    "get_course_summary" -> {
                        val q = args.optString("query", "课程")
                        val res = searchLocal(rt, account, q, 20)
                        val hits = res.getJSONArray("hits")
                        if (hits.length() == 0) "暂无当前账号的本地课程缓存" else formatHitsText(hits)
                    }
                    "get_card_summary" -> {
                        readLocalCardBalance(rt, account)
                    }
                    else -> {
                        val err = JSONObject()
                            .put("jsonrpc", "2.0")
                            .put("id", id)
                            .put("error", JSONObject().put("code", -32602).put("message", "Unknown tool: $toolName"))
                        return Pair(200, err.toString())
                    }
                }
                val content = JSONArray().put(JSONObject().put("type", "text").put("text", textOutput))
                val result = JSONObject().put("content", content).put("isError", false)
                val resp = JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", result)
                Pair(200, resp.toString())
            }
            else -> {
                val err = JSONObject()
                    .put("jsonrpc", "2.0")
                    .put("id", id)
                    .put("error", JSONObject().put("code", -32601).put("message", "Method not found: $method"))
                Pair(200, err.toString())
            }
        }
    }

    private fun readLocalCardBalance(rt: RuntimeHost, account: String): String {
        return try {
            val rows = rt.request("sources.query", JSONObject()
                .put("account_id", account)
                .put("source_id", "official.fudan.ecard.balance")
                .put("external_id", "ecard-balance")
                .put("limit", 1)
            ) as? JSONArray
            val card = rows?.optJSONObject(0)
            if (card != null && card.optString("account_id") == account) {
                val data = card.optJSONObject("payload") ?: card.optJSONObject("data")
                val money = data?.optJSONObject("balance")
                if (money != null && money.has("cents")) {
                    val cents = money.optLong("cents", 0)
                    val curr = money.optString("currency", "CNY")
                    val updated = card.optString("observed_at", card.optString("updated_at", ""))
                    val amount = java.math.BigDecimal.valueOf(cents, 2).toPlainString()
                    "校园卡余额：$amount $curr (更新时间: $updated)"
                } else {
                    "校园卡缓存数据格式异常，无有效金额"
                }
            } else {
                "未检索到当前账号的本地校园卡余额缓存"
            }
        } catch (_: Exception) {
            "未检索到当前账号的本地校园卡余额缓存"
        }
    }

    private fun formatHitsText(hits: JSONArray): String {
        if (hits.length() == 0) return "未找到匹配的本地记录"
        val sb = StringBuilder()
        for (i in 0 until hits.length()) {
            val h = hits.getJSONObject(i)
            sb.append("[${i + 1}] ").append(h.optString("title", "本地记录")).append("\n")
            val snippet = h.optString("snippet")
            if (snippet.isNotBlank()) sb.append("  摘录: ").append(snippet).append("\n")
            val src = h.optString("source_id")
            val time = h.optString("updated_at")
            sb.append("  来源: ").append(src)
            if (time.isNotBlank()) sb.append(" | 时间: ").append(time)
            sb.append("\n\n")
        }
        return sb.toString().trim()
    }

    private fun sendHttpResponse(
        out: OutputStream,
        statusCode: Int,
        reason: String,
        contentType: String,
        body: String,
        extraHeaders: Map<String, String> = emptyMap()
    ) {
        val bodyBytes = body.toByteArray(Charsets.UTF_8)
        val sb = StringBuilder()
        sb.append("HTTP/1.1 ").append(statusCode).append(" ").append(reason).append("\r\n")
        sb.append("Content-Type: ").append(contentType).append("; charset=utf-8\r\n")
        sb.append("Content-Length: ").append(bodyBytes.size).append("\r\n")
        sb.append("Connection: close\r\n")
        for ((k, v) in extraHeaders) {
            sb.append(k).append(": ").append(v).append("\r\n")
        }
        sb.append("\r\n")
        out.write(sb.toString().toByteArray(Charsets.UTF_8))
        if (bodyBytes.isNotEmpty()) {
            out.write(bodyBytes)
        }
        out.flush()
    }
}
