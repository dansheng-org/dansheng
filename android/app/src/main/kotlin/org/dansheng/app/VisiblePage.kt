// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.WebView
import com.google.android.material.button.MaterialButton
import com.google.android.material.color.MaterialColors
import android.widget.LinearLayout
import android.widget.TextView
import org.dansheng.android.PortError
import org.dansheng.android.VisibleLoginPort
import org.dansheng.android.origin
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

open class VisiblePage(private val grantGate: GrantGate) : VisibleLoginPort {
    companion object {
        internal const val SILENT_TIMEOUT_MS = 30_000L
        internal const val SILENT_COOLDOWN_MS = 300_000L
    }

    protected open fun loadPage(view: WebView, url: String) = view.loadUrl(url)
    protected open fun postOnMain(action: Runnable): Boolean = mainHandler.post(action)
    // Lets instrumentation assert that a hidden login showed nothing.
    protected open fun onInteractiveShown(accountId: String) {}
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    @Volatile private var attachedActivity: WeakReference<Activity>? = null

    @Volatile private var venueCredentialProvider: ((String) -> String?)? = null
    @Volatile private var venueAccountIsCurrent: ((String) -> Boolean)? = null
    @Volatile private var venuePasswordUnconfirmed: ((String) -> Unit)? = null
    @Volatile private var venueLoginVerified: ((String) -> Unit)? = null
    @Volatile private var venueAccountActive: ((String) -> Boolean)? = null
    private val backgroundLogins=java.util.concurrent.ConcurrentHashMap<String,java.util.concurrent.atomic.AtomicInteger>()
    private fun enterWithoutPrompt(account:String) {
        backgroundLogins.compute(account){_,v->(v?:java.util.concurrent.atomic.AtomicInteger()).apply{incrementAndGet()}}
    }
    private fun leaveWithoutPrompt(account:String) {
        backgroundLogins.computeIfPresent(account){_,v->v.takeIf{it.decrementAndGet()>0}}
    }
    internal fun <T> withoutPrompt(account:String, block:()->T):T {
        enterWithoutPrompt(account)
        return try {block()} finally {leaveWithoutPrompt(account)}
    }
    internal suspend fun <T> withoutPromptSuspending(account:String, block:suspend ()->T):T {
        enterWithoutPrompt(account)
        return try {block()} finally {leaveWithoutPrompt(account)}
    }

    // Keeps a failing hidden login from running again on every read. Password safety is
    // separate: a failure after the password went out suspends it, see CampusLogins.
    private val silentFailures=java.util.concurrent.ConcurrentHashMap<String,Long>()
    private fun recordSilentFailure(account:String) { silentFailures[account]=SystemClock.elapsedRealtime() }
    internal fun silentBlocked(account:String):Boolean {
        val failedAt=silentFailures[account] ?: return false
        return SystemClock.elapsedRealtime()-failedAt<SILENT_COOLDOWN_MS
    }
    internal fun clearSilentFailure(account:String) { silentFailures.remove(account) }
    internal fun clearSilentFailures() { silentFailures.clear() }

    fun attach(activity: Activity?) {
        attachedActivity = activity?.let { WeakReference(it) }
    }
    private fun liveActivity() = attachedActivity?.get()?.takeIf { !it.isFinishing && !it.isDestroyed }
    internal fun hasForeground() = liveActivity() != null

    fun attachVenueCredentials(
        provider: (String) -> String?,
        accountIsCurrent: (String) -> Boolean,
        passwordUnconfirmed: (String) -> Unit = {},
        loginVerified: (String) -> Unit = {},
        accountActive: (String) -> Boolean = accountIsCurrent
    ) {
        this.venueAccountActive = accountActive
        this.venueCredentialProvider = provider
        this.venueAccountIsCurrent = accountIsCurrent
        this.venuePasswordUnconfirmed = passwordUnconfirmed
        this.venueLoginVerified = loginVerified
    }

    fun clearVenueCredentials() {
        this.venueCredentialProvider = null
        this.venueAccountIsCurrent = null
        this.venuePasswordUnconfirmed = null
        this.venueLoginVerified = null
        this.venueAccountActive = null
    }

