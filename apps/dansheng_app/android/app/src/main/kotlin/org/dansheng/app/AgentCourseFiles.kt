// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.Locale

/** Reads the same account-owned Core assets used by the eLearning file viewer. */
internal class AgentCourseFiles {
    private val operations = Mutex()

    suspend fun read(
        account: String,
        params: JSONObject,
        checkAccount: () -> Unit,
        campusRead: suspend (String, JSONObject) -> Any?,
        core: (String, JSONObject) -> Any?,
    ): JSONObject = scoped(checkAccount) {
        val courseId = canvasId(params, "course_id")
        val fileId = canvasId(params, "file_id")
        val course = JSONObject().put("account_id", account).put("course_id", courseId)
        // The locked download API looks up a global file ID. Verify course membership
        // and the advertised MIME/size before using it.
        val materials = campusRead("canvas.materials.sync", course) as? JSONArray
            ?: throw PortError("SourceSchemaChanged")
        checkAccount()
        val material = (0 until materials.length()).firstNotNullOfOrNull { index ->
            val payload = materials.optJSONObject(index)?.optJSONObject("payload")
            payload?.takeIf { it.optString("id") == fileId }
        } ?: throw PortError("FileUnavailable")
        if (material.optBoolean("locked_for_user") || material.optBoolean("hidden_for_user")) {
            throw PortError("FileUnavailable")
        }
        val filename = material.optString("filename")
        val displayName = material.optString("display_name")
        requirePdf((material.opt("content-type") as? String).orEmpty(), filename.ifBlank { displayName })
        boundedSize(material)

        val asset = campusRead("canvas.material.download", course.put("file_id", fileId)) as? JSONObject
            ?: throw PortError("SourceSchemaChanged")
        checkAccount()
        val id = assetId(asset, account)
        val name = asset.optString("name").ifBlank { displayName.ifBlank { filename } }
        requirePdf(asset.optString("mime_type"), filename.ifBlank { name })
        val size = boundedSize(asset)
        val bytes = ByteArray(size)
        var offset = 0
        val assetParams = JSONObject().put("account_id", account).put("asset_id", id)
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
            if (offset == 0 && !PDF_HEADER.indices.all { decoded[it] == PDF_HEADER[it] }) {
                throw PortError("AttachmentInvalidContent")
            }
            decoded.copyInto(bytes, offset)
            offset += length
        }
        JSONObject()
            .put("name", pdfName(name))
            .put("mime_type", PDF_MIME)
            .put("data", Base64.getEncoder().encodeToString(bytes))
    }

    suspend fun clear(
        account: String,
        checkAccount: () -> Unit,
        core: (String, JSONObject) -> Any?,
    ): JSONObject = scoped(checkAccount) {
        val query = JSONObject().put("account_id", account).put("source_id", SOURCE)
            .put("limit", CACHE_PAGE_SIZE)
        // Snapshot IDs before deleting so OFFSET cannot skip rows we just removed.
        val ids = linkedSetOf<String>()
        for (page in 0 until MAX_CACHE_PAGES) {
            checkAccount()
            val result = core("files.list", query.put("offset", page * CACHE_PAGE_SIZE)) as? JSONObject
                ?: throw PortError("SourceSchemaChanged")
            checkAccount()
            val items = result.optJSONArray("items") ?: throw PortError("SourceSchemaChanged")
            if (items.length() > CACHE_PAGE_SIZE) throw PortError("SourceSchemaChanged")
            for (index in 0 until items.length()) {
                val asset = items.optJSONObject(index) ?: throw PortError("SourceSchemaChanged")
                if (asset.optString("owner") == OWNER) ids.add(assetId(asset, account))
            }
            if (items.length() < CACHE_PAGE_SIZE) break
            if (page == MAX_CACHE_PAGES - 1) throw PortError("LimitExceeded")
        }
        var deleted = 0
        for (id in ids) {
            checkAccount()
            val result = try {
                core("files.delete", JSONObject().put("account_id", account).put("asset_id", id))
            } catch (error: PortError) {
                if (error.code == "NotFound") continue
                throw error
            }
            checkAccount()
            if (result !is JSONObject || result.opt("deleted") != true || result.optString("asset_id") != id) {
                throw PortError("SourceSchemaChanged")
            }
            deleted++
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

    private fun assetId(asset: JSONObject, account: String): String {
        val id = asset.optString("asset_id")
        if (asset.optString("account_id") != account || asset.optString("source_id") != SOURCE ||
            asset.optString("owner") != OWNER || !UUID_V4.matches(id)
        ) throw PortError("FileUnavailable")
        return id
    }

    private fun boundedSize(metadata: JSONObject): Int {
        val raw = metadata.opt("size")
        val size = if (raw is Int || raw is Long) (raw as Number).toLong() else -1L
        if (size > MAX_BYTES) throw PortError("AttachmentTooLarge")
        if (size < PDF_HEADER.size) throw PortError("AttachmentInvalidContent")
        return size.toInt()
    }

    private fun requirePdf(contentType: String, filename: String) {
        val mime = contentType.substringBefore(';').trim().lowercase(Locale.ROOT)
        val pdfExtension = filename.endsWith(".pdf", ignoreCase = true)
        if (mime != PDF_MIME && !(mime in GENERIC_MIME && pdfExtension)) {
            throw PortError("AttachmentUnsupportedType")
        }
    }

    private fun pdfName(name: String): String {
        val clean = name.replace(UNSAFE_NAME, "_").trim { it.isWhitespace() || it == '.' }
        val stem = if (clean.endsWith(".pdf", ignoreCase = true)) clean.dropLast(4) else clean
        return stem.take(116)
            .trimEnd { it.isWhitespace() || it == '.' || Character.isHighSurrogate(it) }
            .ifEmpty { "课程文件" } + ".pdf"
    }

    private companion object {
        const val SOURCE = "official.canvas.materials"
        const val OWNER = "service:canvas"
        const val PDF_MIME = "application/pdf"
        const val MAX_BYTES = 2 * 1024 * 1024
        const val CHUNK_BYTES = 128 * 1024
        const val CACHE_PAGE_SIZE = 128
        const val MAX_CACHE_PAGES = 64
        val PDF_HEADER = "%PDF-".toByteArray(Charsets.US_ASCII)
        val GENERIC_MIME = setOf("", "application/octet-stream", "binary/octet-stream", "*/*")
        val CANVAS_ID = Regex("[1-9][0-9]{0,23}")
        val UUID_V4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        val UNSAFE_NAME = Regex("""[\p{Cc}\p{Cf}<>:"/\\|?*]""")
    }
}
