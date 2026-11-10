// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.net.Uri
import android.os.Handler
import android.webkit.WebView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.dansheng.android.PortError
import org.dansheng.android.origin
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

open class VenueAuthRestoreHelper(
    private val grantGate: GrantGate,
    private val principal: String,
    private val accountId: String,
    private val targetOrigin: String,
    private val targetUrl: String,
    private val webView: WebView,
    private val credentialProvider: (String) -> String?,
    private val accountIsCurrent: (String) -> Boolean,
    private val onPageLoader: (WebView, String) -> Unit,
    private val mainHandler: Handler? = null,
    private val onInteractiveFallback: (() -> Unit)?,
    private val onComplete: (Result<String>) -> Unit,
    private val autoFill: Boolean = true,
    private val timeoutMs: Long = TIMEOUT_MS
) {
    companion object {
        const val BOOKING_ORIGIN = "https://booking.fudan.edu.cn"
        // The booking site's own getToLoginPath points here. A visitor may
        // render the topic page indefinitely without ever being sent to CAS.
        const val TOPIC = "$BOOKING_ORIGIN/reservation/fe/site/special/special?id=48"
        fun loginEntry():String=android.net.Uri.parse("$BOOKING_ORIGIN/reservation/api/login/main")
            .buildUpon().appendQueryParameter("redirect_url",TOPIC).build().toString()
        const val ID_ORIGIN = "https://id.fudan.edu.cn"
        const val UIS_ORIGIN = "https://uis.fudan.edu.cn"
        val TRUSTED_AUTH_ORIGINS = setOf(ID_ORIGIN, UIS_ORIGIN)
        const val BRIDGE_NAME = "__dsVenueAuthBridge"
        const val TIMEOUT_MS = 45_000L
        const val POLL_INTERVAL_MS = 100L
        // A slow mobile network must not open the visible page needlessly.
        const val SUBMIT_GRACE_MS = 10_000L
        // A person may stay on the page for minutes; do not query the school 6 times a second.
        private const val WATCH_PROBE_INTERVAL_MS = 1_500L

        val AUTH_SCRIPT = """
            (function() {
                try {
                    const origin = window.location.origin;
                    if (origin !== "https://id.fudan.edu.cn" && origin !== "https://uis.fudan.edu.cn") return;
                    if (window.__ds_login_injected) return;
                    if (window.__ds_login_submitted) return;

                    const check2fa = function() {
                        const otp = document.querySelector('input[name*="code" i], input[placeholder*="动态码"], input[placeholder*="验证码"], #dynamicCode, #smsCode, #cHat2FaCode');
                        if (otp && otp.offsetParent !== null) return true;
                        const err = document.querySelector('.error-msg, .err-msg, .el-message--error');
                        if (err && err.offsetParent !== null && (err.innerText || '').length > 0) return true;
                        return false;
                    };

                    if (check2fa()) {
                        if (window.__dsVenueAuthBridge && window.__dsVenueAuthBridge.postMessage) {
                            window.__dsVenueAuthBridge.postMessage(JSON.stringify({ type: "2FA_REQUIRED" }));
                        }
                        return;
                    }

                    const idButton = () => document.querySelector('.el-button.content_submit') ||
                        [...document.querySelectorAll('button')].find(b => (b.innerText||'').trim()==='登录');
                    const checkFormTarget = function(form, idSpa=false) {
                        if (!form) return true;
                        const rawAction = form.getAttribute('action') || form.action || window.location.href;
                        const targetUrl = new URL(rawAction, window.location.href);
                        if (targetUrl.origin !== window.location.origin) return false;
                        if (Array.from(form.querySelectorAll('[formaction],[formmethod]')).some(el =>
                            (el.hasAttribute('formaction') && new URL(el.formAction,location.href).origin !== origin) ||
                            (el.hasAttribute('formmethod') && el.formMethod.toUpperCase() !== 'POST'))) return false;
                        const method = (form.getAttribute('method') || form.method || 'POST').toUpperCase();
                        // The identity SPA's form has the HTML default GET, but its
                        // login button uses a JavaScript request. Never submit that form as GET.
                        return method === 'POST' || (idSpa && origin==='https://id.fudan.edu.cn' &&
                            method==='GET' && !!idButton() && !form.getAttribute('action'));
                    };

                    const findInputs = function() {
                        if (origin === "https://id.fudan.edu.cn") {
                            const u = document.getElementById('login-username') ||
                                document.querySelector('input[placeholder*="用户名"]') ||
                                document.querySelector('input[placeholder*="学工号"]') ||
                                document.querySelector('input[name="username"]');
                            const p = document.getElementById('login-password') ||
                                document.querySelector('input[type="password"]');
                            if (u && p && u.offsetParent !== null && p.offsetParent !== null) {
                                const f = u.form;
                                if (p.form!==f || !idButton() || (f && !checkFormTarget(f,true))) return null;
                                return { u: u, p: p, form: f, kind: 'id' };
                            }
                        } else if (origin === "https://uis.fudan.edu.cn") {
                            const u = document.getElementById('username') ||
                                document.getElementById('mobileUsername');
                            const p = document.getElementById('password') ||
                                document.getElementById('mobilePassword');
                            if (u && p && u.offsetParent !== null && p.offsetParent !== null) {
                                const f = u.closest('form') || document.forms[0];
                                if (f && !checkFormTarget(f)) return null;
                                return { u: u, p: p, form: f, kind: 'uis' };
                            }
                        }
                        return null;
                    };

                    const setValue = function(element, val) {
                        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
                        if (setter) {
                            setter.call(element, val);
                        } else {
                            element.value = val;
                        }
                        element.dispatchEvent(new Event('input', { bubbles: true }));
                        element.dispatchEvent(new Event('change', { bubbles: true }));
                    };

                    const doSubmit = function(creds) {
                        if (window.__ds_login_submitted) return;
                        window.__ds_login_submitted = true;

                        const inputs = findInputs();
                        if (!inputs) return;

                        if(inputs.kind==='id' && inputs.form){
                            // Block the browser's native submission path before placing
                            // credentials in the fields; the school's JS click handler still runs.
                            inputs.form.method='post';
                            inputs.form.addEventListener('submit',e=>e.preventDefault(),true);
                        }
                        setValue(inputs.u, creds.username);
                        setValue(inputs.p, creds.password);

                        creds.password = null;

                        if (inputs.kind === 'id') {
                            setTimeout(function() {
                                const submitBtn = idButton();
                                if (submitBtn && origin===location.origin && (!inputs.form || checkFormTarget(inputs.form))) submitBtn.click();
                                if (window.__dsVenueAuthBridge && window.__dsVenueAuthBridge.postMessage) {
                                    window.__dsVenueAuthBridge.postMessage(JSON.stringify({ type: "SUBMIT_DONE" }));
                                }
                            }, 150);
                        } else if (inputs.kind === 'uis') {
                            const form = inputs.form || document.forms[0];
                            if (form) form.submit();
                            if (window.__dsVenueAuthBridge && window.__dsVenueAuthBridge.postMessage) {
                                window.__dsVenueAuthBridge.postMessage(JSON.stringify({ type: "SUBMIT_DONE" }));
                            }
                        }
                    };

                    if (window.__dsVenueAuthBridge && window.__dsVenueAuthBridge.postMessage) {
                        window.__dsVenueAuthBridge.onmessage = function(event) {
                            try {
                                const data = JSON.parse(event.data);
                                if (data.type === 'CREDENTIALS' && data.username && data.password) {
                                    doSubmit(data);
                                }
                            } catch (_) {}
                        };
                        const inputs = findInputs();
                        if (inputs) {
                            window.__ds_login_injected = true;
                            window.__dsVenueAuthBridge.postMessage(JSON.stringify({ type: "REQUEST_CREDENTIALS" }));
                        }
                    }
                } catch (_) {}
            })();
        """.trimIndent()
    }

    private val finished = AtomicBoolean(false)
    private val hasInjected = AtomicBoolean(false)
    private val delivered = AtomicBoolean(false)
    // Set when the password reaches the page, because a navigating page may never confirm the submit.
    val credentialsDelivered get() = delivered.get()
    private val hasSubmitted = AtomicBoolean(false)
    private val probing = AtomicBoolean(false)
    private val requestedSso = AtomicBoolean(false)
    private var webMessageListenerAdded = false
    private var startTime = 0L
    private var submitTime = 0L
    private var lastWatchProbe = 0L
    private var sawPage = false

    protected open fun post(action: Runnable) {
        if (mainHandler != null) {
            mainHandler.post(action)
        } else {
            action.run()
        }
    }

    protected open fun postDelayed(action: Runnable, delayMillis: Long) {
        if (mainHandler != null) {
            mainHandler.postDelayed(action, delayMillis)
        } else {
            action.run()
        }
    }

    protected open fun removeCallbacks(action: Runnable) {
        mainHandler?.removeCallbacks(action)
    }

    fun start(loadTarget: Boolean = true) {
        startTime = System.currentTimeMillis()
        if (autoFill) setupWebMessageListener()
        if (loadTarget) onPageLoader(webView, targetUrl)
        if (autoFill && !webMessageListenerAdded) { triggerFallbackOrFailure(PortError("AuthenticationRequired")); return }
        post(pollRunnable)
    }
    fun stop() { if(finished.compareAndSet(false,true))cleanup() }

    private fun setupWebMessageListener() {
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                val listener = object : WebViewCompat.WebMessageListener {
                    override fun onPostMessage(
                        view: WebView,
                        message: WebMessageCompat,
                        sourceOrigin: Uri,
                        isMainFrame: Boolean,
                        replyProxy: JavaScriptReplyProxy
                    ) {
                        handleBridgeMessage(view, message, sourceOrigin, isMainFrame, replyProxy)
                    }
                }
                WebViewCompat.addWebMessageListener(
                    webView,
                    BRIDGE_NAME,
                    TRUSTED_AUTH_ORIGINS,
                    listener
                )
                webMessageListenerAdded = true
            }
        } catch (_: Throwable) {
            webMessageListenerAdded = false
        }
    }

    private fun handleBridgeMessage(
        view: WebView,
        message: WebMessageCompat,
        sourceOrigin: Uri,
        isMainFrame: Boolean,
        replyProxy: JavaScriptReplyProxy
    ) {
        post {
            if (finished.get()) return@post
            if (!isMainFrame) return@post
            val originStr = try { origin(sourceOrigin.toString()) } catch (_: Exception) { return@post }
            if (originStr !in TRUSTED_AUTH_ORIGINS) return@post
            val currentOrigin = try { view.url?.substringBefore('#')?.let(::origin) } catch (_: Exception) { null }
            if (currentOrigin != originStr) return@post

            if (!accountIsCurrent(accountId)) {
                finishWith(Result.failure(PortError("AccountMismatch")))
                return@post
            }

            val msgType = try {
                JSONObject(message.data ?: "{}").optString("type")
            } catch (_: Exception) { "" }

            when (msgType) {
                "REQUEST_CREDENTIALS" -> {
                    if (hasInjected.compareAndSet(false, true)) {
                        val secret = runCatching { credentialProvider(accountId) }.getOrNull()
                        if (secret.isNullOrEmpty()) {
                            triggerFallbackOrFailure(PortError("AuthenticationRequired"))
                            return@post
                        }
                        val payload = JSONObject()
                            .put("type", "CREDENTIALS")
                            .put("username", accountId)
                            .put("password", secret)
                            .toString()
                        delivered.set(true)
                        replyProxy.postMessage(payload)
                    }
                }
                "SUBMIT_DONE" -> {
                    hasSubmitted.set(true)
                    submitTime = System.currentTimeMillis()
                }
                "2FA_REQUIRED" -> {
                    triggerFallbackOrFailure(PortError("AuthenticationRequired"))
                }
            }
        }
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (finished.get()) return
            checkState()
            if (!finished.get()) {
                postDelayed(this, POLL_INTERVAL_MS)
            }
        }
    }

    private fun checkState() {
        if (finished.get()) return

        if (!accountIsCurrent(accountId)) {
            finishWith(Result.failure(PortError("AccountMismatch")))
            return
        }

        if (webView.url == null && sawPage) {
            // The port destroyed this page and has already answered, so open nothing.
            finishWith(Result.failure(PortError("AuthenticationRequired")))
            return
        }
        val elapsed = System.currentTimeMillis() - startTime
        if (elapsed > timeoutMs) {
            triggerFallbackOrFailure(PortError("DeadlineExceeded"))
            return
        }

        val currentUrl = webView.url ?: return
        sawPage = true
        val currentOrigin = try { origin(currentUrl.substringBefore('#')) } catch (_: Exception) { return }

        when (currentOrigin) {
            BOOKING_ORIGIN -> {
                if (!autoFill && System.currentTimeMillis() - lastWatchProbe < WATCH_PROBE_INTERVAL_MS) return
                if (probing.compareAndSet(false, true)) {
                    lastWatchProbe = System.currentTimeMillis()
                    grantGate.runIdentityProbe(principal, accountId, targetOrigin, webView) { probeResult ->
                        post {
                            probing.set(false)
                            if (finished.get()) return@post
                            if (probeResult.isSuccess && probeResult.getOrNull() == accountId) {
                                finishWith(Result.success(accountId))
                            } else if ((probeResult.exceptionOrNull() as? PortError)?.code=="AccountMismatch") {
                                finishWith(Result.failure(PortError("AccountMismatch")))
                            } else {
                                if ((probeResult.exceptionOrNull() as? PortError)?.code=="AuthenticationRequired" &&
                                    webView.progress>=80 && System.currentTimeMillis()-startTime>1800 &&
                                    requestedSso.compareAndSet(false,true)) {
                                    onPageLoader(webView, loginEntry())
                                    return@post
                                }
                                if (hasSubmitted.get()) {
                                    val timeSinceSubmit = System.currentTimeMillis() - submitTime
                                    if (timeSinceSubmit > SUBMIT_GRACE_MS) {
                                        triggerFallbackOrFailure(PortError("AuthenticationRequired"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ID_ORIGIN, UIS_ORIGIN -> {
                // The page belongs to the user here: no script and no post-submit deadline.
                if (!autoFill) return
                if (hasSubmitted.get()) {
                    val timeSinceSubmit = System.currentTimeMillis() - submitTime
                    if (timeSinceSubmit > SUBMIT_GRACE_MS) {
                        triggerFallbackOrFailure(PortError("AuthenticationRequired"))
                        return
                    }
                }
                webView.evaluateJavascript(AUTH_SCRIPT, null)
            }
            else -> {
                if (currentOrigin !in TRUSTED_AUTH_ORIGINS && currentOrigin != BOOKING_ORIGIN) {
                    triggerFallbackOrFailure(PortError("UntrustedOrigin"))
                }
            }
        }
    }

    private fun triggerFallbackOrFailure(error: PortError) {
        if (onInteractiveFallback != null) {
            if (!finished.compareAndSet(false,true))return
            cleanup()
            onInteractiveFallback.invoke()
        } else {
            finishWith(Result.failure(error))
        }
    }

    private fun finishWith(result: Result<String>) {
        if (finished.compareAndSet(false, true)) {
            post {
                cleanup()
                onComplete(result)
            }
        }
    }

    private fun cleanup() {
        removeCallbacks(pollRunnable)
        if (webMessageListenerAdded) {
            try {
                WebViewCompat.removeWebMessageListener(webView, BRIDGE_NAME)
            } catch (_: Throwable) {}
            webMessageListenerAdded = false
        }
        if (!autoFill) return
        try {
            webView.evaluateJavascript(
                "(function(){ try { delete window.__ds_login_injected; delete window.__ds_login_submitted; } catch(_) {} })()",
                null
            )
        } catch (_: Throwable) {}
    }
}
