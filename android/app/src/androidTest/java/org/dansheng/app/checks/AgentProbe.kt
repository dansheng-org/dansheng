// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app.checks

import android.content.Context
import org.dansheng.app.CampusAgent
import org.dansheng.app.RuntimeHost
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Socket

/**
 * Focused androidTest helper for parent runner:
 * Verifies CampusAgent MCP server over real loopback sockets on an offline synthetic account.
 * Tests authentication, initialize (2025-11-25), ping, notifications, tools/list, tools/call,
 * header line bounding, exact Host/Origin with port, accountChanged(), and immediate denial on account switch.
 * Returns no tokens to logs.
 */
object AgentProbe {
    data class ProbeResponse(val statusCode: Int, val headers: Map<String, String>, val body: String)

    fun sendHttp(
        port: Int,
        method: String,
        path: String,
        token: String?,
        body: String = "",
        origin: String? = null,
        host: String? = null,
        rawHeaders: List<String> = emptyList()
    ): ProbeResponse {
        Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 5000
            val out = socket.getOutputStream()
            val effectiveHost = host ?: "127.0.0.1:$port"
            val sb = StringBuilder()
            sb.append("$method $path HTTP/1.1\r\n")
            sb.append("Host: $effectiveHost\r\n")
            sb.append("Connection: close\r\n")
            if (token != null) {
                sb.append("Authorization: Bearer $token\r\n")
            }
            if (origin != null) {
                sb.append("Origin: $origin\r\n")
            }
            for (header in rawHeaders) {
                sb.append(header).append("\r\n")
            }
            val bodyBytes = body.toByteArray(Charsets.UTF_8)
            sb.append("Content-Type: application/json\r\n")
            sb.append("Content-Length: ${bodyBytes.size}\r\n")
            sb.append("\r\n")
            out.write(sb.toString().toByteArray(Charsets.UTF_8))
            if (bodyBytes.isNotEmpty()) {
                out.write(bodyBytes)
            }
            out.flush()

            // Count HTTP bytes (including multi-byte Chinese JSON) rather than waiting
            // for EOF on rejected requests whose bodies the server need not consume.
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.ISO_8859_1))
            val statusLine = reader.readLine() ?: error("Empty HTTP response")
            val parts = statusLine.split(" ", limit = 3)
            val code = parts.getOrNull(1)?.toIntOrNull() ?: 500

            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                val idx = line.indexOf(':')
                if (idx > 0) {
                    headers[line.substring(0, idx).trim().lowercase()] = line.substring(idx + 1).trim()
                }
            }
            val length=headers["content-length"]?.toInt() ?: error("Missing response length")
            require(length in 0..1048576)
            val chars=CharArray(length)
            var used=0
            while(used<length){val n=reader.read(chars,used,length-used);check(n>0){"Truncated MCP response"};used+=n}
            val respBody=String(chars).toByteArray(Charsets.ISO_8859_1).toString(Charsets.UTF_8)
            return ProbeResponse(code, headers, respBody)
        }
    }
}

