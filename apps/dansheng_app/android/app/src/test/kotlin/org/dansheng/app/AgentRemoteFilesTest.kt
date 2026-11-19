// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import kotlinx.coroutines.runBlocking
import org.dansheng.android.PortError
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class AgentRemoteFilesTest {
    @Test
    fun scannedCloudPdfFallsBackToItsValidatedBytes() = runBlocking {
        val pdf = ByteArray(5 * 1024 * 1024 / 2)
        "%PDF-1.7\nfixture\n".toByteArray().copyInto(pdf)
        val path = "3/7/directory/扫描件.pdf"
        val output = AgentRemoteFiles().read(
            ACCOUNT,
            JSONObject().put("source", "cloud").put("path", path),
            {},
            { method, params ->
                assertEquals("fudan.cloud.download", method)
                assertEquals(path, params.getString("path"))
                assertTrue(params.getBoolean("verify_listing"))
                asset("service:fudan-cloud", "official.fudan.cloud.files", pdf.size)
            },
            { method, params ->
                assertEquals(ID, params.getString("asset_id"))
                when (method) {
                    "files.text" -> throw PortError("NoExtractableText")
                    "files.read" -> {
                        val start = params.getInt("offset")
                        val length = params.getInt("length")
                        val end = start + length
                        JSONObject().put("asset_id", ID).put("encoding", "base64")
                            .put("offset", start).put("length", length).put("next_offset", end)
                            .put("eof", end == pdf.size)
                            .put("data", Base64.getEncoder().encodeToString(pdf.copyOfRange(start, end)))
                    }
                    else -> error("Unexpected method: $method")
                }
            },
        )
        assertEquals("application/pdf", output.getString("mime_type"))
        assertArrayEquals(pdf, Base64.getDecoder().decode(output.getString("data")))
    }

    @Test
    fun largeCanvasAssignmentPdfReturnsExtractedUtf8WithoutReadingItsBytes() = runBlocking {
        val text = "中文作业内容"
        val output = AgentRemoteFiles().read(
            ACCOUNT,
            JSONObject().put("source", "canvas").put("course_id", "3")
                .put("assignment_id", "5").put("file_id", "7"),
            {},
            { method, params ->
                assertEquals("canvas.material.download", method)
                assertEquals("3", params.getString("course_id"))
                assertEquals("5", params.getString("assignment_id"))
                assertEquals("7", params.getString("file_id"))
                asset("service:canvas", "official.canvas.materials", 4 * 1024 * 1024)
            },
            { method, _ ->
                assertEquals("files.text", method)
                JSONObject().put("asset_id", ID).put("text", text).put("truncated", true)
            },
        )
        assertEquals("text/plain", output.getString("mime_type"))
        assertEquals(text, Base64.getDecoder().decode(output.getString("data")).toString(Charsets.UTF_8))
        assertTrue(output.getBoolean("extracted"))
        assertTrue(output.getBoolean("truncated"))
    }

    private fun asset(owner: String, source: String, size: Int): JSONObject =
        JSONObject().put("owner", owner).put("source_id", source).put("account_id", ACCOUNT)
            .put("state", "ready").put("asset_id", ID).put("size", size)
            .put("name", "文件.pdf").put("mime_type", "application/pdf")

    private companion object {
        const val ACCOUNT = "fixture"
        const val ID = "fe38751a-6dfe-4d9c-a6c2-41dc1e4dd55f"
    }
}
