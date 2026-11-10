// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app.checks

import android.webkit.WebView
import org.dansheng.app.DanshengApplication
import org.dansheng.app.RuntimeHost
import org.dansheng.app.VisiblePage
import org.json.JSONObject

class OfflineApplication : DanshengApplication() {
    override fun createRuntime() = RuntimeHost(this,browserIsolated) { gate ->
        object : VisiblePage(gate) {
            override fun showAuthorized(principal:String,accountId:String,url:String,webView:WebView,complete:(Result<String>)->Unit) {
                super.showAuthorized(principal,accountId,url,webView) {
                    lastProbeCode=(it.exceptionOrNull() as? org.dansheng.android.PortError)?.code ?: if(it.isSuccess)"verified" else "probe_failed"
                    complete(it)
                }
            }
            override fun onInteractiveShown(accountId: String) {
                interactiveShown.incrementAndGet()
            }
            override fun loadPage(view: WebView, url: String) {
                view.settings.blockNetworkLoads = true
                lastLoadedWebView = view
                pageLoads.incrementAndGet()
                loadedViews.add(System.identityHashCode(view))
                val login = syntheticLoginHtml
                if (login != null) view.loadDataWithBaseURL(SYNTHETIC_LOGIN_URL, login, "text/html", "UTF-8", SYNTHETIC_LOGIN_URL)
                else view.loadDataWithBaseURL(url, syntheticPageHtml, "text/html", "UTF-8", url)
            }
        }
    }

