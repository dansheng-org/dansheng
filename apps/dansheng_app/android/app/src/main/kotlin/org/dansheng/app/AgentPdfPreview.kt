// SPDX-License-Identifier: GPL-3.0-or-later

package org.dansheng.app

import android.annotation.TargetApi
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import kotlinx.coroutines.CancellationException
import org.dansheng.android.PortError
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import kotlin.math.sqrt

internal class AgentPdfPreview(private val coreDataDir: File) {
    data class Page(
        val kind: AgentAttachmentPicker.Kind,
        val bytes: ByteArray,
        val pageCount: Int,
        val truncated: Boolean = false,
    )

    fun readPage(id: String, size: Long, pageNumber: Int, checkAccount: () -> Unit): Page {
        checkAccount()
        val descriptor = openVerifiedPdf(id, size)
        try {
            val renderer = try {
                checkAccount()
                PdfRenderer(descriptor)
            } catch (failure: Throwable) {
                // PdfRenderer owns the descriptor once construction succeeds.
                runCatching { descriptor.close() }
                throw failure
            }
            renderer.use {
                val pageCount = it.pageCount
                if (pageCount == 0) throw PortError("PdfPreviewUnavailable")
                if (pageNumber !in 1..pageCount) throw PortError("InvalidPage")
                it.openPage(pageNumber - 1).use { page ->
                    checkAccount()
                    if (Build.VERSION.SDK_INT >= 35) {
                        val text = readPageText(page, pageCount)
                        if (text != null) return text
                    }
                    checkAccount()
                    return Page(AgentAttachmentPicker.Kind.JPEG, renderJpeg(page, checkAccount), pageCount)
                }
            }
        } catch (error: PortError) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (_: IOException) {
            throw PortError("PdfPreviewUnavailable")
        } catch (_: RuntimeException) {
            throw PortError("PdfPreviewUnavailable")
        }
    }

    // Called after Core has authorized the asset and checked the PDF signature.
    private fun openVerifiedPdf(id: String, size: Long): ParcelFileDescriptor {
        try {
            val root = File(coreDataDir.absoluteFile.parentFile!!.canonicalFile, coreDataDir.name)
            val assets = File(root, "assets")
            val file = File(assets, id)
            if (file.parentFile != assets || file.canonicalFile != file ||
                !Files.isDirectory(root.toPath(), NOFOLLOW_LINKS) ||
                !Files.isDirectory(assets.toPath(), NOFOLLOW_LINKS)
            ) throw PortError("FileUnavailable")

            val expected = Os.lstat(file.path)
            if (!OsConstants.S_ISREG(expected.st_mode) || expected.st_size != size) {
                throw PortError("FileUnavailable")
            }
            val fd = Os.open(
                file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0,
            )
            try {
                val opened = Os.fstat(fd)
                if (!OsConstants.S_ISREG(opened.st_mode) || opened.st_size != size ||
                    opened.st_dev != expected.st_dev || opened.st_ino != expected.st_ino
                ) throw PortError("FileUnavailable")
                val header = ByteArray(PDF_SIGNATURE.length)
                if (Os.pread(fd, header, 0, header.size, 0L) != header.size ||
                    header.toString(Charsets.US_ASCII) != PDF_SIGNATURE
                ) throw PortError("AttachmentInvalidContent")
                return ParcelFileDescriptor.dup(fd)
            } finally {
                runCatching { Os.close(fd) }
            }
        } catch (_: ErrnoException) {
            throw PortError("FileUnavailable")
        } catch (_: IOException) {
            throw PortError("FileUnavailable")
        } catch (_: SecurityException) {
            throw PortError("FileUnavailable")
        }
    }

    @TargetApi(35)
    private fun readPageText(page: PdfRenderer.Page, pageCount: Int): Page? {
        val (bytes, truncated) = try {
            boundedAgentText(page.textContents.asSequence().map { it.text })
        } catch (_: RuntimeException) {
            return null
        }
        if (bytes.toString(Charsets.UTF_8).isBlank()) return null
        return Page(AgentAttachmentPicker.Kind.TEXT, bytes, pageCount, truncated)
    }

    private fun renderJpeg(page: PdfRenderer.Page, checkAccount: () -> Unit): ByteArray {
        val width = page.width
        val height = page.height
        if (width <= 0 || height <= 0) throw PortError("PdfPreviewUnavailable")
        val scale = minOf(MAX_SIDE.toDouble() / maxOf(width, height), sqrt(MAX_PIXELS / (width.toDouble() * height)))
        val bitmap = Bitmap.createBitmap(
            (width * scale).toInt().coerceAtLeast(1),
            (height * scale).toInt().coerceAtLeast(1),
            Bitmap.Config.ARGB_8888,
        )
        try {
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val jpeg = ByteArrayOutputStream()
            for (quality in JPEG_QUALITIES) {
                checkAccount()
                jpeg.reset()
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, jpeg)) {
                    throw PortError("PdfPreviewUnavailable")
                }
                if (jpeg.size() <= AgentAttachmentPicker.MAX_BINARY_BYTES) return jpeg.toByteArray()
            }
            throw PortError("AttachmentTooLarge")
        } finally {
            bitmap.recycle()
        }
    }

    private companion object {
        const val MAX_SIDE = 1600
        const val MAX_PIXELS = 1_500_000
        val JPEG_QUALITIES = intArrayOf(85, 65, 45)
    }
}

/** Normalize text and stop at a UTF-8 code-point boundary without copying an entire PDF page. */
internal fun boundedAgentText(parts: Sequence<String>): Pair<ByteArray, Boolean> {
    val output = StringBuilder()
    var byteCount = 0
    for (part in parts) {
        if (part.isEmpty()) continue
        var offset = if (output.isEmpty()) 0 else -1
        while (offset < part.length) {
            val codePoint = if (offset < 0) '\n'.code else part.codePointAt(offset)
            offset += Character.charCount(codePoint)
            if ((Character.isISOControl(codePoint) && codePoint !in 9..10 && codePoint != 13) ||
                codePoint in 0xD800..0xDFFF
            ) continue
            val byteLength = when {
                codePoint <= 0x7F -> 1
                codePoint <= 0x7FF -> 2
                codePoint <= 0xFFFF -> 3
                else -> 4
            }
            if (byteCount + byteLength > AgentAttachmentPicker.MAX_TEXT_BYTES) {
                return output.toString().toByteArray(Charsets.UTF_8) to true
            }
            output.appendCodePoint(codePoint)
            byteCount += byteLength
        }
    }
    return output.toString().toByteArray(Charsets.UTF_8) to false
}