public fun runAgentProbe(context: Context, rt: RuntimeHost) {
    val originalAccount = rt.account()
    val probeAccount = originalAccount?.takeIf { it.isNotBlank() } ?: "fixture-probe-account"
    if (originalAccount != probeAccount) {
        rt.setAccount(probeAccount)
    }

    try {
        // 1. Start MCP server on an ephemeral loopback port
        val startResult = CampusAgent.call(rt, "mcp.start", JSONObject()) as JSONObject
        check(startResult.getBoolean("running")) { "MCP server did not start" }
        val port = startResult.getInt("port")
        check(port > 0) { "Invalid MCP port" }
        // Verify token is NOT returned on mcp.start
        check(!startResult.has("token") || startResult.optString("token").isEmpty()) {
            "Bearer token must not be returned on mcp.start"
        }

        // Verify token is NOT returned on mcp.status
        val statusResult = CampusAgent.call(rt, "mcp.status", JSONObject()) as JSONObject
        check(!statusResult.has("token") || statusResult.optString("token").isEmpty()) {
            "Bearer token must not be returned on mcp.status"
        }

        // Retrieve token ONLY via explicit copy action
        val tokenObj = CampusAgent.call(rt, "mcp.token", JSONObject()) as JSONObject
        val token = tokenObj.getString("token")
        check(token.length == 64) { "Token must be a 64-hex-char secure random token" }

        // 2. Denied: Missing Bearer Token
        val noAuth = AgentProbe.sendHttp(port, "POST", "/mcp", null, "{}")
        check(noAuth.statusCode == 401) { "Expected 401 for missing token, got ${noAuth.statusCode}" }

        // 3. Denied: Invalid Bearer Token
        val badAuth = AgentProbe.sendHttp(port, "POST", "/mcp", "wrong-token-value", "{}")
        check(badAuth.statusCode == 401) { "Expected 401 for wrong token, got ${badAuth.statusCode}" }

        // 4. Denied: Foreign Origin or Origin with wrong port
        val badOrigin = AgentProbe.sendHttp(port, "POST", "/mcp", token, "{}", origin = "http://malicious.origin.local")
        check(badOrigin.statusCode == 403) { "Expected 403 for foreign origin, got ${badOrigin.statusCode}" }

        val wrongPortOrigin = AgentProbe.sendHttp(port, "POST", "/mcp", token, "{}", origin = "http://127.0.0.1:9999")
        check(wrongPortOrigin.statusCode == 403) { "Expected 403 for origin with mismatched port, got ${wrongPortOrigin.statusCode}" }

        // 5. Denied: Foreign Host or Host missing port
        val badHost = AgentProbe.sendHttp(port, "POST", "/mcp", token, "{}", host = "external.evil.net:$port")
        check(badHost.statusCode == 403) { "Expected 403 for foreign host, got ${badHost.statusCode}" }

        val noPortHost = AgentProbe.sendHttp(port, "POST", "/mcp", token, "{}", host = "127.0.0.1")
        check(noPortHost.statusCode == 403) { "Expected 403 for host without port, got ${noPortHost.statusCode}" }

        // 6. Header line size bounding: line > 4096 bytes must be rejected
        val hugeHeader = "X-Oversized: " + "A".repeat(4100)
        val lineTooLargeResp = runCatching {
            AgentProbe.sendHttp(port, "POST", "/mcp", token, "{}", rawHeaders = listOf(hugeHeader))
        }
        val rejectedLargeHeader = lineTooLargeResp.getOrNull()?.statusCode in listOf(400, 431) || lineTooLargeResp.isFailure
        check(rejectedLargeHeader) { "Expected rejection for header line exceeding 4096 bytes" }

        // 7. MCP Protocol: initialize (2025-11-25)
        val initRpc = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 1)
            .put("method", "initialize")
            .put("params", JSONObject()
                .put("protocolVersion", "2025-11-25")
                .put("capabilities", JSONObject())
                .put("clientInfo", JSONObject().put("name", "native-probe").put("version", "1.0"))
            )
        val initResp = AgentProbe.sendHttp(port, "POST", "/mcp", token, initRpc.toString(), origin = "http://127.0.0.1:$port")
        check(initResp.statusCode == 200) { "Initialize failed: status ${initResp.statusCode}" }
        val initJson = JSONObject(initResp.body)
        val initResult = initJson.getJSONObject("result")
        check(initResult.getString("protocolVersion") == "2025-11-25") { "Negotiated protocol mismatch" }
        check(initResult.getJSONObject("serverInfo").getString("name") == "dansheng-campus-agent")

        // 8. MCP Protocol: notifications/initialized (expect 202 Accepted)
        val notifRpc = JSONObject()
            .put("jsonrpc", "2.0")
            .put("method", "notifications/initialized")
        val notifResp = AgentProbe.sendHttp(port, "POST", "/mcp", token, notifRpc.toString())
        check(notifResp.statusCode == 202 || notifResp.statusCode == 200) {
            "Expected 202/200 for notifications/initialized, got ${notifResp.statusCode}"
        }

        // 9. MCP Protocol: ping
        val pingRpc = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 2)
            .put("method", "ping")
        val pingResp = AgentProbe.sendHttp(port, "POST", "/mcp", token, pingRpc.toString())
        check(pingResp.statusCode == 200) { "Ping failed: ${pingResp.statusCode}" }
        val pingJson = JSONObject(pingResp.body)
        check(pingJson.has("result"))

        // 10. MCP Protocol: tools/list
        val toolsRpc = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 3)
            .put("method", "tools/list")
        val toolsResp = AgentProbe.sendHttp(port, "POST", "/mcp", token, toolsRpc.toString())
        check(toolsResp.statusCode == 200) { "Tools/list failed: ${toolsResp.statusCode}" }
        val toolsJson = JSONObject(toolsResp.body)
        val tools = toolsJson.getJSONObject("result").getJSONArray("tools")
        val toolNames = (0 until tools.length()).map { tools.getJSONObject(it).getString("name") }.toSet()
        check("search_local_records" in toolNames) { "Missing search_local_records tool" }
        check("get_calendar_summary" in toolNames) { "Missing get_calendar_summary tool" }
        check("get_course_summary" in toolNames) { "Missing get_course_summary tool" }
        check("get_card_summary" in toolNames) { "Missing get_card_summary tool" }

        // 11. MCP Protocol: tools/call (narrow read-only search)
        val callRpc = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", 4)
            .put("method", "tools/call")
            .put("params", JSONObject()
                .put("name", "search_local_records")
                .put("arguments", JSONObject().put("query", "test"))
            )
        val callResp = AgentProbe.sendHttp(port, "POST", "/mcp", token, callRpc.toString())
        check(callResp.statusCode == 200) { "Tools/call failed: ${callResp.statusCode}" }
        val callJson = JSONObject(callResp.body)
        val content = callJson.getJSONObject("result").getJSONArray("content")
        check(content.length() > 0)
        check(content.getJSONObject(0).getString("type") == "text")

        // 12. Test accountChanged() terminates MCP server immediately
        CampusAgent.accountChanged()
        val afterAccountChanged = runCatching {
            Socket("127.0.0.1", port).use { false }
        }.getOrElse { true }
        check(afterAccountChanged) { "Socket must be closed after CampusAgent.accountChanged()" }

        // 13. Restart and test in-flight denial on rt.setAccount
        val reStart = CampusAgent.call(rt, "mcp.start", JSONObject()) as JSONObject
        val newPort = reStart.getInt("port")
        val newToken = (CampusAgent.call(rt, "mcp.token", JSONObject()) as JSONObject).getString("token")

        val switchedAccount = "probe-switched-acc"
        rt.setAccount(switchedAccount)
        val switchedResp = runCatching {
            AgentProbe.sendHttp(newPort, "POST", "/mcp", newToken, pingRpc.toString())
        }
        val denied = switchedResp.getOrNull()?.statusCode in listOf(403, 401) || switchedResp.isFailure
        check(denied) { "Request must be denied after account switch" }

        // 14. Explicit stop
        CampusAgent.call(rt, "mcp.stop", JSONObject())
        val closed = runCatching {
            Socket("127.0.0.1", newPort).use { false }
        }.getOrElse { true }
        check(closed) { "Socket must be closed after mcp.stop" }

    } finally {
        try { CampusAgent.accountChanged() } catch (_: Exception) {}
        try {
            if (originalAccount != null) rt.setAccount(originalAccount) else rt.setAccount("")
        } catch (_: Exception) {}
    }
}
