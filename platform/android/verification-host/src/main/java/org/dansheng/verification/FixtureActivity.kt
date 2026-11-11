// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.app.Activity
import android.os.Bundle
import android.webkit.WebView
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.dansheng.android.*
import org.json.JSONObject

/** Synthetic verification UI only. Has no campus URLs, stored credentials or live connectors. */
class FixtureActivity : Activity() {
    lateinit var browser: WebViewBrowserPort
    lateinit var container: LinearLayout
    lateinit var status: TextView
    var fixtureView: WebView? = null
    var verifyLogin: (() -> Unit)? = null
    var hostSession: String? = null
    var allowFixtureWrites = true
    var fixtureSharedReader: String? = null
    var fixtureSharedOrigin: String? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        container = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        status = TextView(this).apply { text = "Offline synthetic fixture; no campus traffic" }
        container.addView(status); setContentView(container)
        browser = WebViewBrowserPort(this, object : VisibleLoginPort {
            override fun show(accountId: String, url: String, webView: WebView, complete: (Result<String>) -> Unit) {
                fixtureView = webView
                container.addView(webView, LinearLayout.LayoutParams(-1, 450))
                // loadDataWithBaseURL never connects to this reserved synthetic origin.
                // Fixtures install page wrappers; native browser calls must observe them.
                val html = assets.open("fixture.html").bufferedReader().use { it.readText() }
                webView.settings.blockNetworkLoads = true
                val fixtureBase = origin(url) + "/"
                webView.loadDataWithBaseURL(fixtureBase, html, "text/html", "UTF-8", fixtureBase)
                verifyLogin = {
                    webView.evaluateJavascript("window.fixtureIdentity === 'fixture-a'") { result ->
                        complete(if (result == "true" && accountId == "fixture-a") Result.success("fixture-a")
                            else Result.failure(PortError("AuthenticationRequired")))
                    }
                }
            }
        }, MutationAuthorizer { _, account, _ -> allowFixtureWrites && account == "fixture-a" },
            mayShareSession = { issuer, reader, account, url ->
                // Explicit fixture policy; the adapter first checks current grants.
                issuer == "owner" && account == "fixture-a" && (
                    (reader == "plugin:fixture" && url?.startsWith("https://fixture.invalid/") == true) ||
                    (reader == fixtureSharedReader && fixtureSharedOrigin != null &&
                        url != null && origin(url) == fixtureSharedOrigin)
                )
            })
        container.addView(Button(this).apply {
            text = "Open visible fixture login"
            setOnClickListener {
                browser.call("browser.evaluate", authority(), JSONObject().put("account_id", "fixture-a")
                    .put("operation", "session.requireLogin").put("url", "https://fixture.invalid/")) { r ->
                    r.fold({ hostSession = it.getString("session_handle"); status.text = "Synthetic session ready" },
                        { status.text = (it as? PortError)?.code ?: "Fixture failed" })
                }
            }
        })
        container.addView(Button(this).apply { text = "Confirm visible fixture identity"; setOnClickListener { verifyLogin?.invoke() } })
        container.addView(Button(this).apply { text = "Native ABI smoke (optional Rust library)"; setOnClickListener { nativeSmoke() } })
    }
    fun authority() = Authority("owner", true, emptySet(), emptySet(), emptySet())
    fun nativeSmoke() {
        Thread {
            try {
                NativeCore.load()
                fun await(op: Long): JSONObject {
                    val end = System.currentTimeMillis() + 15000
                    while (System.currentTimeMillis() < end) {
                        NativeCore.poll(op)?.let { return JSONObject(it.toString(Charsets.UTF_8)) }
                        Thread.sleep(10)
                    }
                    throw PortError("DeadlineExceeded")
                }
                val open = await(NativeCore.open(JSONObject().put("data_dir", filesDir.resolve("core").absolutePath)
                    .put("platform_capabilities", org.json.JSONArray()).toString().toByteArray()))
                val engine = open.getJSONObject("result").getLong("engine")
                try {
                    val info = await(NativeCore.request(engine, "{\"id\":\"smoke\",\"method\":\"core.info\",\"params\":{}}".toByteArray()))
                    check(info.getJSONObject("result").getString("name") == "dansheng-core")
                } finally { await(NativeCore.close(engine)) }
                runOnUiThread { status.text = "Native ABI open/request/poll/free/close passed" }
            } catch (_: Throwable) { runOnUiThread { status.text = "Native ABI unavailable or failed; build with rustJniDir" } }
        }.start()
    }
    override fun onDestroy() { browser.logout("fixture-a") {}; super.onDestroy() }
}
