// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.widget.NestedScrollView
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale

/**
 * Production first-party course file reader for Dansheng eLearning / Canvas files.
 *
 * Provides safe in-app viewing of PDFs, plain text notes, and course images without
 * external viewer apps.
 *
 * Security & Reliability guarantees:
 * 1. Non-exported activity, strictly protected with WindowManager FLAG_SECURE.
 * 2. Fail closed: accepts ONLY canonical files residing strictly under
 *    cacheDir/course-reader/{sha256(activeAccount)}/... and requires runtime.account
 *    to match the intent extra.
 * 3. Zero HTML execution (plain text only), zero remote network loading, and zero document byte logging.
 * 4. Bounded off-main PDF and image rendering preventing OOM and memory leaks.
 * 5. Lifecycle, rotation, and late-callback safe.
 */
class CampusFileReaderActivity : AppCompatActivity() {

    companion object {
        private const val MAX_TEXT_READ_BYTES = 512 * 1024 // 512 KB
        private const val MAX_BITMAP_DIMENSION = 2560
        private const val KEY_CURRENT_PAGE = "course_reader_page_idx"
    }

    private val activityScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val pdfLock = Any()

    private var targetFile: File? = null
    private var targetName: String = ""
    private var targetMime: String = ""
    private var expectedAccountId: String = ""

    private var pfd: ParcelFileDescriptor? = null
    private var pdfRenderer: PdfRenderer? = null
    private var currentPageIndex: Int = 0
    private var totalPageCount: Int = 0
    private var currentRenderJob: Job? = null

    private var displayedPdfBitmap: Bitmap? = null
    private var displayedImageBitmap: Bitmap? = null

    // UI elements
    private lateinit var rootLayout: LinearLayout
    private lateinit var topBarLayout: LinearLayout
    private lateinit var titleTextView: TextView
    private lateinit var subtitleTextView: TextView
    private lateinit var contentContainer: FrameLayout
    private lateinit var progressBar: ProgressBar

    // PDF navigation UI
    private lateinit var pdfBottomBar: LinearLayout
    private lateinit var pdfPrevButton: MaterialButton
    private lateinit var pdfNextButton: MaterialButton
    private lateinit var pdfPageIndicator: TextView

    // PDF viewer views
    private lateinit var pdfScrollView: NestedScrollView
    private lateinit var pdfImageView: ImageView

