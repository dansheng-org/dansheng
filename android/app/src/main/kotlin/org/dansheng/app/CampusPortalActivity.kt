package org.dansheng.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.*
import android.widget.LinearLayout
import android.widget.TextView
import com.google.android.material.button.MaterialButton
import org.dansheng.android.KeystoreVault
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject

/** Separate WebView data directory; neither its CAS cookies nor a failed handoff touch sports. */
class CampusPortalActivity: Activity() {
    companion object {
        const val SITE="https://my.fudan.edu.cn"
        const val PAGE="$SITE/simple_list/stqk"
        // The school's own redirect picks the current identity page and issues its lock token.
        const val ENTRY=PAGE
        private const val CANVAS="https://elearning.fudan.edu.cn"
        private const val FILL_POLL_MS=500L
        private const val FILL_WINDOW_MS=8_000L
        private const val REJECTION_WINDOW_MS=15_000L
        private val identityHosts=setOf("id.fudan.edu.cn","uis.fudan.edu.cn")
        // A second-factor page means the school accepted the password.
        private const val SECOND_FACTOR_SCRIPT="/二级认证|多级认证|短信登录|OTP/.test(document.body?document.body.innerText:'')"
        // Instances sharing this process; only the last one to leave may end it.
        private val live=java.util.concurrent.atomic.AtomicInteger()
        private val allowed=setOf("my.fudan.edu.cn","uis.fudan.edu.cn","id.fudan.edu.cn","elearning.fudan.edu.cn")
        private fun host(url:String?):String?=url?.let { runCatching { Uri.parse(it) }.getOrNull() }?.takeIf{
            it.scheme=="https" && it.userInfo==null && it.port in setOf(-1,443)
        }?.host
    }
    private lateinit var page:WebView
    private lateinit var label:TextView
    private lateinit var account:String
    private var portalCookies:String?=null
    private var submitted=false
    private var accepted=false
    private var checkTimeout:Runnable?=null
    private var checking=false
    private val ui=android.os.Handler(android.os.Looper.getMainLooper())
    private var fillLoop:Runnable?=null
    private var autofill=false
    /** The identity page is a hash-routed app that renders after onPageFinished and may change
     * its hash. AUTH_SCRIPT does nothing further once it has asked for the credentials. */
    private fun pollAutofill(view:WebView){
        if(!autofill)return
        fillLoop?.let{ui.removeCallbacks(it)}
        val until=android.os.SystemClock.elapsedRealtime()+FILL_WINDOW_MS
        val loop=object:Runnable{override fun run(){
            if(isDestroyed || isFinishing || submitted || checking || host(view.url) !in identityHosts)return
            view.evaluateJavascript(VenueAuthRestoreHelper.AUTH_SCRIPT,null)
            if(android.os.SystemClock.elapsedRealtime()<until)ui.postDelayed(this,FILL_POLL_MS)
        }}
        fillLoop=loop;ui.post(loop)
    }
    /** Any end other than success after the password went out suspends it in the app, unless the
     * school visibly accepted it (second factor or the portal itself). Fails safe on an early close. */
    private fun report(){
        if(submitted)setResult(RESULT_CANCELED,Intent().putExtra("account",account).putExtra("passwordSent",true).putExtra("passwordAccepted",accepted))
    }
    private fun markAccepted(){if(submitted && !accepted){accepted=true;report()}}
    private fun watchAcceptance(){
        val until=android.os.SystemClock.elapsedRealtime()+REJECTION_WINDOW_MS
        ui.postDelayed(object:Runnable{override fun run(){
            if(isDestroyed || isFinishing || accepted || checking || host(page.url) !in identityHosts)return
            page.evaluateJavascript(SECOND_FACTOR_SCRIPT){
                if(it=="true")markAccepted()
                else if(android.os.SystemClock.elapsedRealtime()<until)ui.postDelayed(this,FILL_POLL_MS)
            }
        }},FILL_POLL_MS)
    }
    private fun cancelCheck(){
        if(!checking)return
        checkTimeout?.let(ui::removeCallbacks);checkTimeout=null
        checking=false;portalCookies=null;page.setOnTouchListener(null)
        label.text="未能核对同一账号，可在学校网页查看";page.loadUrl(PAGE)
    }
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        live.incrementAndGet()
        if(!(application as DanshengApplication).privateBrowserProfileReady){finish();return}
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        intent.getStringExtra("notice")?.let { url->
            if(host(url) !in setOf("jwc.fudan.edu.cn","gs.fudan.edu.cn")){finish();return}
            val root=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL}
            root.addView(MaterialButton(this).apply{text="关闭教务公告";setOnClickListener{finish()}})
            page=WebView(this).apply{
                settings.allowFileAccess=false;settings.allowContentAccess=false
                webViewClient=object:WebViewClient(){override fun shouldOverrideUrlLoading(v:WebView,r:WebResourceRequest)=
                    r.isForMainFrame && host(r.url.toString()) !in setOf("jwc.fudan.edu.cn","gs.fudan.edu.cn")}
            };root.addView(page,LinearLayout.LayoutParams(-1,0,1f));setContentView(root);page.loadUrl(url);return
        }
        account=intent.getStringExtra("account")?:run{finish();return}
        if(!account.matches(Regex("[A-Za-z0-9_.:@-]{1,128}"))){finish();return}
        autofill=intent.getBooleanExtra("autofill",false)
        // Recreation (rotation, dark mode) must not buy another submission from the same open.
        submitted=savedInstanceState?.getBoolean("submitted") ?: false
        accepted=savedInstanceState?.getBoolean("accepted") ?: false
        report()
        val root=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL}
        label=TextView(this).apply{text="校园双因素认证";textSize=18f;setPadding(24,16,16,8)}
        val bar=LinearLayout(this)
        fun button(t:String, action:()->Unit)=MaterialButton(this).apply{text=t;setOnClickListener{action()}}
        // Reloads only: each open submits the saved password at most once.
        bar.addView(button("重新打开"){checkTimeout?.let(ui::removeCallbacks);checkTimeout=null;checking=false;portalCookies=null;page.loadUrl(ENTRY)})
        bar.addView(button("完成验证"){beginCheck()});bar.addView(button("关闭"){finish()})
        page=WebView(this).apply {
            isSaveEnabled=false
            settings.javaScriptEnabled=true;settings.domStorageEnabled=true
            settings.allowFileAccess=false;settings.allowContentAccess=false
            settings.mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW
            webViewClient=object:WebViewClient(){
                override fun shouldOverrideUrlLoading(view:WebView,req:WebResourceRequest)=req.isForMainFrame && host(req.url.toString()) !in allowed
                override fun onPageFinished(view:WebView,url:String){
                    when(host(url)){
                        "id.fudan.edu.cn","uis.fudan.edu.cn"->if(!checking)pollAutofill(view)
                            else view.evaluateJavascript("!!document.querySelector('input[type=password]')"){if(it=="true")cancelCheck()}
                        "elearning.fudan.edu.cn"->if(checking && !Uri.parse(url).path.orEmpty().startsWith("/login")) finishCheck()
                        "my.fudan.edu.cn"->if(!checking){markAccepted();label.text="完成学校验证后，点「完成验证」"}
                    }
                }
            }
        }
        root.addView(label);root.addView(bar);root.addView(page,LinearLayout.LayoutParams(-1,0,1f));setContentView(root)
        val manager=CookieManager.getInstance()
        manager.setAcceptThirdPartyCookies(page,true)
        if(autofill && WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)){
            WebViewCompat.addWebMessageListener(page,VenueAuthRestoreHelper.BRIDGE_NAME,VenueAuthRestoreHelper.TRUSTED_AUTH_ORIGINS){v,m,source,main,reply->
                if(!main || host(v.url)!=source.host || source.scheme!="https" || submitted || checking)return@addWebMessageListener
                if(runCatching{JSONObject(m.data?:"{}").optString("type")}.getOrNull()!="REQUEST_CREDENTIALS")return@addWebMessageListener
                val value=runCatching{KeystoreVault(this).get("campus-login/v1/uis/$account")?.let{JSONObject(it).getString("secret")}}.getOrNull()
                if(value!=null){submitted=true;report();reply.postMessage(JSONObject().put("type","CREDENTIALS").put("username",account).put("password",value).toString());watchAcceptance()}
            }
        }
        // This process does not share the venue WebView's cookie jar.
        WebStorage.getInstance().deleteAllData()
        manager.removeAllCookies { manager.flush();if(!isFinishing && !isDestroyed)page.loadUrl(ENTRY) }
    }
    private fun beginCheck(){
        if(checking)return
        if(host(page.url)!="my.fudan.edu.cn"){label.text="请先在学校页面完成验证";return}
        val cookie=CookieManager.getInstance().getCookie(PAGE)
        if(cookie.isNullOrBlank() || cookie.length>16384){label.text="尚未取得校园服务会话";return}
        portalCookies=cookie;checking=true;label.text="正在核对当前校园账号"
        page.setOnTouchListener { _,_->checking }
        checkTimeout?.let(ui::removeCallbacks)
        checkTimeout=Runnable{cancelCheck()}.also{ui.postDelayed(it,22_000)}
        page.loadUrl("$CANVAS/login/cas")
    }
    private fun finishCheck(){
        val canvas=CookieManager.getInstance().getCookie("$CANVAS/api/v1/users/self/profile")
        if(canvas.isNullOrBlank() || canvas.length>16384){cancelCheck();return}
        val portal=portalCookies?:return
        checkTimeout?.let(ui::removeCallbacks);checkTimeout=null
        checking=false;portalCookies=null
        setResult(RESULT_OK,Intent().putExtra("portal",portal).putExtra("identity",canvas));finish()
    }
    override fun onSaveInstanceState(out:Bundle){
        super.onSaveInstanceState(out)
        out.putBoolean("submitted",submitted);out.putBoolean("accepted",accepted)
    }
    override fun onDestroy(){
        ui.removeCallbacksAndMessages(null)
        // This process caches the vault file, so the next open must start fresh to see a password
        // the app has since deleted or replaced. The system already holds any activity result.
        val leaving=isFinishing
        val last=live.decrementAndGet()==0
        fun end(){if(leaving && last && live.get()==0)android.os.Process.killProcess(android.os.Process.myPid())}
        val cleaning=::page.isInitialized
        if(cleaning){(page.parent as? ViewGroup)?.removeView(page);page.stopLoading();page.destroy()
            WebStorage.getInstance().deleteAllData()
            CookieManager.getInstance().removeAllCookies{CookieManager.getInstance().flush();end()}}
        super.onDestroy()
        if(!cleaning)end()
    }
}
