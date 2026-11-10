// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Application
import android.os.Build
import android.webkit.WebView

open class DanshengApplication : Application() {
    protected var browserIsolated = false
        private set
    internal val privateBrowserProfileReady get()=browserIsolated
    protected open fun createRuntime() = RuntimeHost(this,browserIsolated)
    val runtime: RuntimeHost by lazy { createRuntime() }

    override fun onCreate() {
        super.onCreate()
        browserIsolated=initWebViewSuffix()
        if(Application.getProcessName().endsWith(":campus_verify"))return
        // Cold start initialization: immediately installs AndroidRuntime.execution
        // and notification channels before any foreground service or broadcast delivery.
        runtime.initializeOnCreate()
    }

    private fun initWebViewSuffix():Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val processName = Application.getProcessName()
                val suffix = if (processName == packageName) {
                    "dansheng_browser"
                } else {
                    val tag = processName.substringAfter(':').replace(Regex("[^a-zA-Z0-9_]"), "_")
                    "dansheng_$tag"
                }
                WebView.setDataDirectorySuffix(suffix)
                return true
            } catch (_: IllegalStateException) {
                // An earlier WebView may be using the default shared profile.
                return false
            }
        }
        return false
    }
}
