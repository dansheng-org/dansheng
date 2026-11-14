// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Activity
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.text.InputFilter
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.widget.NestedScrollView
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Flagship Material 3 adaptive modal sheet coordinator for Dansheng extensions and authentication.
 *
 * Designed with a warm paper & teal palette, fluid DayNight theme support, full keyboard and
 * rotation safety, no memory leaks or window leaks under cancellation, FLAG_SECURE protected inputs,
 * and zero 2010-era dialogs.
 */
class ModernSheet(private val activity: Activity) {
    private val themed by lazy { android.view.ContextThemeWrapper(activity,R.style.Theme_Dansheng_SheetContent) }

    @Volatile
    private var currentDialog: BottomSheetDialog? = null

    /**
     * Shows a Material 3 confirmation sheet.
     * Throws [PortError]("Cancelled") if the user dismisses or clicks cancel.
     */
    suspend fun confirm(
        title: String,
        message: String,
        positive: String = "确认"
    ): Unit = showCancellableDialog { cont, dialog, palette ->
        val (root, _) = createSheetScaffold(palette)

        // Title
        val titleView = createTitleTextView(title, palette)
        root.addView(titleView)

        // Scrollable message body capped for small phone screens
        val scrollView = createAdaptiveScrollView().apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(16f).toInt()
            }
        }

        val messageView = TextView(activity).apply {
            text = message
            setTextColor(palette.textSecondary)
            textSize = 14f
            setLineSpacing(dp(2f), 1.25f)
        }
        scrollView.addView(messageView)
        root.addView(scrollView)

        // Button bar
        val buttonBar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val cancelButton = createSecondaryButton("取消", palette).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8f).toInt()
            }
            setOnClickListener { safeDismiss(dialog) }
        }

        val confirmButton = createPrimaryButton(positive, palette).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(8f).toInt()
            }
            setOnClickListener {
                cont.resume(Unit)
            }
        }

        buttonBar.addView(cancelButton)
        buttonBar.addView(confirmButton)
        root.addView(buttonBar)

        root
    }

    /**
     * Reviews extension manifest and security profile before installation.
     *
     * Displays name, version, default OFF on install status, friendly categorized permissions,
     * trusted source status, and policy verification. Unverified packages can install without
     * protected policy, or optionally expand/paste an independent release SHA-256 without self-verification suggestions.
     *
     * Returns true if protected policy is enabled; false otherwise.
     * Throws [PortError]("Cancelled") on dismiss or cancel.
     */
    suspend fun review(
        manifest: JSONObject,
        archiveHash: String,
        pinnedOfficial: Boolean,
        hasPolicy: Boolean
    ): Boolean = showCancellableDialog { cont, dialog, palette ->
        val (root, _) = createSheetScaffold(palette)

        val id = manifest.optString("id", "")
        val name = manifest.optString("name", id.ifEmpty { "本地扩展" })
        val version = manifest.optString("version", "1.0.0")

        val scrollView = createAdaptiveScrollView().apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(14f).toInt()
            }
        }

        val content = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        // Header: Extension name and version chip
        val headerLayout = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(12f).toInt()
            }
        }

        val nameText = TextView(activity).apply {
            text = if(pinnedOfficial && id=="official.fudan-sports") "定时抢场" else name
            textSize = 19f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
        }
        headerLayout.addView(nameText)

        val metaText = TextView(activity).apply {
            text = "版本 $version  ·  安装后默认关闭"
            textSize = 12f
            setTextColor(palette.primaryTeal)
            setPadding(0, dp(2f).toInt(), 0, 0)
        }
        headerLayout.addView(metaText)
        content.addView(headerLayout)


        // Trusted source status
        val sourcePill = if (pinnedOfficial) {
            createInfoPill(
                icon = "✓",
                label = "已核验发布版本",
                description = id,
                palette = palette,
                bgColor = palette.statusOfficialBg,
                textColor = palette.statusOfficialText
            )
        } else {
            createInfoPill(
                icon = "ℹ",
                label = "本地扩展",
                description = if (hasPolicy) {
                    "如需登录和预约能力，请核对发布摘要。"
                } else {
                    "普通模式安装，不涉及高权限策略。"
                },
                palette = palette,
                bgColor = palette.statusUnverifiedBg,
                textColor = palette.statusUnverifiedText
            )
        }
        content.addView(sourcePill)

        // Friendly permission categories (no raw grants)
        val permTitle = TextView(activity).apply {
            text = "启用后可使用"
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
            setPadding(0, dp(10f).toInt(), 0, dp(4f).toInt())
        }
        content.addView(permTitle)

        val categories = parseFriendlyCategories(manifest)
        val permCard = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(12f).toInt()
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(palette.cardBg)
                cornerRadius = dp(12f)
                setStroke(dp(1f).toInt(), palette.divider)
            }
            val pad = dp(12f).toInt()
            setPadding(pad, pad, pad, pad)
        }

        for ((catName, catDesc) in categories) {
            val itemLayout = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(3f).toInt(), 0, dp(5f).toInt())
            }
            val catTitle = TextView(activity).apply {
                text = "• $catName"
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(palette.textPrimary)
            }
            val catSub = TextView(activity).apply {
                text = catDesc
                textSize = 12f
                setTextColor(palette.textSecondary)
                setPadding(dp(10f).toInt(), 0, 0, 0)
            }
            itemLayout.addView(catTitle)
            itemLayout.addView(catSub)
            permCard.addView(itemLayout)
        }
        content.addView(permCard)

        // Verification & Install controls
        var hashInputLayout: TextInputLayout? = null
        var hashEditText: TextInputEditText? = null

        val expandableVerification = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(10f).toInt()
            }
        }

        if (!pinnedOfficial && hasPolicy) {
            val toggleVerifyBtn = MaterialButton(themed).apply {
                setBackgroundColor(Color.TRANSPARENT)
                strokeWidth = 0
                elevation = 0f
                text = "粘贴独立发布清单摘要 (SHA-256)..."
                setTextColor(palette.primaryTeal)
                textSize = 13f
                isAllCaps = false
                setOnClickListener {
                    expandableVerification.visibility =
                        if (expandableVerification.visibility == View.VISIBLE) View.GONE else View.VISIBLE
                }
            }
            content.addView(toggleVerifyBtn)

            hashInputLayout = TextInputLayout(themed).apply {
                hint = "发布清单中的 SHA-256 (64位)"
                boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_OUTLINE
                setBoxCornerRadii(dp(10f), dp(10f), dp(10f), dp(10f))
                setBoxStrokeColorStateList(ColorStateList.valueOf(palette.primaryTeal))
                defaultHintTextColor = ColorStateList.valueOf(palette.textSecondary)
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(6f).toInt()
                }
            }

            hashEditText = TextInputEditText(hashInputLayout.context).apply {
                isSingleLine = true
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                filters = arrayOf(InputFilter.LengthFilter(64))
                setTextColor(palette.textPrimary)
                textSize = 12f
                typeface = Typeface.MONOSPACE
            }
            hashInputLayout.addView(hashEditText)
            expandableVerification.addView(hashInputLayout)

            val verifyInstallBtn = createPrimaryButton("验证并启用策略安装", palette).apply {
                setOnClickListener {
                    val typed = hashEditText.text?.toString()?.trim() ?: ""
                    if (typed.equals(archiveHash, ignoreCase = true)) {
                        cont.resume(true)
                    } else {
                        hashInputLayout.error = "校验码不匹配"
                        cont.resumeWithException(PortError("PackageHashMismatch"))
                    }
                }
            }
            expandableVerification.addView(verifyInstallBtn)
            content.addView(expandableVerification)
        }

        scrollView.addView(content)
        root.addView(scrollView)

        // Actions
        val buttonBar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val cancelBtn = createSecondaryButton("取消", palette).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8f).toInt()
            }
            setOnClickListener { safeDismiss(dialog) }
        }

        val defaultPositiveLabel = if (!pinnedOfficial && hasPolicy) "仅安装普通插件" else "确认安装"
        val mainActionBtn = createPrimaryButton(defaultPositiveLabel, palette).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(8f).toInt()
            }
            setOnClickListener {
                if (pinnedOfficial && hasPolicy) {
                    cont.resume(true)
                } else {
                    cont.resume(false)
                }
            }
        }

        buttonBar.addView(cancelBtn)
        buttonBar.addView(mainActionBtn)
        root.addView(buttonBar)

        root
    }

    /**
     * Prompts for authentication credentials using secure inputs and Material 3 design.
     *
     * Window is protected with FLAG_SECURE. No passwords or tokens are ever logged.
     * Throws [PortError]("Cancelled") if dismissed or cancelled.
     */
    suspend fun credentials(
        title: String,
        message: String,
        usernameHint: String?,
        secretHint: String,
        username: String = "",
        emailOptions: List<String> = emptyList()
    ): Pair<String, String> = showCancellableDialog { cont, dialog, palette ->
        dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        val (root, _) = createSheetScaffold(palette)

        val titleView = createTitleTextView(title, palette)
        root.addView(titleView)

        if (message.isNotBlank()) {
            val msgView = TextView(activity).apply {
                text = message
                setTextColor(palette.textSecondary)
                textSize = 14f
                setLineSpacing(dp(2f), 1.2f)
                setPadding(0, 0, 0, dp(12f).toInt())
            }
            root.addView(msgView)
        }

        // Optional username entry
        var usernameEdit: TextInputEditText? = null
        if (!usernameHint.isNullOrBlank()) {
            val userLayout = TextInputLayout(themed).apply {
                hint = usernameHint
                boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_OUTLINE
                setBoxCornerRadii(dp(12f), dp(12f), dp(12f), dp(12f))
                setBoxStrokeColorStateList(ColorStateList.valueOf(palette.primaryTeal))
                defaultHintTextColor = ColorStateList.valueOf(palette.textSecondary)
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(10f).toInt()
                }
            }
            usernameEdit = TextInputEditText(userLayout.context).apply {
                isSingleLine = true
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                setTextColor(palette.textPrimary)
                textSize = 15f
                setText(username)
            }
            userLayout.addView(usernameEdit)
            root.addView(userLayout)
            if(emailOptions.isNotEmpty()) {
                val field=usernameEdit
                val options=com.google.android.material.chip.ChipGroup(themed)
                for(email in emailOptions)options.addView(com.google.android.material.chip.Chip(themed).apply {
                    text="@"+email.substringAfter('@')
                    setOnClickListener { field.setText(email);field.setSelection(email.length) }
                })
                root.addView(options)
            }
        }

        // Secret entry with password toggle
        val secretLayout = TextInputLayout(themed).apply {
            hint = secretHint
            boxBackgroundMode = TextInputLayout.BOX_BACKGROUND_OUTLINE
            setBoxCornerRadii(dp(12f), dp(12f), dp(12f), dp(12f))
            setBoxStrokeColorStateList(ColorStateList.valueOf(palette.primaryTeal))
            defaultHintTextColor = ColorStateList.valueOf(palette.textSecondary)
            endIconMode = TextInputLayout.END_ICON_PASSWORD_TOGGLE
            setEndIconTintList(ColorStateList.valueOf(palette.primaryTeal))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(16f).toInt()
            }
        }

        val secretEdit = TextInputEditText(secretLayout.context).apply {
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setTextColor(palette.textPrimary)
            textSize = 15f
        }
        secretLayout.addView(secretEdit)
        root.addView(secretLayout)

        // Actions
        val buttonBar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }

        val cancelBtn = createSecondaryButton("取消", palette).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8f).toInt()
            }
            setOnClickListener {
                usernameEdit?.text?.clear()
                secretEdit.text?.clear()
                safeDismiss(dialog)
            }
        }

        val positiveLabel = if (title.contains("连接") || title.contains("登录")) "连接" else "确认"
        val submitBtn = createPrimaryButton(positiveLabel, palette).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(8f).toInt()
            }
            setOnClickListener {
                val u = usernameEdit?.text?.toString()?.trim() ?: ""
                val s = secretEdit.text?.toString() ?: ""
                usernameEdit?.text?.clear()
                secretEdit.text?.clear()
                cont.resume(u to s)
            }
        }

        buttonBar.addView(cancelBtn)
        buttonBar.addView(submitBtn)
        root.addView(buttonBar)

        root
    }

    /**
     * Closes any currently displayed sheet dialog immediately without window leaks.
     */
    fun close() {
        val d = synchronized(this) {
            val temp = currentDialog
            currentDialog = null
            temp
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            safeDismiss(d)
        } else {
            activity.runOnUiThread { safeDismiss(d) }
        }
    }

    private fun safeDismiss(dialog: BottomSheetDialog?) {
        if (dialog != null && dialog.isShowing) {
            try {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    dialog.dismiss()
                }
            } catch (_: Throwable) {}
        }
    }

    // --- Internal Helpers & Scaffold ---

    private fun createAdaptiveScrollView(): NestedScrollView {
        return object : NestedScrollView(activity) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val maxH = (resources.displayMetrics.heightPixels * 0.58f).toInt()
                val currentSize = MeasureSpec.getSize(heightMeasureSpec)
                val newSpec = if (currentSize > maxH || MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.UNSPECIFIED) {
                    MeasureSpec.makeMeasureSpec(maxH, MeasureSpec.AT_MOST)
                } else {
                    heightMeasureSpec
                }
                super.onMeasure(widthMeasureSpec, newSpec)
            }
        }.apply {
            isFillViewport = true
        }
    }

    private suspend fun <T> showCancellableDialog(
        block: (cont: CancellableContinuation<T>, dialog: BottomSheetDialog, palette: Palette) -> View
    ): T = withContext(Dispatchers.Main) {
        if (activity.isFinishing || activity.isDestroyed) {
            throw PortError("ActivityUnavailable")
        }

        val palette = Palette(isNightMode())
        val dialog = createBottomSheetDialog(palette)

        suspendCancellableCoroutine<T> { cont ->
            var finished = false

            cont.invokeOnCancellation {
                if (Looper.myLooper() == Looper.getMainLooper()) {
                    safeDismiss(dialog)
                } else {
                    activity.runOnUiThread { safeDismiss(dialog) }
                }
            }

            dialog.setOnDismissListener {
                synchronized(this@ModernSheet) {
                    if (currentDialog === dialog) {
                        currentDialog = null
                    }
                }
                if (!finished && cont.isActive) {
                    finished = true
                    cont.resumeWithException(PortError("Cancelled"))
                }
            }

            val wrappedCont = object : CancellableContinuation<T> by cont {
                override fun resumeWith(result: Result<T>) {
                    finished = true
                    safeDismiss(dialog)
                    cont.resumeWith(result)
                }
            }

            try {
                val view = block(wrappedCont, dialog, palette)
                if (!activity.isFinishing && !activity.isDestroyed) {
                    dialog.setContentView(view)
                    dialog.show()
                } else {
                    safeDismiss(dialog)
                    if (cont.isActive) {
                        cont.resumeWithException(PortError("ActivityUnavailable"))
                    }
                }
            } catch (e: Throwable) {
                safeDismiss(dialog)
                if (cont.isActive) {
                    cont.resumeWithException(if (e is PortError) e else PortError("Cancelled"))
                }
            }
        }
    }

    private fun createBottomSheetDialog(palette: Palette): BottomSheetDialog {
        close()

        val styleRes = R.style.Theme_Dansheng_BottomSheetDialog
        val dialog = BottomSheetDialog(activity, styleRes)
        synchronized(this) {
            currentDialog = dialog
        }

        dialog.behavior.apply {
            isHideable = true
            skipCollapsed = true
            state = BottomSheetBehavior.STATE_EXPANDED
        }
        return dialog
    }

    private fun createSheetScaffold(palette: Palette): Pair<LinearLayout, View> {
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(palette.bgSurface)
                cornerRadii = floatArrayOf(
                    dp(24f), dp(24f),
                    dp(24f), dp(24f),
                    0f, 0f,
                    0f, 0f
                )
            }
            val padHoriz = dp(20f).toInt()
            val padTop = dp(10f).toInt()
            val padBottom = dp(20f).toInt()
            setPadding(padHoriz, padTop, padHoriz, padBottom)
        }

        val dragHandle = View(activity).apply {
            val handleWidth = dp(36f).toInt()
            val handleHeight = dp(4f).toInt()
            layoutParams = LinearLayout.LayoutParams(handleWidth, handleHeight).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(14f).toInt()
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(palette.handleColor)
                cornerRadius = dp(2f)
            }
            contentDescription = "拖动控制条"
        }
        root.addView(dragHandle)

        return root to dragHandle
    }

    private fun createTitleTextView(title: String, palette: Palette): TextView {
        return TextView(activity).apply {
            text = title
            textSize = 19f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(palette.textPrimary)
            setPadding(0, 0, 0, dp(10f).toInt())
        }
    }

    private fun createInfoPill(
        icon: String,
        label: String,
        description: String,
        palette: Palette,
        bgColor: Int,
        textColor: Int
    ): View {
        return LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(10f).toInt()
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(bgColor)
                cornerRadius = dp(10f)
            }
            val padH = dp(12f).toInt()
            val padV = dp(8f).toInt()
            setPadding(padH, padV, padH, padV)

            val row = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            val iconView = TextView(activity).apply {
                text = icon
                textSize = 13f
                setTextColor(textColor)
                setPadding(0, 0, dp(6f).toInt(), 0)
            }
            val labelView = TextView(activity).apply {
                text = label
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(textColor)
            }
            row.addView(iconView)
            row.addView(labelView)
            addView(row)

            val descView = TextView(activity).apply {
                text = description
                textSize = 12f
                setTextColor(palette.textSecondary)
                setPadding(dp(16f).toInt(), dp(2f).toInt(), 0, 0)
            }
            addView(descView)
        }
    }

    private fun parseFriendlyCategories(manifest: JSONObject): List<Pair<String, String>> {
        val categories = mutableListOf<Pair<String, String>>()
        val caps = manifest.optJSONArray("capabilities") ?: JSONArray()
        val networks = manifest.optJSONArray("network") ?: JSONArray()

        val capList = (0 until caps.length()).map { caps.optString(it) }
        val netList = (0 until networks.length()).map { networks.optString(it) }

        if ("browser.write" in capList) categories.add("预约操作" to "只提交你确认过的预约或取消请求")

        if (netList.isNotEmpty() || capList.any { it.contains("http") || it.contains("network") }) {
            val detail = if (netList.isNotEmpty()) {
                val hosts = netList.mapNotNull { runCatching { Uri.parse(it).host }.getOrNull() ?: it }.distinct()
                "访问: " + hosts.take(3).joinToString(", ") + if (hosts.size > 3) " 等" else ""
            } else {
                "通过网络访问指定校园服务"
            }
            categories.add("网络访问" to detail)
        }

        if (capList.any { it.contains("storage") || it.contains("cache") }) {
            categories.add("本地存储" to "在设备本地保存设置与缓存")
        }

        if (capList.any { it.contains("vault") || it.contains("account") || it.contains("credential") }) {
            categories.add("账号凭据" to "安全使用当前账号的身份会话")
        }

        if (capList.any { it.contains("notify") || it.contains("alarm") }) {
            categories.add("系统通知" to "发送任务提醒与状态通知")
        }

        if (capList.any { it.contains("job") || it.contains("wake") || it.contains("task") }) {
            categories.add("后台任务" to "按计划在后台自动执行任务")
        }

        if (categories.isEmpty()) {
            categories.add("基础权限" to "仅在前台界面运行，无额外特权")
        }

        return categories
    }

    private fun createPrimaryButton(text: String, palette: Palette): MaterialButton {
        return MaterialButton(themed).apply {
            this.text = text
            setBackgroundColor(palette.primaryTeal)
            setTextColor(palette.onTeal)
            cornerRadius = dp(14f).toInt()
            minHeight = dp(48f).toInt()
            isAllCaps = false
            elevation = 0f
            typeface = Typeface.DEFAULT_BOLD
            textSize = 15f
        }
    }

    private fun createSecondaryButton(text: String, palette: Palette): MaterialButton {
        return MaterialButton(themed, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            this.text = text
            setTextColor(palette.textSecondary)
            strokeColor = ColorStateList.valueOf(palette.divider)
            strokeWidth = dp(1f).toInt()
            cornerRadius = dp(14f).toInt()
            minHeight = dp(48f).toInt()
            isAllCaps = false
            textSize = 15f
        }
    }

    private fun isNightMode(): Boolean {
        val mode = activity.resources.configuration.uiMode
        return (mode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    }

    private fun dp(value: Float): Float {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value,
            activity.resources.displayMetrics
        )
    }

    private class Palette(val isNight: Boolean) {
        val bgSurface = if (isNight) Color.parseColor("#1A1C1E") else Color.parseColor("#FAF8F5")
        val cardBg = if (isNight) Color.parseColor("#242729") else Color.parseColor("#F3EFEA")
        val primaryTeal = if (isNight) Color.parseColor("#4DD0E1") else Color.parseColor("#006A72")
        val onTeal = if (isNight) Color.parseColor("#002022") else Color.WHITE
        val textPrimary = if (isNight) Color.parseColor("#E1E3E3") else Color.parseColor("#191C1D")
        val textSecondary = if (isNight) Color.parseColor("#BFC8C7") else Color.parseColor("#404848")
        val divider = if (isNight) Color.parseColor("#3F4948") else Color.parseColor("#DDE4E3")
        val handleColor = if (isNight) Color.parseColor("#546E7A") else Color.parseColor("#B0BEC5")

        val statusOffBg = if (isNight) Color.parseColor("#2A2421") else Color.parseColor("#F2ECE9")
        val statusOffText = if (isNight) Color.parseColor("#D7CCC8") else Color.parseColor("#705D56")

        val statusOfficialBg = if (isNight) Color.parseColor("#0E2A18") else Color.parseColor("#E6F4EA")
        val statusOfficialText = if (isNight) Color.parseColor("#A8DAB5") else Color.parseColor("#137333")

        val statusUnverifiedBg = if (isNight) Color.parseColor("#2B2206") else Color.parseColor("#FEF7E0")
        val statusUnverifiedText = if (isNight) Color.parseColor("#FFE082") else Color.parseColor("#945800")
    }
}
