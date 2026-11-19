// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.dansheng.android.PortError
import org.json.JSONObject
import java.util.Base64

/** Adapts account-owned Core assets to the same validated input as a local attachment. */
internal class AgentRemoteFiles {
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
        val request = JSONObject().put("account_id", account).put("max_bytes", MAX_DOCUMENT_BYTES)
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
        val size = asset.optLong("size", -1)
        if (size <= 0) throw PortError("AttachmentInvalidContent")
        if (size > MAX_DOCUMENT_BYTES) throw PortError("AttachmentTooLarge")

        val name = asset.optString("name")
        val kind = AgentAttachmentPicker.resolveKind(asset.optString("mime_type"), name)
        val assetParams = JSONObject().put("account_id", account).put("asset_id", id)
        if (kind == AgentAttachmentPicker.Kind.PDF) {
            val extracted = extractPdfText(assetParams, name, id, core)
            checkAccount()
            if (extracted != null) return@scoped extracted
        }
        val limit = when {
            kind == AgentAttachmentPicker.Kind.PDF -> MAX_DOCUMENT_BYTES
            kind.isText -> AgentAttachmentPicker.MAX_TEXT_BYTES
            else -> AgentAttachmentPicker.MAX_BINARY_BYTES
        }
        if (size > limit) throw PortError(if (kind.isText) "AttachmentTextTooLarge" else "AttachmentTooLarge")
        val bytes = readBytes(assetParams, id, size.toInt(), checkAccount, core)
        AgentAttachmentPicker.payload(name, kind, bytes, pdfLimit = MAX_DOCUMENT_BYTES)
    }

    private fun extractPdfText(
        params: JSONObject,
        name: String,
        id: String,
        core: (String, JSONObject) -> Any?,
    ): JSONObject? {
        val result = try {
            core("files.text", params) as? JSONObject ?: throw PortError("SourceSchemaChanged")
        } catch (error: PortError) {
            // A small scanned, encrypted, or complex PDF can still be passed
            // to a model that supports the file format directly.
            if (error.code in TEXT_FALLBACK_ERRORS) return null
            throw error
        }
        if (result.optString("asset_id") != id) throw PortError("FileUnavailable")
        val text = (result.opt("text") as? String ?: throw PortError("SourceSchemaChanged"))
            .filterNot { it.isISOControl() && it != '\t' && it != '\n' && it != '\r' }
        if (text.isBlank()) return null
        return AgentAttachmentPicker.payload(name, AgentAttachmentPicker.Kind.TEXT, text.toByteArray())
            .put("extracted", true).put("truncated", result.optBoolean("truncated"))
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
            checkAccount()
            val length = minOf(CHUNK_BYTES, size - offset)
            val chunk = core(
                "files.read",
                assetParams.put("offset", offset).put("length", length),
            ) as? JSONObject ?: throw PortError("FileUnavailable")
            checkAccount()
            val data = chunk.opt("data") as? String ?: throw PortError("FileUnavailable")
            if (data.length != (length + 2) / 3 * 4 ||
                chunk.optString("asset_id") != id ||
                chunk.optString("encoding") != "base64" ||
                chunk.optLong("offset", -1) != offset.toLong() ||
                chunk.optLong("length", -1) != length.toLong() ||
                chunk.optLong("next_offset", -1) != (offset + length).toLong() ||
                chunk.opt("eof") != (offset + length == size)
            ) throw PortError("FileUnavailable")
            val decoded = try {
                Base64.getDecoder().decode(data)
            } catch (_: IllegalArgumentException) {
                throw PortError("FileUnavailable")
            }
            if (decoded.size != length) throw PortError("FileUnavailable")
            decoded.copyInto(bytes, offset)
            offset += length
        }
        return bytes
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
        const val MAX_DOCUMENT_BYTES = 8 * 1024 * 1024
        const val CHUNK_BYTES = 128 * 1024
        const val CACHE_PAGE_SIZE = 128
        const val MAX_CACHE_PAGES = 64
        val CANVAS_ID = Regex("[1-9][0-9]{0,23}")
        val UUID_V4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        val TEXT_FALLBACK_ERRORS = setOf(
            "CapabilityUnavailable", "MethodNotFound", "DocumentParseError", "DocumentTooComplex",
            "DocumentTooLarge", "EncryptedDocument", "UnsupportedContent", "NoExtractableText",
        )
    }
}