    private lateinit var palette: ReaderPalette

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.Theme_Dansheng_SheetContent)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)

        // Strict verification: fail closed before inflating UI or accessing files
        if (!verifyAndResolveInput()) {
            finish()
            return
        }

        if (savedInstanceState != null) {
            currentPageIndex = savedInstanceState.getInt(KEY_CURRENT_PAGE, 0)
        }

        palette = ReaderPalette(isNightMode())
        setupWindowDecor()
        buildViewHierarchy()

        loadDocument()
    }

    override fun onResume() {
        super.onResume()
        // Account revocation / switch check: fail closed if account changed
        val app = application as? DanshengApplication
        val current = app?.runtime?.account()
        if (current.isNullOrBlank() || current != expectedAccountId) {
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(KEY_CURRENT_PAGE, currentPageIndex)
    }

    override fun onDestroy() {
        currentRenderJob?.cancel()
        activityScope.cancel()

        displayedPdfBitmap?.let {
            if (!it.isRecycled) it.recycle()
        }
        displayedPdfBitmap = null

        displayedImageBitmap?.let {
            if (!it.isRecycled) it.recycle()
        }
        displayedImageBitmap = null

        closePdfResources()
        super.onDestroy()
    }

    /**
     * Strict path & account validation.
     * Fails closed if any criterion is unmet.
     */
    private fun verifyAndResolveInput(): Boolean {
        val pathExtra = intent?.getStringExtra("path")?.takeIf { it.isNotBlank() } ?: return false
        val accountExtra = intent?.getStringExtra("account_id")?.takeIf { it.isNotBlank() } ?: return false
        val nameExtra = intent?.getStringExtra("name")?.takeIf { it.isNotBlank() } ?: "课程文件"
        val mimeExtra = intent?.getStringExtra("mime")?.lowercase(Locale.ROOT)?.substringBefore(';') ?: ""

        // Verify active runtime account matches
        val app = application as? DanshengApplication ?: return false
        val runtimeAccount = app.runtime.account()?.takeIf { it.isNotBlank() } ?: return false
        if (runtimeAccount != accountExtra) {
            return false
        }

        // Canonical directory boundary check
        val baseReaderDir = File(cacheDir, "course-reader").canonicalFile
        val accountHash = PortUtils.sha256(runtimeAccount.toByteArray(Charsets.UTF_8))
        val allowedAccountDir = File(baseReaderDir, accountHash).canonicalFile

        val candidate = File(pathExtra).canonicalFile
        if (!candidate.exists() || !candidate.isFile) {
            return false
        }

        val allowedPrefix = allowedAccountDir.canonicalPath + File.separator
        if (!candidate.canonicalPath.startsWith(allowedPrefix)) {
            return false
        }

        targetFile = candidate
        targetName = nameExtra
        targetMime = mimeExtra
        expectedAccountId = runtimeAccount
        return true
    }

    private fun isNightMode(): Boolean {
        val nightFlags = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        return nightFlags == Configuration.UI_MODE_NIGHT_YES
    }

    private fun setupWindowDecor() {
        window.setBackgroundDrawable(ColorDrawable(palette.bgSurface))
        window.statusBarColor = palette.cardBg
        window.navigationBarColor = palette.cardBg

        val insetsController = WindowInsetsControllerCompat(window, window.decorView)
        insetsController.isAppearanceLightStatusBars = !palette.isNight
        insetsController.isAppearanceLightNavigationBars = !palette.isNight
    }

    private fun buildViewHierarchy() {
        rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            setBackgroundColor(palette.bgSurface)
        }

        ViewCompat.setOnApplyWindowInsetsListener(rootLayout) { view, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom)
            insets
        }

        // Top App Bar
        topBarLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(palette.cardBg)
            val hPad = dp(12f)
            val vPad = dp(8f)
            setPadding(hPad, vPad, hPad, vPad)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val backButton = MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = "←"
            textSize = 22f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.primaryTeal)
            setBackgroundColor(Color.TRANSPARENT)
            val btnSize = dp(44f)
            minWidth = btnSize
            minimumWidth = btnSize
            setPadding(0, 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(btnSize, btnSize).apply {
                marginEnd = dp(8f)
            }
            contentDescription = "返回"
            setOnClickListener { finish() }
        }
        topBarLayout.addView(backButton)

        val headerTextContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }

        titleTextView = TextView(this).apply {
            text = targetName
            textSize = 17f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        headerTextContainer.addView(titleTextView)

        val fileSizeStr = formatFileSize(targetFile?.length() ?: 0L)
        val fileTypeStr = resolveDisplayType(targetMime, targetFile?.extension)
        subtitleTextView = TextView(this).apply {
            text = "$fileTypeStr · $fileSizeStr"
            textSize = 12f
            setTextColor(palette.textSecondary)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        headerTextContainer.addView(subtitleTextView)
        topBarLayout.addView(headerTextContainer)

        rootLayout.addView(topBarLayout)

        // Divider
        val topDivider = View(this).apply {
            setBackgroundColor(palette.divider)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(1f)
            )
        }
        rootLayout.addView(topDivider)

        // Main Content Area
        contentContainer = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        }

        progressBar = ProgressBar(this).apply {
            indeterminateTintList = ColorStateList.valueOf(palette.primaryTeal)
            visibility = View.GONE
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        }
        contentContainer.addView(progressBar)

        rootLayout.addView(contentContainer)

        // PDF Bottom Control Bar (initially GONE)
        pdfBottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(palette.cardBg)
            val hPad = dp(16f)
            val vPad = dp(8f)
            setPadding(hPad, vPad, hPad, vPad)
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val bottomDivider = View(this).apply {
            setBackgroundColor(palette.divider)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(1f)
            )
        }

        pdfPrevButton = MaterialButton(this).apply {
            text = "上一页"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            cornerRadius = dp(12f)
            setPadding(dp(16f), dp(8f), dp(16f), dp(8f))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setOnClickListener {
                if (currentPageIndex > 0) {
                    renderPdfPage(currentPageIndex - 1)
                }
            }
        }
        pdfBottomBar.addView(pdfPrevButton)

        pdfPageIndicator = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        pdfBottomBar.addView(pdfPageIndicator)

        pdfNextButton = MaterialButton(this).apply {
            text = "下一页"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            cornerRadius = dp(12f)
            setPadding(dp(16f), dp(8f), dp(16f), dp(8f))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setOnClickListener {
                if (currentPageIndex < totalPageCount - 1) {
                    renderPdfPage(currentPageIndex + 1)
                }
            }
        }
        pdfBottomBar.addView(pdfNextButton)

        val bottomContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            addView(bottomDivider)
            addView(pdfBottomBar)
        }
        rootLayout.addView(bottomContainer)

        setContentView(rootLayout)
    }

    private fun loadDocument() {
        val file = targetFile ?: return
        val mime = targetMime
        val ext = file.extension.lowercase(Locale.ROOT)

        val isPdf = mime == "application/pdf" || ext == "pdf"
        val isImage = mime in setOf("image/png", "image/jpeg", "image/jpg", "image/webp") ||
                ext in setOf("png", "jpg", "jpeg", "webp")
        val isText = mime.startsWith("text/") ||
                mime in setOf("application/json", "application/xml") ||
                ext in setOf("txt", "text", "md", "markdown", "csv", "json", "xml", "log", "yaml", "yml", "ini", "conf", "properties", "html", "htm")

        when {
            isPdf -> loadPdf(file)
            isImage -> loadImage(file)
            isText -> loadPlainText(file)
            else -> showUnsupportedCard()
        }
    }

    // =========================================================================
    // PDF Rendering Engine
    // =========================================================================

    private fun loadPdf(file: File) {
        activityScope.launch {
            showProgress(true)
            val opened = withContext(Dispatchers.IO) {
                openPdfDocument(file)
            }
            showProgress(false)

            if (!opened || totalPageCount <= 0) {
                showErrorCard("无法读取 PDF", "文档未包含有效页面或已损坏。")
                return@launch
            }

            initPdfViews()
            renderPdfPage(currentPageIndex.coerceIn(0, totalPageCount - 1))
        }
    }

    private fun openPdfDocument(file: File): Boolean {
        return synchronized(pdfLock) {
            try {
                closePdfResources()
                val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                pfd = descriptor
                val renderer = PdfRenderer(descriptor)
                pdfRenderer = renderer
                totalPageCount = renderer.pageCount
                true
            } catch (t: Throwable) {
                closePdfResources()
                false
            }
        }
    }

    private fun closePdfResources() {
        synchronized(pdfLock) {
            try {
                pdfRenderer?.close()
            } catch (_: Throwable) {}
            pdfRenderer = null

            try {
                pfd?.close()
            } catch (_: Throwable) {}
            pfd = null
        }
    }

    private fun initPdfViews() {
        contentContainer.removeAllViews()
        contentContainer.addView(progressBar)

        pdfImageView = ImageView(this).apply {
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_CENTER
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            )
        }

        pdfScrollView = NestedScrollView(this).apply {
            isFillViewport = true
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            addView(pdfImageView)
        }

        contentContainer.addView(pdfScrollView)
    }

    private fun renderPdfPage(pageIndex: Int) {
        val renderer = pdfRenderer ?: return
        if (pageIndex < 0 || pageIndex >= totalPageCount) return
        currentPageIndex = pageIndex
        updatePdfControls()

        currentRenderJob?.cancel()
        currentRenderJob = activityScope.launch {
            showProgress(true)
            val bitmap = withContext(Dispatchers.IO) {
                synchronized(pdfLock) {
                    if (!isActive || isFinishing || isDestroyed) return@withContext null
                    val r = pdfRenderer ?: return@withContext null
                    if (pageIndex < 0 || pageIndex >= r.pageCount) return@withContext null

                    var page: PdfRenderer.Page? = null
                    try {
                        page = r.openPage(pageIndex)
                        val pageW = page.width.coerceAtLeast(1)
                        val pageH = page.height.coerceAtLeast(1)

                        // Off-main bounded resolution calculation
                        val displayMetrics = resources.displayMetrics
                        val density = displayMetrics.density
                        val screenW = displayMetrics.widthPixels.coerceAtLeast(1)
                        val targetScale = (screenW.toFloat() / pageW.toFloat()).coerceIn(1.0f, (density * 2.0f).coerceAtLeast(1.5f))

                        var finalW = (pageW * targetScale).toInt().coerceAtLeast(1)
                        var finalH = (pageH * targetScale).toInt().coerceAtLeast(1)
                        if (finalW > MAX_BITMAP_DIMENSION || finalH > MAX_BITMAP_DIMENSION) {
                            val downscale = MAX_BITMAP_DIMENSION.toFloat() / maxOf(finalW, finalH).toFloat()
                            finalW = (finalW * downscale).toInt().coerceAtLeast(1)
                            finalH = (finalH * downscale).toInt().coerceAtLeast(1)
                        }

                        val bmp = Bitmap.createBitmap(finalW, finalH, Bitmap.Config.ARGB_8888)
                        val canvas = Canvas(bmp)
                        canvas.drawColor(Color.WHITE)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        bmp
                    } catch (t: Throwable) {
                        null
                    } finally {
                        try {
                            page?.close()
                        } catch (_: Throwable) {}
                    }
                }
            }

            if (!isActive || isFinishing || isDestroyed) {
                bitmap?.recycle()
                return@launch
            }
            showProgress(false)

            if (bitmap != null) {
                val old = displayedPdfBitmap
                displayedPdfBitmap = bitmap
                pdfImageView.setImageBitmap(bitmap)
                pdfScrollView.scrollTo(0, 0)
                if (old != null && old != bitmap && !old.isRecycled) {
                    old.recycle()
                }
            } else {
                showErrorCard("渲染页面失败", "无法渲染第 ${pageIndex + 1} 页。")
            }
        }
    }

    private fun updatePdfControls() {
        pdfBottomBar.visibility = View.VISIBLE
        pdfPageIndicator.text = "${currentPageIndex + 1} / $totalPageCount"
        styleNavButton(pdfPrevButton, currentPageIndex > 0)
        styleNavButton(pdfNextButton, currentPageIndex < totalPageCount - 1)
    }

    private fun styleNavButton(button: MaterialButton, enabled: Boolean) {
        button.isEnabled = enabled
        if (enabled) {
            button.backgroundTintList = ColorStateList.valueOf(palette.tealContainer)
            button.setTextColor(palette.onTealContainer)
            button.strokeWidth = 0
        } else {
            button.backgroundTintList = ColorStateList.valueOf(palette.buttonDisabled)
            button.setTextColor(palette.textDisabled)
            button.strokeWidth = 0
        }
    }

    // =========================================================================
    // Plain Text Reader (Bounded, No HTML Execution, No Document Logging)
    // =========================================================================

    private fun loadPlainText(file: File) {
        activityScope.launch {
            showProgress(true)
            val textData = withContext(Dispatchers.IO) {
                try {
                    val fileLength = file.length()
                    val isTruncated = fileLength > MAX_TEXT_READ_BYTES
                    val buffer = ByteArray(MAX_TEXT_READ_BYTES)
                    var totalRead = 0

                    FileInputStream(file).use { input ->
                        while (totalRead < MAX_TEXT_READ_BYTES) {
                            val count = input.read(buffer, totalRead, MAX_TEXT_READ_BYTES - totalRead)
                            if (count == -1) break
                            totalRead += count
                        }
                    }

                    val decoder = Charsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPLACE)
                        .onUnmappableCharacter(CodingErrorAction.REPLACE)
                    val decoded = decoder.decode(ByteBuffer.wrap(buffer, 0, totalRead)).toString()
                    Pair(decoded, isTruncated)
                } catch (t: Throwable) {
                    null
                }
            }

            if (!isActive || isFinishing || isDestroyed) return@launch
            showProgress(false)

            if (textData != null) {
                displayPlainText(textData.first, textData.second)
            } else {
                showErrorCard("无法读取文件", "读取文本内容时发生错误。")
            }
        }
    }

    private fun displayPlainText(text: String, isTruncated: Boolean) {
        contentContainer.removeAllViews()
        contentContainer.addView(progressBar)
        pdfBottomBar.visibility = View.GONE

        val scrollView = NestedScrollView(this).apply {
            isFillViewport = true
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val textLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            val pad = dp(16f)
            setPadding(pad, pad, pad, pad)
        }

        val textView = TextView(this).apply {
            this.text = text.ifEmpty { "(空文件 / Empty content)" }
            textSize = 14f
            setTextColor(palette.textPrimary)
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
            setLineSpacing(dp(3f).toFloat(), 1.25f)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
        textLayout.addView(textView)

        if (isTruncated) {
            val banner = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                val bPad = dp(12f)
                setPadding(bPad, bPad, bPad, bPad)
                background = GradientDrawable().apply {
                    setColor(palette.cardBg)
                    cornerRadius = dp(8f).toFloat()
                    setStroke(dp(1f), palette.divider)
                }
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    topMargin = dp(16f)
                    bottomMargin = dp(16f)
                }
            }

            val bannerText = TextView(this).apply {
                this.text = "⚠️ 文件内容超过 512 KB，已截断显示前 512 KB 内容"
                textSize = 13f
                setTextColor(palette.textSecondary)
                typeface = Typeface.DEFAULT_BOLD
            }
            banner.addView(bannerText)
            textLayout.addView(banner)
        }

        scrollView.addView(textLayout)
        contentContainer.addView(scrollView)
    }

    // =========================================================================
    // Image Reader (Sampled PNG / JPEG / WebP)
    // =========================================================================

    private fun loadImage(file: File) {
        activityScope.launch {
            showProgress(true)
            val bitmap = withContext(Dispatchers.IO) {
                try {
                    val boundsOptions = BitmapFactory.Options().apply {
                        inJustDecodeBounds = true
                    }
                    BitmapFactory.decodeFile(file.absolutePath, boundsOptions)
                    val outW = boundsOptions.outWidth
                    val outH = boundsOptions.outHeight
                    if (outW <= 0 || outH <= 0) return@withContext null

                    val displayMetrics = resources.displayMetrics
                    val reqW = displayMetrics.widthPixels * 2
                    val reqH = displayMetrics.heightPixels * 2

                    var sampleSize = 1
                    while ((outW / sampleSize) > reqW || (outH / sampleSize) > reqH) {
                        sampleSize *= 2
                    }

                    val decodeOptions = BitmapFactory.Options().apply {
                        inSampleSize = sampleSize
                        inPreferredConfig = Bitmap.Config.ARGB_8888
                    }
                    BitmapFactory.decodeFile(file.absolutePath, decodeOptions)
                } catch (t: Throwable) {
                    null
                }
            }

            if (!isActive || isFinishing || isDestroyed) {
                bitmap?.recycle()
                return@launch
            }
            showProgress(false)

            if (bitmap != null) {
                displayImage(bitmap)
            } else {
                showErrorCard("无法解析图片", "该图片文件损坏或格式不受支持。")
            }
        }
    }

    private fun displayImage(bitmap: Bitmap) {
        contentContainer.removeAllViews()
        contentContainer.addView(progressBar)
        pdfBottomBar.visibility = View.GONE

        val old = displayedImageBitmap
        displayedImageBitmap = bitmap

        val scrollView = NestedScrollView(this).apply {
            isFillViewport = true
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val imageView = ImageView(this).apply {
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_CENTER
            setImageBitmap(bitmap)
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        }

        scrollView.addView(imageView)
        contentContainer.addView(scrollView)

        if (old != null && old != bitmap && !old.isRecycled) {
            old.recycle()
        }
    }

    // =========================================================================
    // Unsupported / Error View States (No Pretending)
    // =========================================================================

    private fun showUnsupportedCard() {
        contentContainer.removeAllViews()
        contentContainer.addView(progressBar)
        pdfBottomBar.visibility = View.GONE

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val padding = dp(24f)
            setPadding(padding, padding, padding, padding)
            background = GradientDrawable().apply {
                setColor(palette.cardBg)
                cornerRadius = dp(16f).toFloat()
                setStroke(dp(1f), palette.divider)
            }
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            ).apply {
                val margin = dp(24f)
                setMargins(margin, margin, margin, margin)
            }
        }

        val iconText = TextView(this).apply {
            text = "📄"
            textSize = 36f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(12f))
        }
        card.addView(iconText)

        val titleText = TextView(this).apply {
            text = "暂不支持直接预览"
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(8f))
        }
        card.addView(titleText)

        val descText = TextView(this).apply {
            val ext = targetFile?.extension?.ifBlank { "未知" } ?: "未知"
            val mimeDisplay = if (targetMime.isNotBlank()) targetMime else "未知 MIME 类型"
            text = "该文件类型 ($ext · $mimeDisplay) 无法在内置阅读器中直接预览。\n您可以通过支持该格式的外部应用打开。"
            textSize = 14f
            setTextColor(palette.textSecondary)
            gravity = Gravity.CENTER
            setLineSpacing(dp(2f).toFloat(), 1.25f)
        }
        card.addView(descText)

        contentContainer.addView(card)
    }

    private fun showErrorCard(title: String, message: String) {
        contentContainer.removeAllViews()
        contentContainer.addView(progressBar)
        pdfBottomBar.visibility = View.GONE

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val padding = dp(24f)
            setPadding(padding, padding, padding, padding)
            background = GradientDrawable().apply {
                setColor(palette.cardBg)
                cornerRadius = dp(16f).toFloat()
                setStroke(dp(1f), palette.divider)
            }
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            ).apply {
                val margin = dp(24f)
                setMargins(margin, margin, margin, margin)
            }
        }

        val iconText = TextView(this).apply {
            text = "⚠️"
            textSize = 36f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(12f))
        }
        card.addView(iconText)

        val titleText = TextView(this).apply {
            text = title
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(8f))
        }
        card.addView(titleText)

        val descText = TextView(this).apply {
            text = message
            textSize = 14f
            setTextColor(palette.textSecondary)
            gravity = Gravity.CENTER
        }
        card.addView(descText)

        contentContainer.addView(card)
    }

    private fun showProgress(show: Boolean) {
        progressBar.visibility = if (show) View.VISIBLE else View.GONE
    }

    private fun dp(value: Float): Int {
        return (value * resources.displayMetrics.density + 0.5f).toInt()
    }

    private fun formatFileSize(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB")
        var size = bytes.toDouble()
        var unitIndex = 0
        while (size >= 1024 && unitIndex < units.size - 1) {
            size /= 1024
            unitIndex++
        }
        return if (unitIndex == 0) "${bytes} B" else String.format(Locale.ROOT, "%.1f %s", size, units[unitIndex])
    }

    private fun resolveDisplayType(mime: String, extension: String?): String {
        val ext = extension?.lowercase(Locale.ROOT) ?: ""
        return when {
            mime == "application/pdf" || ext == "pdf" -> "PDF 文档"
            mime in setOf("image/png", "image/jpeg", "image/jpg", "image/webp") || ext in setOf("png", "jpg", "jpeg", "webp") -> "图片"
            mime.startsWith("text/") || ext in setOf("txt", "text", "md", "csv", "json", "xml", "log") -> "文本文件"
            else -> ext.uppercase(Locale.ROOT).ifBlank { "文件" }
        }
    }

    /**
     * M3 Paper / Teal adaptive color tokens.
     */
    private class ReaderPalette(val isNight: Boolean) {
        val bgSurface = if (isNight) Color.parseColor("#1A1C1E") else Color.parseColor("#FAF8F5")
        val cardBg = if (isNight) Color.parseColor("#242729") else Color.parseColor("#F3EFEA")
        val primaryTeal = if (isNight) Color.parseColor("#4DD0E1") else Color.parseColor("#006A72")
        val onTeal = if (isNight) Color.parseColor("#002022") else Color.WHITE
        val tealContainer = if (isNight) Color.parseColor("#004F55") else Color.parseColor("#CCE8E8")
        val onTealContainer = if (isNight) Color.parseColor("#B2EBF2") else Color.parseColor("#002022")
        val textPrimary = if (isNight) Color.parseColor("#E1E3E3") else Color.parseColor("#191C1D")
        val textSecondary = if (isNight) Color.parseColor("#BFC8C7") else Color.parseColor("#404848")
        val divider = if (isNight) Color.parseColor("#3F4948") else Color.parseColor("#DDE4E3")
        val buttonDisabled = if (isNight) Color.parseColor("#2D3133") else Color.parseColor("#E0DDD9")
        val textDisabled = if (isNight) Color.parseColor("#5A6262") else Color.parseColor("#A0ABAB")
    }
}
