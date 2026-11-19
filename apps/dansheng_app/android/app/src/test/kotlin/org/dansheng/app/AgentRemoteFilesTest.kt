// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import kotlinx.coroutines.runBlocking
import org.dansheng.android.PortError
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNoException
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.util.Base64

class AgentRemoteFilesTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun cloudPdfReturnsOriginalBytesAndIgnoresLegacyPage() = runBlocking {
        val path = "3/7/directory/扫描件.pdf"
        val output = readOriginal(
            cloudParams().put("path", path).put("page", 3),
            pdfBytes(2 * MIB + 23),
            "application/pdf",
        ) { method, params ->
            assertEquals("fudan.cloud.download", method)
            assertEquals(path, params.getString("path"))
            assertTrue(params.getBoolean("verify_listing"))
            cloudAsset(2 * MIB + 23)
        }
        assertEquals("文件.pdf", output.getString("name"))
    }

    @Test
    fun canvasAssignmentPdfAtInlineLimitReturnsOriginalBytes() = runBlocking {
        val output = readOriginal(
            JSONObject().put("source", "canvas").put("course_id", "3")
                .put("assignment_id", "5").put("file_id", "7"),
            pdfBytes(INLINE_LIMIT),
            "application/pdf",
        ) { method, params ->
            assertEquals("canvas.material.download", method)
            assertEquals("3", params.getString("course_id"))
            assertEquals("5", params.getString("assignment_id"))
            assertEquals("7", params.getString("file_id"))
            asset("service:canvas", "official.canvas.materials", INLINE_LIMIT)
        }
        assertEquals("文件.pdf", output.getString("name"))
    }

    @Test
    fun largePdfReturnsOnlyTheVerifiedOriginalCachePathAndMetadata() = runBlocking {
        for (size in listOf(INLINE_LIMIT + 1, PDF_LIMIT)) {
            val root = temporary.newFolder()
            val cached = cacheFile(root, size)
            var verified = false
            val output = AgentRemoteFiles(root) { file, expectedSize, prefix ->
                assertEquals(cached.canonicalFile, file)
                assertEquals(size.toLong(), expectedSize)
                assertArrayEquals(PDF_HEADER, prefix)
                verified = true
            }.read(
                ACCOUNT, cloudParams(), {},
                { _, params ->
                    assertEquals(MAX_DOWNLOAD, params.getInt("max_bytes"))
                    cloudAsset(size).put("name", "../unsafe:name.PDF").put("path", "../ignored")
                },
                { method, params -> signatureChunk(method, params, size) },
            )
            assertTrue(verified)
            assertEquals(setOf("name", "mime_type", "size", "cache_path"), output.keys().asSequence().toSet())
            assertEquals("unsafe_name.PDF", output.getString("name"))
            assertEquals("application/pdf", output.getString("mime_type"))
            assertEquals(size.toLong(), output.getLong("size"))
            assertEquals(cached.canonicalPath, output.getString("cache_path"))
        }
    }

    @Test
    fun invalidAssetMetadataFailsBeforeReadingCoreBytes() {
        val overrides = listOf(
            Triple("account_id", "other", "FileUnavailable"),
            Triple("owner", "owner", "FileUnavailable"),
            Triple("source_id", "other", "FileUnavailable"),
            Triple("state", "partial", "FileUnavailable"),
            Triple("asset_id", "../outside", "FileUnavailable"),
            Triple("size", 0, "AttachmentInvalidContent"),
            Triple("size", "100", "AttachmentInvalidContent"),
            Triple("size", 100.5, "AttachmentInvalidContent"),
            Triple("name", JSONObject.NULL, "SourceSchemaChanged"),
            Triple("mime_type", 123, "SourceSchemaChanged"),
            Triple("mime_type", "text/plain", "AttachmentUnsupportedType"),
        )
        for ((field, value, code) in overrides) {
            assertFailure(code) {
                unusedCache().read(
                    ACCOUNT, cloudParams(), {},
                    { _, _ -> cloudAsset(100).put(field, value) },
                    { _, _ -> error("Core read must not run for invalid metadata") },
                )
            }
        }
    }

    @Test
    fun bothPdfDeliveryPathsRejectInvalidSignatures() {
        for (size in listOf(PDF_HEADER.size, INLINE_LIMIT + 1)) {
            assertFailure("AttachmentInvalidContent") {
                unusedCache().read(
                    ACCOUNT, cloudParams(), {},
                    { _, _ -> cloudAsset(size) },
                    { method, params -> signatureChunk(method, params, size, "hello".toByteArray()) },
                )
            }
        }
    }

    @Test
    fun invalidCoreChunkMetadataPreventsDelivery() {
        val size = INLINE_LIMIT + 1
        assertFailure("FileUnavailable") {
            unusedCache().read(
                ACCOUNT, cloudParams(), {},
                { _, _ -> cloudAsset(size) },
                { method, params -> signatureChunk(method, params, size).put("next_offset", 4) },
            )
        }
    }

    @Test
    fun mismatchedCachedFileSizePreventsDelivery() {
        val size = INLINE_LIMIT + 1
        val root = temporary.newFolder()
        cacheFile(root, size - 1)
        assertFailure("FileUnavailable") { readCached(unusedCache(root), size) }
    }

    @Test
    fun directoryCannotBeReturnedAsAnOriginalFile() {
        val root = temporary.newFolder()
        assertTrue(File(root, "assets/$ID").mkdirs())
        assertFailure("FileUnavailable") { readCached(unusedCache(root), INLINE_LIMIT + 1) }
    }

    @Test
    fun symlinkOutsideCoreCacheCannotBeReturned() {
        val size = INLINE_LIMIT + 1
        val root = temporary.newFolder()
        val outside = cacheFile(temporary.newFolder(), size)
        val assets = File(root, "assets")
        assertTrue(assets.mkdir())
        try {
            Files.createSymbolicLink(File(assets, ID).toPath(), outside.toPath())
        } catch (failure: UnsupportedOperationException) {
            assumeNoException(failure)
        } catch (failure: IOException) {
            if (!System.getProperty("os.name").startsWith("Windows")) throw failure
            assumeNoException(failure)
        }
        assertFailure("FileUnavailable") { readCached(unusedCache(root), size) }
    }

    @Test
    fun accountChangeDuringCacheVerificationPreventsDelivery() {
        val size = INLINE_LIMIT + 1
        val root = temporary.newFolder()
        cacheFile(root, size)
        var active = true
        val files = AgentRemoteFiles(root) { _, _, _ -> active = false }
        assertFailure("AccountChanged") {
            readCached(files, size) { if (!active) throw PortError("AccountChanged") }
        }
    }

    @Test
    fun oversizedPdfsAndTextAreRejectedWithoutReadingOrExtracting() {
        for (size in listOf(PDF_LIMIT + 1, MAX_DOWNLOAD)) {
            assertFailure("AgentPdfTooLarge") {
                unusedCache().read(
                    ACCOUNT, cloudParams(), {},
                    { _, params ->
                        assertEquals(MAX_DOWNLOAD, params.getInt("max_bytes"))
                        cloudAsset(size)
                    },
                    { _, _ -> error("No bytes or excerpts expected") },
                )
            }
        }
        assertFailure("AttachmentTextTooLarge") {
            unusedCache().read(
                ACCOUNT, cloudParams(), {},
                { _, _ -> cloudAsset(24 * 1024 + 1).put("name", "campus.csv").put("mime_type", "text/csv") },
                { _, _ -> error("No bytes or excerpts expected") },
            )
        }
    }

    @Test
    fun smallTextReturnsUnmodifiedUtf8AndMimeType() = runBlocking {
        val bytes = "列,数据\r\n一,二\r\n".toByteArray()
        val output = readOriginal(cloudParams(), bytes, "text/csv") { _, _ ->
            cloudAsset(bytes.size).put("name", "campus.csv").put("mime_type", "text/csv")
        }
        assertEquals("campus.csv", output.getString("name"))
    }

    private suspend fun readOriginal(
        input: JSONObject,
        bytes: ByteArray,
        mime: String,
        download: (String, JSONObject) -> JSONObject,
    ): JSONObject {
        val output = unusedCache().read(
            ACCOUNT, input, {},
            { method, params ->
                assertEquals(ACCOUNT, params.getString("account_id"))
                assertEquals(MAX_DOWNLOAD, params.getInt("max_bytes"))
                download(method, params)
            },
            { method, params ->
                assertCoreRead(method, params)
                val start = params.getInt("offset")
                val end = start + params.getInt("length")
                chunk(bytes.copyOfRange(start, end), start, bytes.size)
            },
        )
        assertEquals(setOf("name", "mime_type", "data"), output.keys().asSequence().toSet())
        assertEquals(mime, output.getString("mime_type"))
        assertArrayEquals(bytes, Base64.getDecoder().decode(output.getString("data")))
        return output
    }

    private suspend fun readCached(
        files: AgentRemoteFiles,
        size: Int,
        checkAccount: () -> Unit = {},
    ): JSONObject = files.read(
        ACCOUNT, cloudParams(), checkAccount,
        { _, _ -> cloudAsset(size) },
        { method, params -> signatureChunk(method, params, size) },
    )

    private fun signatureChunk(
        method: String,
        params: JSONObject,
        size: Int,
        prefix: ByteArray = PDF_HEADER,
    ): JSONObject {
        assertCoreRead(method, params)
        assertEquals(0, params.getInt("offset"))
        assertEquals(PDF_HEADER.size, params.getInt("length"))
        return chunk(prefix, 0, size)
    }

    private fun assertCoreRead(method: String, params: JSONObject) {
        assertEquals("files.read", method)
        assertEquals(ACCOUNT, params.getString("account_id"))
        assertEquals(ID, params.getString("asset_id"))
    }

    private fun assertFailure(code: String, read: suspend () -> JSONObject) {
        val failure = assertThrows(PortError::class.java) { runBlocking { read() } }
        assertEquals(code, failure.code)
    }

    private fun unusedCache(root: File = temporary.root): AgentRemoteFiles =
        AgentRemoteFiles(root) { _, _, _ -> error("Unexpected cached PDF verification") }

    private fun cacheFile(root: File, size: Int): File {
        val file = File(root, "assets/$ID")
        assertTrue(file.parentFile!!.mkdir())
        RandomAccessFile(file, "rw").use {
            it.setLength(size.toLong())
            it.write(PDF_HEADER)
        }
        return file
    }

    private fun pdfBytes(size: Int): ByteArray =
        ByteArray(size) { (it % 251).toByte() }.also { PDF_HEADER.copyInto(it) }

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
        const val MIB = 1024 * 1024
        const val INLINE_LIMIT = 8 * MIB
        const val PDF_LIMIT = 100 * MIB
        const val MAX_DOWNLOAD = 200 * MIB
        val PDF_HEADER = PDF_SIGNATURE.toByteArray(Charsets.US_ASCII)
    }
}
