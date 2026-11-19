// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.dansheng.android.PortError
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.BasicFileAttributes
import java.util.Base64

/** Adapts account-owned Core assets to the same validated input as a local attachment. */
internal class AgentRemoteFiles(
    private val coreDataDir: File,
    private val verifyCachedPdf: (File, Long, ByteArray) -> Unit = ::verifyOpenCachedPdf,
) {
    private enum class Source(val method: String, val id: String, val owner: String) {
        CANVAS("canvas.material.download", "official.canvas.materials", "service:canvas"),
        CLOUD("fudan.cloud.download", "official.fudan.cloud.files", "service:fudan-cloud"),
    }

    private val operations = Mutex()

    suspend fun read(
        account: String,
        params: JSONObject,
        checkAccount: () -> Unit,
        campusRead: suspend (String, JSONObject) -> Any?,
        core: (String, JSONObject) -> Any?,
    ): JSONObject = scoped(checkAccount) {
        val source = when (params.opt("source")) {
            "canvas" -> Source.CANVAS
            "cloud" -> Source.CLOUD
            else -> throw PortError("InvalidInput")
        }
        val request = JSONObject().put("account_id", account).put("max_bytes", MAX_DOWNLOAD_BYTES)
        when (source) {
            Source.CANVAS -> {
                request.put("course_id", canvasId(params, "course_id"))
                    .put("file_id", canvasId(params, "file_id"))
                if (params.has("assignment_id")) {
                    request.put("assignment_id", canvasId(params, "assignment_id"))
                }
            }
            Source.CLOUD -> {
                val path = (params.opt("path") as? String)
                    ?.takeIf { it.length in 1..4096 } ?: throw PortError("InvalidInput")
                request.put("path", path).put("verify_listing", true)
            }
        }
        val asset = campusRead(source.method, request) as? JSONObject
            ?: throw PortError("SourceSchemaChanged")
        checkAccount()
        val id = assetId(asset, account, source)
        if (asset.optString("state") != "ready") throw PortError("FileUnavailable")
        val size = when (val raw = asset.opt("size")) {
            is Int -> raw.toLong()
            is Long -> raw
            else -> throw PortError("AttachmentInvalidContent")
        }
        if (size <= 0) throw PortError("AttachmentInvalidContent")

        val name = asset.opt("name") as? String ?: throw PortError("SourceSchemaChanged")
        val mime = asset.opt("mime_type") as? String ?: throw PortError("SourceSchemaChanged")
        val kind = AgentAttachmentPicker.resolveKind(mime, name)
        val assetParams = JSONObject().put("account_id", account).put("asset_id", id)
        if (kind == AgentAttachmentPicker.Kind.PDF) {
            if (size > MAX_AGENT_PDF_BYTES) throw PortError("AgentPdfTooLarge")
            if (size > MAX_INLINE_PDF_BYTES) {
                val prefix = readChunk(
                    assetParams, id, size, 0, PDF_SIGNATURE.length, checkAccount, core,
                )
                if (prefix.toString(Charsets.US_ASCII) != PDF_SIGNATURE) {
                    throw PortError("AttachmentInvalidContent")
                }
                val file = withContext(Dispatchers.IO) {
                    checkAccount()
                    cachedPdf(id, size, prefix)
                }
                return@scoped JSONObject()
                    .put("name", AgentAttachmentPicker.attachmentName(name, kind))
                    .put("mime_type", kind.mime)
                    .put("size", size)
                    .put("cache_path", file.path)
            }
        }
        if (kind.isText && size > AgentAttachmentPicker.MAX_TEXT_BYTES) {
            throw PortError("AttachmentTextTooLarge")
        }
        if (kind != AgentAttachmentPicker.Kind.PDF && !kind.isText && size > AgentAttachmentPicker.MAX_BINARY_BYTES) {
            throw PortError("AttachmentTooLarge")
        }
        val bytes = readBytes(assetParams, id, size.toInt(), checkAccount, core)
        AgentAttachmentPicker.payload(name, kind, bytes, pdfLimit = MAX_INLINE_PDF_BYTES)
    }

    private fun cachedPdf(id: String, size: Long, prefix: ByteArray): File {
        try {
            val directory = coreDataDir.absoluteFile
            val root = File(directory.parentFile!!.canonicalFile, directory.name)
            val assets = File(root, "assets")
            val file = File(assets, id)
            if (file.parentFile != assets || file.canonicalFile != file ||
                !Files.isDirectory(root.toPath(), NOFOLLOW_LINKS) ||
                !Files.isDirectory(assets.toPath(), NOFOLLOW_LINKS)
            ) throw PortError("FileUnavailable")
            val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, NOFOLLOW_LINKS)
            if (!attributes.isRegularFile || attributes.size() != size) throw PortError("FileUnavailable")
            verifyCachedPdf(file, size, prefix)
            return file
        } catch (_: IOException) {
            throw PortError("FileUnavailable")
        } catch (_: SecurityException) {
            throw PortError("FileUnavailable")
        }
    }

    private fun readBytes(
        assetParams: JSONObject,
        id: String,
        size: Int,
        checkAccount: () -> Unit,
        core: (String, JSONObject) -> Any?,
    ): ByteArray {
        val bytes = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val length = minOf(CHUNK_BYTES, size - offset)
            readChunk(assetParams, id, size.toLong(), offset, length, checkAccount, core).copyInto(bytes, offset)
            offset += length
        }
        return bytes
    }

    private fun readChunk(
        assetParams: JSONObject,
        id: String,
        size: Long,
        offset: Int,
        length: Int,
        checkAccount: () -> Unit,
        core: (String, JSONObject) -> Any?,
    ): ByteArray {
        checkAccount()
        val chunk = core(
            "files.read",
            assetParams.put("offset", offset).put("length", length),
        ) as? JSONObject ?: throw PortError("FileUnavailable")
        checkAccount()
        val data = chunk.opt("data") as? String ?: throw PortError("FileUnavailable")
        val nextOffset = offset.toLong() + length
        if (data.length != (length + 2) / 3 * 4 ||
            chunk.optString("asset_id") != id ||
            chunk.optString("encoding") != "base64" ||
            chunk.optLong("offset", -1) != offset.toLong() ||
            chunk.optLong("length", -1) != length.toLong() ||
            chunk.optLong("next_offset", -1) != nextOffset ||
            chunk.opt("eof") != (nextOffset == size)
        ) throw PortError("FileUnavailable")
        val decoded = try {
            Base64.getDecoder().decode(data)
        } catch (_: IllegalArgumentException) {
            throw PortError("FileUnavailable")
        }
        if (decoded.size != length) throw PortError("FileUnavailable")
        return decoded
    }

    suspend fun clear(
        account: String,
        checkAccount: () -> Unit,
        core: (String, JSONObject) -> Any?,
    ): JSONObject = scoped(checkAccount) {
        var deleted = 0
        for (source in Source.entries) {
            val query = JSONObject().put("account_id", account).put("source_id", source.id)
                .put("limit", CACHE_PAGE_SIZE)
            // Snapshot IDs before deleting so OFFSET cannot skip rows we just removed.
            val ids = linkedSetOf<String>()
            for (page in 0 until MAX_CACHE_PAGES) {
                checkAccount()
                val result = core("files.list", query.put("offset", page * CACHE_PAGE_SIZE)) as? JSONObject
                    ?: throw PortError("SourceSchemaChanged")
                val items = result.optJSONArray("items") ?: throw PortError("SourceSchemaChanged")
                if (items.length() > CACHE_PAGE_SIZE) throw PortError("SourceSchemaChanged")
                for (index in 0 until items.length()) {
                    val asset = items.optJSONObject(index) ?: throw PortError("SourceSchemaChanged")
                    if (asset.optString("owner") == source.owner) ids.add(assetId(asset, account, source))
                }
                if (items.length() < CACHE_PAGE_SIZE) break
                if (page == MAX_CACHE_PAGES - 1) throw PortError("LimitExceeded")
            }
            for (id in ids) {
                checkAccount()
                val result = try {
                    core("files.delete", JSONObject().put("account_id", account).put("asset_id", id))
                } catch (error: PortError) {
                    if (error.code == "NotFound") continue
                    throw error
                }
                if (result !is JSONObject || result.opt("deleted") != true || result.optString("asset_id") != id) {
                    throw PortError("SourceSchemaChanged")
                }
                deleted++
            }
        }
        JSONObject().put("deleted", deleted)
    }

    private suspend fun scoped(checkAccount: () -> Unit, run: suspend () -> JSONObject): JSONObject =
        operations.withLock {
            checkAccount()
            try {
                run()
            } finally {
                checkAccount()
            }
        }

    private fun canvasId(params: JSONObject, field: String): String =
        (params.opt(field) as? String)?.takeIf(CANVAS_ID::matches) ?: throw PortError("InvalidInput")

    private fun assetId(asset: JSONObject, account: String, source: Source): String {
        val id = asset.optString("asset_id")
        if (asset.optString("account_id") != account || asset.optString("source_id") != source.id ||
            asset.optString("owner") != source.owner || !UUID_V4.matches(id)
        ) throw PortError("FileUnavailable")
        return id
    }

    private companion object {
        const val MAX_DOWNLOAD_BYTES = 200 * 1024 * 1024
        const val MAX_INLINE_PDF_BYTES = 8 * 1024 * 1024
        const val MAX_AGENT_PDF_BYTES = 100 * 1024 * 1024
        const val CHUNK_BYTES = 128 * 1024
        const val CACHE_PAGE_SIZE = 128
        const val MAX_CACHE_PAGES = 64
        val CANVAS_ID = Regex("[1-9][0-9]{0,23}")
        val UUID_V4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    }
}

// Verify the actual open file before exposing its path to the caller.
private fun verifyOpenCachedPdf(file: File, size: Long, prefix: ByteArray) {
    try {
        val uid = Process.myUid()
        val expected = Os.lstat(file.path)
        if (!OsConstants.S_ISREG(expected.st_mode) || expected.st_size != size || expected.st_uid != uid) {
            throw PortError("FileUnavailable")
        }
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        try {
            val opened = Os.fstat(fd)
            if (!OsConstants.S_ISREG(opened.st_mode) || opened.st_size != size || opened.st_uid != uid ||
                opened.st_dev != expected.st_dev || opened.st_ino != expected.st_ino
            ) throw PortError("FileUnavailable")
            val header = ByteArray(prefix.size)
            if (Os.pread(fd, header, 0, header.size, 0L) != header.size || !header.contentEquals(prefix)) {
                throw PortError("AttachmentInvalidContent")
            }
        } finally {
            runCatching { Os.close(fd) }
        }
    } catch (_: ErrnoException) {
        throw PortError("FileUnavailable")
    }
}
