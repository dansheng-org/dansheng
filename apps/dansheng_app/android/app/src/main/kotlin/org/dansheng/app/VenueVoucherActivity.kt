// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Activity
import android.os.Bundle
import android.net.Uri
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest

/** Official voucher in the sports WebView cookie store; no bridge or credential injection. */
class VenueVoucherActivity:Activity() {
    private var page:WebView?=null
    private lateinit var account:String
    private val runtime get()=(application as DanshengApplication).runtime
    override fun onCreate(state:Bundle?){
        super.onCreate(state)
        account=intent.getStringExtra("account_id") ?: run {finish();return}
        val id=intent.getLongExtra("appointment_id",0)
        if(id<=0 || runtime.account()!=account){finish();return}
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        page=WebView(this).apply {
            settings.javaScriptEnabled=true
            settings.domStorageEnabled=true
            settings.allowFileAccess=false
            settings.allowContentAccess=false
            webViewClient=object:WebViewClient(){
                override fun shouldOverrideUrlLoading(view:WebView,request:WebResourceRequest):Boolean {
                    if(runtime.account()!=account){finish();return true}
                    val uri=request.url
                    return uri.scheme!="https" || uri.userInfo!=null || uri.port !in setOf(-1,443) ||
                        uri.host !in setOf("booking.fudan.edu.cn","id.fudan.edu.cn","uis.fudan.edu.cn")
                }
            }
            loadUrl("https://booking.fudan.edu.cn/reservation/fe/site/m_informationCenter?voucher=1&voucher_id=$id")
        }
        setContentView(page)
    }
    override fun onResume(){super.onResume();if(::account.isInitialized && runtime.account()!=account)finish()}
    override fun onDestroy(){page?.apply{stopLoading();destroy()};page=null;super.onDestroy()}
}
