// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.util.Base64
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.dansheng.android.PortError
import org.json.JSONObject

internal object AgentAttachmentPicker {
    const val MAX_BINARY_BYTES = 2 * 1024 * 1024
    const val MAX_TEXT_BYTES = 24 * 1024
    private const val MAX_NAME_LENGTH = 120
    private val unsafeNameChars = Regex("""[\p{Cc}\p{Cf}<>:"/\\|?*]""")

    enum class Kind(val mime: String, val isText: Boolean, vararg val extensions: String) {
        PDF("application/pdf", false, "pdf"),
        PNG("image/png", false, "png"),
        JPEG("image/jpeg", false, "jpg", "jpeg", "jpe"),
        WEBP("image/webp", false, "webp"),
        TEXT("text/plain", true, "txt", "text", "log"),
        MARKDOWN("text/markdown", true, "md", "markdown", "mdown", "mkd"),
        CSV("text/csv", true, "csv"),
        JSON("application/json", true, "json"),
    }

    suspend fun read(resolver: ContentResolver, uri: Uri): JSONObject = withContext(Dispatchers.IO) {
        try {
            if (uri.scheme != ContentResolver.SCHEME_CONTENT) throw PortError("AttachmentReadFailed")
            val displayName = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
                }
            val name = safeName(displayName)
            val kind = resolveKind(resolver.getType(uri), name)
            val limit = if (kind.isText) MAX_TEXT_BYTES else MAX_BINARY_BYTES
            val bytes = resolver.openInputStream(uri)?.use { readBounded(it, limit) }
                ?: throw PortError("AttachmentReadFailed")
            payload(name, kind, bytes)
        } catch (e: CancellationException) {
            throw e
        } catch (e: PortError) {
            throw e
        } catch (_: Exception) {
            throw PortError("AttachmentReadFailed")
        }
    }

    fun payload(displayName: String, kind: Kind, bytes: ByteArray, pdfLimit: Int = MAX_BINARY_BYTES): JSONObject {
        val limit = when {
            kind == Kind.PDF -> pdfLimit
            kind.isText -> MAX_TEXT_BYTES
            else -> MAX_BINARY_BYTES
        }
        if (bytes.size > limit) throw PortError(
            if (kind.isText) "AttachmentTextTooLarge" else "AttachmentTooLarge",
        )
        if (!hasExpectedContent(kind, bytes)) throw PortError("AttachmentInvalidContent")
        return JSONObject().put("name", nameForKind(safeName(displayName), kind))
            .put("mime_type", kind.mime).put("data", Base64.getEncoder().encodeToString(bytes))
    }

    private fun safeName(displayName: String?): String = displayName.orEmpty()
        .substringAfterLast('/').substringAfterLast('\\')
        .replace(unsafeNameChars, "_").trim { it.isWhitespace() || it == '.' }
        .ifEmpty { "attachment" }

    private fun extension(name: String): String = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

    private fun nameForKind(name: String, kind: Kind): String {
        val hasExtension = extension(name) in kind.extensions
        val suffix = if (hasExtension) name.substring(name.lastIndexOf('.')) else ".${kind.extensions.first()}"
        val stem = if (hasExtension) name.dropLast(suffix.length) else name
        return stem.take(MAX_NAME_LENGTH - suffix.length)
            .trimEnd { it.isWhitespace() || it == '.' || Character.isHighSurrogate(it) }
            .ifEmpty { "attachment" } + suffix
    }

    fun resolveKind(reportedMime: String?, name: String): Kind {
        val mime = reportedMime?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT).orEmpty()
        val ext = extension(name)
        val fromExtension = Kind.entries.firstOrNull { ext in it.extensions }
        val kind = when (mime) {
            "", "application/octet-stream", "binary/octet-stream", "*/*" -> fromExtension
            "text/plain" -> fromExtension?.takeIf { it.isText } ?: Kind.TEXT
            "image/jpg", "image/pjpeg" -> Kind.JPEG
            "text/x-markdown" -> Kind.MARKDOWN
            "application/csv" -> Kind.CSV
            "text/json" -> Kind.JSON
            else -> Kind.entries.firstOrNull { it.mime == mime }
        } ?: throw PortError("AttachmentUnsupportedType")
        if (fromExtension != null && fromExtension != kind && !(fromExtension.isText && kind.isText)) {
            throw PortError("AttachmentUnsupportedType")
        }
        return kind
    }

    private fun readBounded(stream: InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (output.size() < limit) {
            val count = stream.read(buffer, 0, minOf(buffer.size, limit - output.size()))
            if (count < 0) return output.toByteArray()
            if (count == 0) {
                val next = stream.read()
                if (next < 0) return output.toByteArray()
                output.write(next)
            } else {
                output.write(buffer, 0, count)
            }
        }
        if (stream.read() < 0) return output.toByteArray()
        throw PortError(if (limit == MAX_TEXT_BYTES) "AttachmentTextTooLarge" else "AttachmentTooLarge")
    }

    private fun hasExpectedContent(kind: Kind, bytes: ByteArray): Boolean = when (kind) {
        Kind.PDF -> bytes.matchesAt(0, "%PDF-".toByteArray(Charsets.US_ASCII))
        Kind.PNG -> bytes.matchesAt(0, byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 13, 10, 26, 10))
        Kind.JPEG -> bytes.matchesAt(0, byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()))
        Kind.WEBP -> bytes.matchesAt(0, "RIFF".toByteArray(Charsets.US_ASCII)) &&
            bytes.matchesAt(8, "WEBP".toByteArray(Charsets.US_ASCII)) &&
            listOf("VP8 ", "VP8L", "VP8X").any { bytes.matchesAt(12, it.toByteArray(Charsets.US_ASCII)) }
        Kind.TEXT, Kind.MARKDOWN, Kind.CSV, Kind.JSON -> isUtf8Text(bytes)
    }

    private fun ByteArray.matchesAt(offset: Int, signature: ByteArray): Boolean =
        size >= offset + signature.size && signature.indices.all { this[offset + it] == signature[it] }

    private fun isUtf8Text(bytes: ByteArray): Boolean = try {
        bytes.isNotEmpty() && Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).none {
            Character.isISOControl(it) && it != '\t' && it != '\n' && it != '\r'
        }
    } catch (_: CharacterCodingException) {
        false
    }
}