    override fun show(accountId: String, url: String, webView: WebView, complete: (Result<String>) -> Unit) {
        complete(Result.failure(PortError("PermissionDenied")))
    }

    override fun showAuthorized(principal: String, accountId: String, url: String, webView: WebView, complete: (Result<String>) -> Unit) {
        postOnMain {
            val targetOrigin = try {
                origin(url)
            } catch (_: Exception) {
                complete(Result.failure(PortError("InvalidUrl")))
                return@postOnMain
            }

            if (grantGate.policyFor(principal, targetOrigin) == null) {
                complete(Result.failure(PortError("UntrustedOrigin")))
                return@postOnMain
            }

            // Only trusted host code can enter withoutPrompt, whichever package asks.
            val activity = liveActivity()?.takeUnless { backgroundLogins.containsKey(accountId) }

            val credProvider = venueCredentialProvider
            val isCurrent = venueAccountIsCurrent
            val isBookingOrigin = targetOrigin == VenueAuthRestoreHelper.BOOKING_ORIGIN
            if (credProvider==null || isCurrent==null || !grantGate.trustedVenueLogin(principal) || !isBookingOrigin || !isCurrent(accountId)) {
                if (activity != null) showInteractiveDialog(activity, principal, accountId, targetOrigin, url, webView, false, complete)
                else complete(Result.failure(PortError("VisibleUiUnavailable")))
                return@postOnMain
            }
            layoutHidden(webView)

            val active = venueAccountActive ?: isCurrent
            // Suspended on disk BEFORE the password leaves, so a kill or a concurrent reader can never
            // send it a second time; only a verified login lifts it again.
            val deliver: (String) -> String? = { acc -> credProvider(acc)?.also { venuePasswordUnconfirmed?.invoke(acc) } }
            fun noteFailure() = recordSilentFailure(accountId)
            // Same WebView: the user sees exactly where the hidden attempt stopped.
            fun resumeVisibly() {
                noteFailure()
                val current = liveActivity()
                if (current != null) showInteractiveDialog(current, principal, accountId, targetOrigin, url, webView, true, complete)
                else complete(Result.failure(PortError("AuthenticationRequired")))
            }
            val helper = VenueAuthRestoreHelper(
                grantGate = grantGate,
                principal = principal,
                accountId = accountId,
                targetOrigin = targetOrigin,
                targetUrl = url,
                webView = webView,
                credentialProvider = deliver,
                accountIsCurrent = { acc -> active(acc) && grantGate.trustedVenueLogin(principal) },
                onPageLoader = { v, u -> loadPage(v, u) },
                mainHandler = runCatching { mainHandler }.getOrNull(),
                onInteractiveFallback = if (activity != null) ::resumeVisibly else null,
                onComplete = { result ->
                    if (result.isSuccess) { clearSilentFailure(accountId); venueLoginVerified?.invoke(accountId) } else noteFailure()
                    complete(result)
                },
                timeoutMs = if (activity != null) SILENT_TIMEOUT_MS else VenueAuthRestoreHelper.TIMEOUT_MS
            )
            helper.start()
        }
    }

    private fun layoutHidden(webView: WebView) {
        if(webView.width==0 || webView.height==0) {
            val m=webView.resources.displayMetrics
            webView.measure(android.view.View.MeasureSpec.makeMeasureSpec(m.widthPixels,android.view.View.MeasureSpec.EXACTLY),
                android.view.View.MeasureSpec.makeMeasureSpec(m.heightPixels,android.view.View.MeasureSpec.EXACTLY))
            webView.layout(0,0,m.widthPixels,m.heightPixels)
        }
    }