    companion object {
        const val SYNTHETIC_LOGIN_URL = "https://id.fudan.edu.cn/authserver/login"
        val interactiveShown = java.util.concurrent.atomic.AtomicInteger()
        val pageLoads = java.util.concurrent.atomic.AtomicInteger()
        val loadedViews = java.util.concurrent.CopyOnWriteArrayList<Int>()
        // When set, a load lands on this page instead, as a CAS redirect would.
        @Volatile var syntheticLoginHtml: String? = null
        @Volatile var lastProbeCode:String="not_started"
        @Volatile
        var lastLoadedWebView: WebView? = null

        @Volatile
        var syntheticPageHtml: String = defaultSyntheticHtml("fixture-sports-account")

        fun setSyntheticIdentity(identity: String) {
            syntheticPageHtml = defaultSyntheticHtml(identity)
            lastLoadedWebView?.let { wv ->
                wv.post {
                    wv.evaluateJavascript("window.fixtureIdentity = ${JSONObject.quote(identity)};", null)
                }
            }
        }

        fun defaultSyntheticHtml(identity: String = "fixture-sports-account"): String {
            val quotedIdentity = JSONObject.quote(identity)
            return """
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Synthetic Sports Fixture</title></head>
<body>
<h2>Synthetic Sports Page</h2>
<script>
window.fixtureIdentity = $quotedIdentity;
window.fixtureCalls = [];
window.fixtureNextWriteError = false;
window.fixtureNextWriteTimeout = false;
window.fixtureReply = null;
window.fixtureAppointments = null;

window.fetch = function(url, options) {
  options = options || {};
  const method = (options.method || 'GET').toUpperCase();
  const urlStr = String(url);
  window.fixtureCalls.push({transport: 'fetch', url: urlStr + '?synthetic-waf=dynamic', method: method});

  if (urlStr.includes('/reservation/site/user/detail')) {
    return Promise.resolve({
      status: 200,
      url: urlStr,
      text: async () => JSON.stringify({
        e: 'OK',
        d: {
          number: window.fixtureIdentity,
          name: 'Synthetic Student'
        }
      })
    });
  }

  if (urlStr.includes('/reservation/api/topic/resource-list')) {
    return Promise.resolve({
      status: 200,
      url: urlStr,
      text: async () => JSON.stringify(window.fixtureReply || {
        e: 'OK',
        d: {
          data: [
            {
              base: {
                id: 900,
                name: 'Synthetic Badminton Court',
                type: 1
              }
            }
          ]
        }
      })
    });
  }

  if (urlStr.includes('/reservation/site/resource/calendar')) {
    return Promise.resolve({
      status: 200,
      url: urlStr,
      text: async () => JSON.stringify(window.fixtureReply || {
        e: 'OK',
        d: {
          time: [
            { id: 71, str_time: '10:00-11:00' }
          ],
          resource: [
            { id: 901, name: 'Synthetic Court 1' }
          ]
        }
      })
    });
  }

  if (urlStr.includes('/reservation/site/appointment/appointment-list') || urlStr.includes('/reservation/site/appointmentList')) {
    const defaultData = [
      {
        id: 30,
        resource_name: 'Synthetic Badminton Court',
        status: '已预约',
        type: 7,
        is_cancel: true,
        slots: [
          {
            date: '2099-01-03',
            time: '10:00-11:00',
            resource_id: 901,
            resource_name: 'Synthetic Court 1',
            active: true,
            can_cancel: true
          }
        ]
      },
      {
        id: 31,
        resource_name: 'Synthetic Badminton Court',
        status: '已预约',
        type: 7,
        is_cancel: true,
        slots: [
          {
            date: '2099-01-03',
            time: '10:00-11:00',
            resource_id: 901,
            resource_name: 'Synthetic Court 1',
            active: true,
            can_cancel: true
          }
        ]
      }
    ];
    return Promise.resolve({
      status: 200,
      url: urlStr,
      text: async () => JSON.stringify(window.fixtureReply || {
        e: 'OK',
        d: {
          data: window.fixtureAppointments || defaultData
        }
      })
    });
  }

  if (urlStr.includes('/reservation/site/appointment/appointment-detail')) {
    return Promise.resolve({
      status: 200,
      url: urlStr,
      text: async () => JSON.stringify(window.fixtureReply || {
        e: 'OK',
        d: {
          id: 30,
          resource_name: 'Synthetic Badminton Court',
          slots: [
            {
              date: '2099-01-03',
              time: '10:00-11:00',
              resource_id: 901,
              resource_name: 'Synthetic Court 1',
              active: true,
              can_cancel: true
            }
          ]
        }
      })
    });
  }

  return Promise.resolve({
    status: 200,
    url: urlStr,
    text: async () => JSON.stringify(window.fixtureReply || { e: 'OK', d: { dynamic: true } })
  });
};

window.XMLHttpRequest = class {
  constructor() {
    this.method = 'GET';
    this.url = '';
    this.headers = {};
    this.status = 0;
    this.responseText = '';
    this.responseURL = '';
  }
  open(method, url) {
    this.method = method;
    this.url = url + '?synthetic-waf=dynamic';
  }
  setRequestHeader(k, v) {
    this.headers[k] = v;
  }
  send(form) {
    const isForm = (typeof FormData !== 'undefined' && form instanceof FormData);
    window.fixtureCalls.push({
      transport: 'xhr',
      url: this.url,
      method: this.method,
      sign: this.headers['sign-key'],
      form: isForm
    });

    if (window.fixtureNextWriteError) {
      window.fixtureNextWriteError = false;
      setTimeout(() => {
        if (this.onerror) this.onerror();
      }, 15);
      return;
    }

    if (window.fixtureNextWriteTimeout) {
      window.fixtureNextWriteTimeout = false;
      setTimeout(() => {
        if (this.ontimeout) this.ontimeout();
      }, 15);
      return;
    }

    this.status = 200;
    this.responseURL = this.url;
    this.responseText = JSON.stringify(window.fixtureReply || { e: 'OK', d: { dynamic: true } });
    setTimeout(() => {
      if (this.onload) this.onload();
    }, 15);
  }
  abort() {
    if (this.onabort) this.onabort();
  }
};
</script>
</body>
</html>
            """.trimIndent()
        }
    }
}
