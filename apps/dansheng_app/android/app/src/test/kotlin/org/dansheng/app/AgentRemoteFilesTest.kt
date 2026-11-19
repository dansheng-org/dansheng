// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import kotlinx.coroutines.runBlocking
import org.dansheng.android.PortError
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class AgentRemoteFilesTest {
    private val remoteFiles = AgentRemoteFiles { _, _, _, _ -> error("Unexpected PDF preview") }

    @Test
    fun scannedCloudPdfFallsBackToItsValidatedBytes() = runBlocking {
        val pdf = ByteArray(5 * 1024 * 1024 / 2)
        "%PDF-1.7\nfixture\n".toByteArray().copyInto(pdf)
        val path = "3/7/directory/扫描件.pdf"
        val output = remoteFiles.read(
            ACCOUNT,
            JSONObject().put("source", "cloud").put("path", path),
            {},
            { method, params ->
                assertEquals("fudan.cloud.download", method)
                assertEquals(path, params.getString("path"))
                assertTrue(params.getBoolean("verify_listing"))
                assertEquals(MAX_DOWNLOAD, params.getInt("max_bytes"))
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
                        chunk(pdf.copyOfRange(start, end), start, pdf.size)
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
        val output = remoteFiles.read(
            ACCOUNT,
            JSONObject().put("source", "canvas").put("course_id", "3")
                .put("assignment_id", "5").put("file_id", "7"),
            {},
            { method, params ->
                assertEquals("canvas.material.download", method)
                assertEquals("3", params.getString("course_id"))
                assertEquals("5", params.getString("assignment_id"))
                assertEquals("7", params.getString("file_id"))
                assertEquals(MAX_DOWNLOAD, params.getInt("max_bytes"))
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

    @Test
    fun largePdfReadsOnlyCoreSignatureAndPreviewsFirstPage() = runBlocking {
        val files = AgentRemoteFiles { id, size, page, _ ->
            assertEquals(ID, id)
            assertEquals(MAX_DOWNLOAD.toLong(), size)
            assertEquals(1, page)
            AgentPdfPreview.Page(AgentAttachmentPicker.Kind.TEXT, "第 1 页".toByteArray(), 2)
        }
        val output = files.read(
            ACCOUNT, cloudParams(), {},
            { _, _ -> cloudAsset(MAX_DOWNLOAD) },
            { method, params ->
                assertEquals("files.read", method)
                assertEquals(ACCOUNT, params.getString("account_id"))
                assertEquals(ID, params.getString("asset_id"))
                assertEquals(0, params.getInt("offset"))
                assertEquals(5, params.getInt("length"))
                chunk(PDF_SIGNATURE.toByteArray(), 0, MAX_DOWNLOAD)
            },
        )
        assertEquals("page_text", output.getString("preview"))
        assertEquals("text/plain", output.getString("mime_type"))
        assertEquals(1, output.getInt("page"))
        assertEquals(2, output.getInt("page_count"))
        assertTrue(output.getBoolean("extracted"))
        assertTrue(output.getBoolean("truncated"))
        assertEquals("第 1 页", Base64.getDecoder().decode(output.getString("data")).toString(Charsets.UTF_8))
    }

    @Test
    fun explicitPageUsesJpegPreviewEvenForSmallPdf() = runBlocking {
        val jpeg = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte())
        val files = AgentRemoteFiles { _, _, page, checkAccount ->
            checkAccount()
            assertEquals(3, page)
            AgentPdfPreview.Page(AgentAttachmentPicker.Kind.JPEG, jpeg, 3)
        }
        val output = files.read(
            ACCOUNT, cloudParams().put("page", 3L), {},
            { _, _ -> cloudAsset(100) },
            { method, _ ->
                assertEquals("files.read", method)
                chunk(PDF_SIGNATURE.toByteArray(), 0, 100)
            },
        )
        assertEquals("page_image", output.getString("preview"))
        assertEquals("image/jpeg", output.getString("mime_type"))
        assertEquals(3, output.getInt("page"))
        assertEquals(3, output.getInt("page_count"))
        assertFalse(output.getBoolean("extracted"))
        assertTrue(output.getBoolean("truncated"))
        assertArrayEquals(jpeg, Base64.getDecoder().decode(output.getString("data")))
    }

    @Test
    fun pdfMetadataAndSignatureMustPassBeforePreview() {
        for ((field, value) in mapOf(
            "account_id" to "other",
            "owner" to "owner",
            "source_id" to "other",
            "state" to "partial",
            "asset_id" to "../outside",
        )) {
            val error = assertThrows(PortError::class.java) {
                runBlocking {
                    remoteFiles.read(
                        ACCOUNT, cloudParams().put("page", 1), {},
                        { _, _ -> cloudAsset(100).put(field, value) },
                        { _, _ -> error("Core read must not run for invalid metadata") },
                    )
                }
            }
            assertEquals("FileUnavailable", error.code)
        }
        val error = assertThrows(PortError::class.java) {
            runBlocking {
                remoteFiles.read(
                    ACCOUNT, cloudParams().put("page", 1), {},
                    { _, _ -> cloudAsset(100) },
                    { _, _ -> chunk("hello".toByteArray(), 0, 100) },
                )
            }
        }
        assertEquals("AttachmentInvalidContent", error.code)
    }

    @Test
    fun malformedPageIsRejectedBeforeDownload() {
        for (value in listOf(0, -1, 1.5, "2", Int.MAX_VALUE.toLong() + 1, JSONObject.NULL)) {
            val error = assertThrows(PortError::class.java) {
                runBlocking {
                    remoteFiles.read(
                        ACCOUNT, cloudParams().put("page", value), {},
                        { _, _ -> error("No download expected") },
                        { _, _ -> error("No Core read expected") },
                    )
                }
            }
            assertEquals("InvalidInput", error.code)
        }
    }

    @Test
    fun accountChangeDuringPreviewPreventsDelivery() {
        var active = true
        val files = AgentRemoteFiles { _, _, _, _ ->
            active = false
            AgentPdfPreview.Page(AgentAttachmentPicker.Kind.TEXT, "secret".toByteArray(), 1)
        }
        val error = assertThrows(PortError::class.java) {
            runBlocking {
                files.read(
                    ACCOUNT, cloudParams().put("page", 1), { if (!active) throw PortError("AccountChanged") },
                    { _, _ -> cloudAsset(100) },
                    { _, _ -> chunk(PDF_SIGNATURE.toByteArray(), 0, 100) },
                )
            }
        }
        assertEquals("AccountChanged", error.code)
    }

    @Test
    fun largeCampusTextReturnsAPlainExcerptWithoutReadingFileBytes() = runBlocking {
        val output = remoteFiles.read(
            ACCOUNT, cloudParams(), {},
            { _, _ ->
                cloudAsset(MAX_DOWNLOAD).put("name", "campus.csv").put("mime_type", "text/csv")
            },
            { method, params ->
                assertEquals("files.text", method)
                assertEquals(ID, params.getString("asset_id"))
                JSONObject().put("asset_id", ID).put("text", "课程,作业\n").put("truncated", true)
            },
        )
        assertEquals("text_excerpt", output.getString("preview"))
        assertEquals("text/plain", output.getString("mime_type"))
        assertFalse(output.getBoolean("extracted"))
        assertTrue(output.getBoolean("truncated"))
        assertEquals("课程,作业\n", Base64.getDecoder().decode(output.getString("data")).toString(Charsets.UTF_8))
    }

    @Test
    fun textByteLimitKeepsWholeUtf8CodePointsAndNormalizesControls() {
        val prefix = "a".repeat(AgentAttachmentPicker.MAX_TEXT_BYTES - 6)
        val (bytes, truncated) = boundedAgentText(sequenceOf(prefix + '\u0000', "😀😀"))
        assertTrue(truncated)
        assertEquals(prefix + "\n😀", bytes.toString(Charsets.UTF_8))
        assertEquals(AgentAttachmentPicker.MAX_TEXT_BYTES - 1, bytes.size)
    }

    private fun cloudParams(): JSONObject = JSONObject().put("source", "cloud").put("path", "3/7/文件.pdf")

    private fun cloudAsset(size: Int): JSONObject = asset("service:fudan-cloud", "official.fudan.cloud.files", size)

    private fun chunk(bytes: ByteArray, offset: Int, fileSize: Int): JSONObject =
        JSONObject().put("asset_id", ID).put("encoding", "base64")
            .put("offset", offset).put("length", bytes.size).put("next_offset", offset + bytes.size)
            .put("eof", offset + bytes.size == fileSize)
            .put("data", Base64.getEncoder().encodeToString(bytes))

    private fun asset(owner: String, source: String, size: Int): JSONObject =
        JSONObject().put("owner", owner).put("source_id", source).put("account_id", ACCOUNT)
            .put("state", "ready").put("asset_id", ID).put("size", size)
            .put("name", "文件.pdf").put("mime_type", "application/pdf")

    private companion object {
        const val ACCOUNT = "fixture"
        const val ID = "fe38751a-6dfe-4d9c-a6c2-41dc1e4dd55f"
        const val MAX_DOWNLOAD = 200 * 1024 * 1024
    }
}