    private fun showInteractiveDialog(
        activity: Activity,
        principal: String,
        accountId: String,
        targetOrigin: String,
        url: String,
        webView: WebView,
        resume: Boolean,
        complete: (Result<String>) -> Unit
    ) {
        val finished = AtomicBoolean(false)
        var dialog: Dialog? = null
        var watcher: VenueAuthRestoreHelper? = null

        fun finishWith(result: Result<String>) {
            if (finished.compareAndSet(false, true)) {
                postOnMain {
                    watcher?.stop()
                    try {
                        (webView.parent as? ViewGroup)?.removeView(webView)
                        dialog?.dismiss()
                    } catch (_: Exception) {}
                    // A person passed the school's checks, which also resets its wrong-password count,
                    // so at most one wrong automatic attempt can happen between successful logins.
                    if (result.isSuccess && grantGate.trustedVenueLogin(principal) && targetOrigin == VenueAuthRestoreHelper.BOOKING_ORIGIN) {
                        clearSilentFailure(accountId); venueLoginVerified?.invoke(accountId)
                    }
                    complete(result)
                }
            }
        }

        // Create visible dialog hosting the exact same WebView instance
        val d = Dialog(activity, R.style.Theme_Dansheng_SheetContent)
        d.window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        val theme = d.context
        fun px(dp: Int) = (dp * theme.resources.displayMetrics.density).toInt()
        dialog = d
        d.setCancelable(true)
        d.setOnCancelListener {
            finishWith(Result.failure(PortError("AuthenticationCancelled")))
        }
        d.setOnDismissListener { if(!finished.get())finishWith(Result.failure(PortError("AuthenticationCancelled"))) }

        val rootLayout = LinearLayout(theme).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setBackgroundColor(MaterialColors.getColor(theme, com.google.android.material.R.attr.colorSurface, Color.WHITE))
        }

        val headerBar = LinearLayout(theme).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(px(16), px(8), px(12), px(8))
        }

        val titleView = TextView(theme).apply {
            text = if (resume) "请完成校园认证后验证" else "场馆认证"
            textSize = 16f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f)
        }

        val confirmButton = MaterialButton(theme).apply {
            text = "验证登录"
            setOnClickListener {
                grantGate.runIdentityProbe(principal, accountId, targetOrigin, webView) { probeResult ->
                    if (probeResult.isSuccess && probeResult.getOrNull() == accountId) {
                        finishWith(Result.success(accountId))
                    } else if ((probeResult.exceptionOrNull() as? PortError)?.code=="AccountMismatch") {
                        finishWith(Result.failure(probeResult.exceptionOrNull() ?: PortError("IdentityVerificationUnavailable")))
                    } else {
                        titleView.text="请先完成校园认证"
                    }
                }
            }
        }

        val cancelButton = MaterialButton(theme, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = "取消"
            setOnClickListener {
                finishWith(Result.failure(PortError("AuthenticationCancelled")))
            }
        }

        headerBar.addView(titleView)
        headerBar.addView(MaterialButton(theme,null,com.google.android.material.R.attr.materialButtonOutlinedStyle).apply{
            text="校园登录"
            setOnClickListener { if(grantGate.policyFor(principal,targetOrigin)!=null) webView.loadUrl(VenueAuthRestoreHelper.loginEntry()) }
        })
        headerBar.addView(confirmButton)
        headerBar.addView(cancelButton)
        rootLayout.addView(headerBar)

        // Detach from previous parent before adding
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1.0f
        )
        rootLayout.addView(webView)

        d.setContentView(rootLayout)
        try {
            d.show()
            d.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT)
            onInteractiveShown(accountId)
            if(grantGate.trustedVenueLogin(principal) && targetOrigin==VenueAuthRestoreHelper.BOOKING_ORIGIN){
                // Only notices when the person is done. The password never reaches this page,
                // so it cannot be submitted twice however the hidden attempt ended.
                watcher=VenueAuthRestoreHelper(
                    grantGate = grantGate,
                    principal = principal,
                    accountId = accountId,
                    targetOrigin = targetOrigin,
                    targetUrl = url,
                    webView = webView,
                    credentialProvider = { null },
                    // The identity probe itself fails closed on the active account.
                    accountIsCurrent = { grantGate.trustedVenueLogin(principal) },
                    onPageLoader = ::loadPage,
                    mainHandler = mainHandler,
                    onInteractiveFallback = { titleView.text="请完成校园认证后验证" },
                    onComplete = ::finishWith,
                    autoFill = false,
                    timeoutMs = Long.MAX_VALUE
                )
                watcher.start(loadTarget = !resume)
            }else if(!resume) loadPage(webView,url)
        } catch (_: Exception) {
            finishWith(Result.failure(PortError("VisibleUiUnavailable")))
        }
    }
}
