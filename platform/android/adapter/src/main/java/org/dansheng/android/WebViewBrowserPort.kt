// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest
import org.json.JSONObject
import org.json.JSONTokener
import java.util.UUID

typealias PortReply = (Result<JSONObject>) -> Unit

/** Trusted UI supplies a visible WebView and proves its account with its own verifier.
 * Completion MUST follow a visible user handoff AND an authenticated read-only identity probe.
 * Returning the requested account without verifying the logged-in identity is prohibited.
 */
interface VisibleLoginPort {
    fun show(accountId: String, url: String, webView: WebView, complete: (Result<String>) -> Unit)
    fun showAuthorized(principal: String, accountId: String, url: String, webView: WebView, complete: (Result<String>) -> Unit) =
        show(accountId, url, webView, complete)
}

/** Extra host approval is never taken from JSON supplied by a plugin. */
fun interface MutationAuthorizer {
    fun allowed(principal: String, account: String, request: JSONObject): Boolean
}

class WebViewBrowserPort(private val context: Context, private val login: VisibleLoginPort,
    private val mutations: MutationAuthorizer,
    private val mayShareSession:(String,String,String,String?)->Boolean = { _,_,_,_->false }) {
    private val main = Handler(Looper.getMainLooper())
    private val sessions = SessionLedger()
    private var page: WebView? = null
    private var authenticating = false
    private var profileOwner: String? = null
    private var profilePrincipal: String? = null
    private var cancelLogin: (() -> Unit)? = null
    private var document = 0L
    private val boxKey = "__dansheng_" + UUID.randomUUID().toString().replace("-", "")
    private val pending = mutableMapOf<String, () -> Unit>()
    private val script by lazy { context.assets.open("dansheng-page-transport.js").bufferedReader().use { it.readText() } }

    /** This metadata comes ONLY from C ABI platform_poll, never from caller params. */
    fun call(capability: String, authority: Authority, input: JSONObject, reply: PortReply) =
        dispatch(capability, authority, input, false, reply)
    /** Only the host UI can open a longer interactive handoff; plugin input cannot select this path. */
    fun loginFromUser(authority: Authority, account:String, url:String, reply:PortReply) =
        dispatch("browser.login",authority,JSONObject().put("account_id",account).put("url",url),true,reply)
    private fun dispatch(capability: String, authority: Authority, input: JSONObject, foreground:Boolean, reply: PortReply) {
        main.post {
            try {
                val account = input.getString("account_id")
                val url = input.optString("url").takeIf { it.isNotEmpty() }
                authority.check(capability, account, url, System.currentTimeMillis())
                if (profilePrincipal != null && profilePrincipal != authority.principalId &&
                    !mayShareSession(profilePrincipal!!,authority.principalId,account,page?.url))
                    throw PortError("SessionOwnershipMismatch")
                when (capability) {
                    "browser.request" -> request(authority, account, input, reply)
                    "browser.open", "browser.login" -> {
                        authority.check("browser.login", account, url, System.currentTimeMillis())
                        requireLogin(authority, account, input.getString("url"), reply, foreground)
                    }
                    "browser.navigate" -> {
                        val s = sessions.require(account, input.getString("session_handle"))
                        if (origin(input.getString("url")) != s.origin) throw PortError("OriginMismatch")
                        val v = page ?: throw PortError("AuthenticationRequired")
                        v.loadUrl(input.getString("url"))
                        reply(Result.success(JSONObject().put("navigating", true)))
                    }
                    "browser.close" -> {
                        sessions.require(account, input.getString("session_handle"))
                        logout(account) { reply(Result.success(JSONObject().put("closed", true))) }
                    }
                    "browser.evaluate" -> when (input.getString("operation")) {
                        "session.status" -> {
                            val state=status(account)
                            if(input.optBoolean("require_authenticated") && !state.getBoolean("authenticated")) throw PortError("AuthenticationRequired")
                            reply(Result.success(state))
                        }
                        "session.requireLogin" -> {
                            authority.check("browser.login", account, url, System.currentTimeMillis())
                            requireLogin(authority, account, input.getString("url"), reply)
                        }
                        // No arbitrary JS, DOM/cookie access, credential injection or native HTTP fallback.
                        else -> throw PortError("CapabilityUnavailable")
                    }
                    else -> throw PortError("CapabilityUnavailable")
                }
            } catch (e: Exception) { reply(Result.failure(if (e is PortError) e else PortError("InvalidInput"))) }
        }
    }

    private fun status(account: String): JSONObject = JSONObject().apply {
        val s = sessions.status(account)
        put("account_id", account); put("authenticated", s != null)
        if (s != null) put("session_handle", s.handle)
    }

    private fun requireLogin(authority: Authority, account: String, url: String, reply: PortReply, foreground:Boolean=false) {
        sessions.status(account)?.let {
            if(it.origin!=origin(url))throw PortError("OriginMismatch")
            if(!foreground){reply(Result.success(status(account)));return}
            if(pending.isNotEmpty() || authenticating)throw PortError("AccountBusy")
            // An expired session must be able to re-enter SSO without erasing viable campus cookies.
            sessions.beginReset()
            page?.apply {stopLoading();(parent as? android.view.ViewGroup)?.removeView(this);destroy()}
            page=null;sessions.finishReset()
        }
        if (authenticating || page != null || sessions.resetting) throw PortError("AccountBusy")
        origin(url)
        authenticating = true
        profileOwner = account
        profilePrincipal = authority.principalId
        val view = WebView(context)
        page = view
        view.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true
            allowFileAccess = false; allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean =
                try { authority.check("browser.login", account, request.url.toString().substringBefore('#'), System.currentTimeMillis()); false } catch (_: PortError) { true }
            override fun onPageStarted(v: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                document++
                pending.values.toList().forEach { it() }
            }
            override fun onRenderProcessGone(v: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                logout(account) {}; return true
            }
        }
        val handoffId = document
        cancelLogin = { reply(Result.failure(PortError("AuthenticationRequired"))) }
        val timeout = Runnable {
            if (authenticating && page === view) {
                logout(account) {}
            }
        }
        main.postDelayed(timeout, if(foreground) 300_000L else 50_000L)
        try { login.showAuthorized(authority.principalId, account, url, view) { result -> main.post {
            if (!authenticating || page !== view) return@post
            main.removeCallbacks(timeout)
            authenticating = false
            val verified = result.getOrNull()
            if (verified != account || originSafe(view.url) != origin(url) || document < handoffId) {
                logout(account) {}
            } else {
                try { authority.check("browser.login", account, url, System.currentTimeMillis()) }
                catch (_: PortError) { logout(account) {}; return@post }
                cancelLogin = null
                sessions.issue(account, url)
                reply(Result.success(status(account)))
            }
        } } } catch (_: Exception) { logout(account) {} }
    }

    /** Host-only logout. Revoke first; clear the shared profile BEFORE permitting another account. */
    fun releasePrincipal(principal:String) { main.post {
        val account=profileOwner
        if(account!=null && profilePrincipal==principal) logout(account) {}
    } }
    fun logout(account: String, done: () -> Unit) {
        main.post {
            // Failed handoffs have no issued session yet; still clear their profile.
            if (profileOwner != account) { done(); return@post }
            sessions.beginReset(); authenticating = false; document++
            val cancel = cancelLogin; cancelLogin = null
            pending.values.toList().forEach { it() }
            page?.apply { stopLoading(); (parent as? android.view.ViewGroup)?.removeView(this); destroy() }
            page = null
            WebStorage.getInstance().deleteAllData()
            CookieManager.getInstance().removeAllCookies {
                CookieManager.getInstance().flush(); profileOwner = null; profilePrincipal = null; sessions.finishReset()
                // Report a rejected login only once the same account can safely start another handoff.
                cancel?.invoke(); done()
            }
        }
    }

    private fun originSafe(url: String?): String? = try { url?.substringBefore('#')?.let(::origin) } catch (_: PortError) { null }

    private fun request(authority: Authority, account: String, p: JSONObject, reply: PortReply) {
        val session = sessions.require(account, p.getString("session_handle"))
        val view = page ?: throw PortError("AuthenticationRequired")
        val url = p.getString("url")
        if (origin(url) != session.origin || originSafe(view.url) != session.origin) throw PortError("OriginMismatch")
        val method = p.optString("method", "GET").uppercase()
        if (method !in setOf("GET", "POST")) throw PortError("InvalidInput")
        val mutating = method != "GET"
        if (mutating) authority.check("browser.write", account, url, System.currentTimeMillis())
        val transport = p.optString("transport", "fetch")
        if (transport !in setOf("fetch", "xhr")) throw PortError("InvalidInput")
        if ((!mutating && (p.has("body") || p.has("form_fields"))) ||
            (p.has("form_fields") && (transport != "xhr" || p.has("body")))) throw PortError("InvalidInput")
        if (pending.isNotEmpty()) throw PortError("BrowserBusy")
        val deadline = Deadline(minOf(p.getLong("deadline_epoch_ms"), System.currentTimeMillis() + 55_000),
            System.currentTimeMillis(), SystemClock.elapsedRealtime())
        val remaining = deadline.remaining(System.currentTimeMillis(), SystemClock.elapsedRealtime())
        if (remaining <= 0) throw PortError("DeadlineExceeded")
        val headers = p.optJSONObject("headers") ?: JSONObject()
        for (key in headers.keys()) {
            if (key.lowercase() !in setOf("accept", "content-type", "sign-key")) throw PortError("ForbiddenHeader")
            if (headers.getString(key).any { it == '\r' || it == '\n' }) throw PortError("InvalidInput")
        }
        val args = JSONObject(p.toString()).apply {
            put("method", method); put("headers", headers); put("mutating", mutating)
            put("transport", transport); put("timeout_ms", minOf(remaining, 8000))
            put("max_body_chars", 1024 * 1024)
        }
        if (args.toString().length > 128 * 1024) throw PortError("RequestTooLarge")
        // Claim only after local validation; a successful claim is deliberately durable
        // even if dispatch subsequently fails (uncertainty must be reconciled).
        if (mutating && !mutations.allowed(authority.principalId, account, p)) throw PortError("ApprovalRequired")
        val id = UUID.randomUUID().toString()
        val generation = document
        var finished = false
        fun finish(value: Result<JSONObject>) {
            if (finished) return
            finished = true; pending.remove(id)
            view.evaluateJavascript("(function(){const b=window[${JSONObject.quote(boxKey)}]; if(b&&b[${JSONObject.quote(id)}]){const s=b[${JSONObject.quote(id)}];delete b[${JSONObject.quote(id)}];if(s.abort)s.abort();}})()", null)
            reply(value)
        }
        fun fail() = finish(Result.failure(PortError(if (mutating) "NeedsReconciliation" else "BrowserRequestFailed")))
        pending[id] = { fail() }
        view.evaluateJavascript("($script)(${JSONObject.quote(boxKey)},${JSONObject.quote(id)},$args)", null)
        val poll = object : Runnable {
            override fun run() {
                if (finished) return
                if (document != generation || sessions.status(account)?.handle != session.handle ||
                    deadline.remaining(System.currentTimeMillis(), SystemClock.elapsedRealtime()) <= 0) { fail(); return }
                view.evaluateJavascript("(function(){const b=window[${JSONObject.quote(boxKey)}];const s=b&&b[${JSONObject.quote(id)}];return s&&s.done?JSON.stringify(s.value):null;})()") { raw ->
                    if (finished) return@evaluateJavascript
                    // Recheck after async callback: navigation/account changes cannot race acceptance.
                    if (document != generation || sessions.status(account)?.handle != session.handle ||
                        deadline.remaining(System.currentTimeMillis(), SystemClock.elapsedRealtime()) <= 0) { fail(); return@evaluateJavascript }
                    try {
                        authority.check("browser.request", account, url, System.currentTimeMillis())
                        if (mutating) authority.check("browser.write", account, url, System.currentTimeMillis())
                    }
                    catch (_: PortError) { fail(); return@evaluateJavascript }
                    try {
                        val text = JSONTokener(raw ?: "null").nextValue()
                        if (text is String) {
                            val result = JSONObject(text)
                            if (result.has("error")) { fail(); return@evaluateJavascript }
                            if (result.optInt("status", 0) <= 0) { fail(); return@evaluateJavascript }
                            if (originSafe(result.optString("url")) != session.origin) { fail(); return@evaluateJavascript }
                            // The final URL can carry WAF/SSO tokens. Expose only origin/path.
                            val finalUri = java.net.URI(result.getString("url"))
                            result.put("url", session.origin + (finalUri.rawPath ?: "/"))
                            finish(Result.success(result)); return@evaluateJavascript
                        }
                    } catch (_: Exception) { fail(); return@evaluateJavascript }
                    main.postDelayed(this, 25)
                }
            }
        }
        main.post(poll)
        // Covers a WebView whose evaluateJavascript callback never returns.
        main.postDelayed({ if (!finished) fail() }, remaining)
    }
}
