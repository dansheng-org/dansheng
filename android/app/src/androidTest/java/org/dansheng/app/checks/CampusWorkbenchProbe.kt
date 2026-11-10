// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app.checks

import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.dansheng.android.PortError
import org.dansheng.app.CampusVenueHost
import org.dansheng.app.DanshengApi
import org.dansheng.app.FlutterError
import org.dansheng.app.HostCommand
import org.dansheng.app.MainActivity
import org.dansheng.app.PackageImport
import org.dansheng.app.RuntimeHost
import org.dansheng.app.VenueAuthRestoreHelper
import org.dansheng.app.VisiblePage
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Android Instrumentation probe verifying the native campus workbench refactor:
 * - Sealed synthetic network-blocked system WebView (never connects to external services).
 * - Packaged builtin-venues/ assets staged with version/digest enforcement into immutable private app storage.
 * - Native ModernSheet adaptive confirmation for manual reservation with CTA '确认预约'.
 * - Signed internal read service auto-available without hidden plugin enable confirmation.
 * - Human-readable preview approval verification and exact parameter matching.
 * - Direct manual reservation journey without importing external scheduling plugins.
 * - Real DanXi calendar shape parsing and per-court availability distinction.
 * - Single confirmed manual POST; no pre-approval writes.
 * - Zero background jobs or alarm timers registered for manual operations.
 * - Unknown write result / timeout fencing: journaled as uncertain and never resubmitted.
 * - Optional scheduler install separately: shared auth session without duplicating write authority.
 * - Saved password: hidden login, single submission, same-page visible fallback, cooldown, silent read restore.
 */
object CampusWorkbenchProbe {

    // Stands in for the identity page. Network loads stay blocked; the button only counts
    // clicks and stays on the page, which is what a rejected password looks like.
    private const val SYNTHETIC_LOGIN_HTML = """<!doctype html>
<html>
<head><meta charset="utf-8"><title>Synthetic Login Fixture</title></head>
<body>
<input id="login-username"><input id="login-password" type="password">
<button class="el-button content_submit" onclick="window.fixtureSubmits=(window.fixtureSubmits||0)+1">登录</button>
</body>
</html>"""

    private const val FALLBACK_WORKBENCH_HTML = """<!doctype html>
<html>
<head><meta charset="utf-8"><title>Synthetic Workbench Fixture</title></head>
<body>
<h2>Synthetic Workbench Page</h2>
<script>
window.fixtureIdentity = 'fixture-workbench-account';
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
                name: '江湾体育馆-羽毛球场',
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
            { id: 71, str_time: '10:00-11:00', start_time: '10:00', end_time: '11:00' },
            { id: 72, str_time: '11:00-12:00', start_time: '11:00', end_time: '12:00' }
          ],
          resource: [
            { id: 901, name: '1号羽毛球场' },
            { id: 902, name: '2号羽毛球场' }
          ],
          data: {
            '2099-01-03': {
              '901': {
                '71': { num: 1, status: 0, occupy: false, read_only: false },
                '72': { num: 1, status: 0, occupy: false, read_only: false }
              },
              '902': {
                '71': { num: 0, status: 1, occupy: true, read_only: false },
                '72': { num: 0, status: 1, occupy: true, read_only: false }
              }
            }
          }
        }
      })
    });
  }

  if (urlStr.includes('/reservation/site/appointment/appointment-list') || urlStr.includes('/reservation/site/appointmentList')) {
    const defaultData = [
      {
        id: 30,
        resource_name: '江湾体育馆-羽毛球场',
        status: 0,
        status_name: '已预约',
        type: 7,
        is_cancel: true,
        slots: [
          {
            date: '2099-01-03',
            time: '10:00-11:00',
            resource_id: 901,
            resource_name: '1号羽毛球场',
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
          resource_name: '江湾体育馆-羽毛球场',
          status: 0,
          status_name: '已预约',
          qrcode: 'synthetic-qr-code',
          appointment_time: [
            {
              date: '2099-01-03',
              str_time: '10:00-11:00',
              resource_id: 901,
              resource_name: '1号羽毛球场',
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
      form: isForm,
      body: typeof form === 'string' ? form : null
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
    if (this.url.includes('/reservation/site/resource/launch')) {
      this.responseText = JSON.stringify({ e: 'OK', m: '预约成功' });
    } else {
      this.responseText = JSON.stringify(window.fixtureReply || { e: 'OK', d: { dynamic: true } });
    }
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
</html>"""

    fun run(test: Instrumentation, rt: RuntimeHost, out: Bundle) {
        var currentStep = "initialization"
        fun setStep(name: String) {
            currentStep = name
            out.putString("step", name)
            test.sendStatus(1, Bundle().apply { putString("stage", name) })
        }

        try {
            runWorkbench(test, rt, out, ::setStep)
            out.putString("result", "passed")
        } catch (t: Throwable) {
            out.putString("result", "failed")
            out.putString("step", currentStep)
            out.putString("reason", if (t is PortError) t.code else t.javaClass.simpleName)
            out.putInt(
                "assertion_line",
                t.stackTrace.firstOrNull { it.fileName == "CampusWorkbenchProbe.kt" }?.lineNumber ?: 0
            )
            throw t
        }
    }

    private data class StagedSchedulerPackage(
        val pluginId: String,
        val stagedDir: File,
        val pkgDir: File,
        val manifest: JSONObject,
        val policy: JSONObject,
        val zipHash: String
    )

    private fun runWorkbench(
        test: Instrumentation,
        rt: RuntimeHost,
        out: Bundle,
        setStep: (String) -> Unit
    ) {
        setStep("clean_previous_synthetic_state")
        try {
            test.targetContext.getSharedPreferences("builtin-venue-receipt", 0).edit().clear().commit()
            test.targetContext.getSharedPreferences("dansheng-mutations-v1", 0).edit().clear().commit()
        } catch (_: Throwable) {}

        setStep("fresh_environment_verification")
        val initialAccount = "fixture-wb-" + UUID.randomUUID().toString().take(8)

        // This runner uses a dedicated QA profile. Exercise a genuinely absent add-on.
        val prePlugins = rt.request("plugins.list") as JSONArray
        for (i in 0 until prePlugins.length()) {
            val p = prePlugins.getJSONObject(i)
            if (p.getString("id") == "official.fudan-sports") {
                rt.request("plugins.disable", JSONObject().put("plugin_id", "official.fudan-sports"))
                rt.revoke("official.fudan-sports")
                rt.request("plugins.uninstall",JSONObject().put("plugin_id","official.fudan-sports"))
            }
        }
        val activePlugins = rt.request("plugins.list") as JSONArray
        check((0 until activePlugins.length()).none {
            activePlugins.getJSONObject(it).getString("id") == "official.fudan-sports" &&
            activePlugins.getJSONObject(it).optBoolean("enabled", false)
        }) { "External scheduling plugin must not be enabled for manual journey" }

        setStep("configure_synthetic_fixture")
        // Load the correct workbench fixture into syntheticPageHtml with initialAccount
        applyWorkbenchFixture(test, initialAccount)

        setStep("account_onboarding")
        rt.setAccount(initialAccount)
        rt.request(
            "accounts.upsert",
            JSONObject().put("account_id", initialAccount).put("label", "Synthetic Workbench Account")
        )

        setStep("attach_activity")
        val intent = Intent(test.targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val activity = foregroundActivity(test, intent)
        try {
            activity.getSharedPreferences("builtin-venue-receipt", 0).edit().clear().commit()
        } catch (_: Throwable) {}
        rt.attach(activity)

        val venueHost = CampusVenueHost(activity, rt)

        try {
            setStep("no_saved_password_asks_native_sheet")
            val loadsBeforeSheet = OfflineApplication.pageLoads.get()
            val asked = CompletableFuture<Result<String>>()
            CoroutineScope(Dispatchers.IO).launch {
                asked.complete(runCatching { activity.invoke(HostCommand.CAMPUS, JSONObject().put("method", "venues.visibleLogin").toString()) })
            }
            clickConfirmWhenReady(test, activity, "取消", timeoutMs = 15_000L)
            val askedErr = asked.get(10, TimeUnit.SECONDS).exceptionOrNull()
            check((askedErr as? FlutterError)?.code == "Cancelled") { "Dismissing the sheet must cancel the login, got: $askedErr" }
            check(OfflineApplication.pageLoads.get() == loadsBeforeSheet) { "The login button must ask in the sheet before any page opens" }

            setStep("identity_mismatch_login_rejection")
            // Apply mismatch identity into the workbench fixture (never swap in sports default HTML)
            applyWorkbenchFixture(test, "wrong-student-number")

            // CampusVenueHost itself has no sheet, so this is the no-password dialog; its watcher rejects by itself.
            val shownBeforeMismatch = OfflineApplication.interactiveShown.get()
            val mismatchFuture = callVenueHost(venueHost, "visibleLogin", JSONObject())

            val mismatchResult = mismatchFuture.get(25, TimeUnit.SECONDS)
            check(OfflineApplication.interactiveShown.get() == shownBeforeMismatch + 1) { "Without a saved password the page must be visible" }
            check(mismatchResult.isFailure) { "Identity mismatch must fail without logging in wrong student" }
            val mismatchErr = mismatchResult.exceptionOrNull()
            check(mismatchErr is PortError) { "Mismatch should fail with PortError, got: $mismatchErr" }
            out.putString("mismatch_port", mismatchErr.code)
            out.putString("mismatch_probe", OfflineApplication.lastProbeCode)
            check(OfflineApplication.lastProbeCode == "AccountMismatch" && mismatchErr.code == "AuthenticationRequired") {
                "Expected rejected synthetic identity; probe=${OfflineApplication.lastProbeCode}, port=${mismatchErr.code}"
            }

            setStep("identity_match_login_success")
            // A blank identity reads as a guest page: the dialog keeps waiting, and
            // a human may spend longer than an ordinary 10 s host call signing in.
            applyWorkbenchFixture(test, "")
            val matchFuture = callVenueHost(venueHost, "visibleLogin", JSONObject())
            Thread.sleep(55_000L)
            check(!matchFuture.isDone) { "The dialog must keep waiting for the person" }

            // Restore active account identity into the workbench fixture
            applyWorkbenchFixture(test, initialAccount)
            val matchResult = matchFuture.get(15, TimeUnit.SECONDS)
            val matchVal = matchResult.getOrThrow() as JSONObject
            check(matchVal.optBoolean("authenticated", false)) { "Session must be authenticated" }
            check(matchVal.optString("account_id") == initialAccount) { "Session account must match active account" }
            out.putLong("visible_login_user_wait_ms", 55_000L)

            verifySavedPasswordLogin(test, rt, activity, venueHost, initialAccount, out, setStep)

            setStep("venues_list_retrieval")
            // Signed internal read service is auto-available: directly executes without hidden plug-in enable confirmation
            val venuesFuture = callVenueHost(venueHost, "venues", JSONObject())
            val venuesRaw = venuesFuture.get(15, TimeUnit.SECONDS).getOrThrow() as JSONArray
            check(venuesRaw.length() > 0) { "Venues list was empty" }
            val venue0 = venuesRaw.getJSONObject(0)
            check(venue0.getInt("id") == 900) { "Expected venue id 900" }
            check(venue0.getString("name").contains("羽毛球")) {
                "Expected badminton court containing '羽毛球', got: ${venue0.getString("name")}"
            }
            out.putInt("venue_count", venuesRaw.length())

            setStep("calendar_danxi_per_court_status")
            val calFuture = callVenueHost(
                venueHost,
                "calendar",
                JSONObject().put("venue_id", 900).put("target_date", "2099-01-03")
            )
            val cal = calFuture.get(15, TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(cal.has("slots")) { "Calendar response missing slots array" }
            val slots = cal.getJSONArray("slots")
            check(slots.length() >= 2) { "Expected at least 2 court slots, got: ${slots.length()}" }

            val slot901 = (0 until slots.length()).map { slots.getJSONObject(it) }.firstOrNull {
                it.getInt("court_id") == 901 && it.getInt("period_id") == 71
            }
            checkNotNull(slot901) { "Slot for Court 901 was missing" }
            check(slot901.getBoolean("available")) { "Court 901 should be available based on DanXi num=1, occupy=false" }
            check(!slot901.optBoolean("occupied", false)) { "Court 901 occupied flag must be false" }

            val slot902 = (0 until slots.length()).map { slots.getJSONObject(it) }.firstOrNull {
                it.getInt("court_id") == 902 && it.getInt("period_id") == 71
            }
            checkNotNull(slot902) { "Slot for Court 902 was missing" }
            check(!slot902.getBoolean("available")) { "Court 902 should be unavailable based on DanXi status=1, occupy=true" }
            check(slot902.optBoolean("occupied", true)) { "Court 902 occupied flag must be true" }
            out.putInt("slots_count", slots.length())

            setStep("appointments_and_detail")
            val appts = callVenueHost(venueHost, "appointments", JSONObject()).get(10, TimeUnit.SECONDS).getOrThrow() as JSONArray
            check(appts.length() > 0) { "Appointments query returned empty list" }
            val appt0 = appts.getJSONObject(0)
            check(appt0.getInt("id") == 30)

            val detail = callVenueHost(
                venueHost,
                "detail",
                JSONObject().put("appointment_id", 30)
            ).get(10, TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(detail.getInt("id") == 30)

            setStep("prepare_manual_reservation")
            val prepParams = JSONObject()
                .put("venue_id", 900)
                .put("target_date", "2099-01-03")
                .put("period_id", 71)
                .put("court_id", 901)
                .put("time", "10:00-11:00")
            val prep = callVenueHost(venueHost, "prepareManual", prepParams).get(10, TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(prep.has("canonical_input")) { "prepareManual missing canonical_input" }
            check(prep.has("summary")) { "prepareManual missing human-readable summary" }
            val canonicalInput = prep.getJSONObject("canonical_input")
            check(canonicalInput.getString("account_id") == initialAccount)
            check(canonicalInput.getInt("venue_id") == 900)
            check(canonicalInput.getInt("court_id") == 901)
            check(canonicalInput.getInt("period_id") == 71)

            setStep("unapproved_write_blocked_zero_posts")
            evaluateInPage(test, "window.fixtureCalls = [];")
            // Direct call to core without valid recorded consent must fail closed
            val directAttempt = runCatching {
                rt.request(
                    "plugins.run",
                    JSONObject()
                        .put("plugin_id", CampusVenueHost.BUILTIN_PLUGIN_ID)
                        .put("action", "reserve")
                        .put("input", canonicalInput)
                )
            }
            check(directAttempt.isFailure) { "Direct reserve without recorded consent must fail" }
            val directPosts = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(directPosts == 0) { "Blocked write must send exactly 0 POSTs, got: $directPosts" }

            setStep("occupied_court_precheck_zero_posts")
            evaluateInPage(test, "window.fixtureCalls = [];")
            // Reserving Court 902 (which is occupied in DanXi calendar) fails at availability recheck before POST
            val occupiedPrep = callVenueHost(
                venueHost,
                "prepareManual",
                JSONObject()
                    .put("venue_id", 900)
                    .put("target_date", "2099-01-03")
                    .put("period_id", 71)
                    .put("court_id", 902)
                    .put("time", "10:00-11:00")
            ).get(10, TimeUnit.SECONDS).getOrThrow() as JSONObject

            val occupiedFuture = callVenueHost(venueHost, "reserve", occupiedPrep)
            val occupiedRes = runCatching { occupiedFuture.get(15, TimeUnit.SECONDS).getOrThrow() }
            check(occupiedRes.isFailure) { "Occupied court reservation must fail" }
            val occupiedErr = occupiedRes.exceptionOrNull()
            check(occupiedErr is PortError && occupiedErr.code == "CourtOccupied") {
                "Expected CourtOccupied error, got: $occupiedErr"
            }
            val occupiedPosts = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(occupiedPosts == 0) { "Occupied slot must abort before sending launch POST, got: $occupiedPosts" }

            setStep("native_modern_sheet_cancellation")
            evaluateInPage(test, "window.fixtureCalls = [];")
            val cancelFuture = callVenueHost(venueHost, "reserve", prep)
            clickConfirmWhenReady(test, activity, "取消", timeoutMs = 15_000L)
            val cancelResult = runCatching { cancelFuture.get(15, TimeUnit.SECONDS).getOrThrow() }
            check(cancelResult.isFailure) { "Dismissed/cancelled ModernSheet must fail" }
            val cancelErr = cancelResult.exceptionOrNull()
            check(cancelErr is PortError && cancelErr.code == "Cancelled") {
                "Expected Cancelled error, got: $cancelErr"
            }
            val cancelPosts = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(cancelPosts == 0) { "Cancelled reservation must send zero POSTs, got: $cancelPosts" }

            setStep("confirmed_manual_single_post")
            evaluateInPage(test, "window.fixtureCalls = [];")
            val confirmedFuture = callVenueHost(venueHost, "reserve", prep)
            clickConfirmWhenReady(test, activity, "确认预约", timeoutMs = 20_000L)
            val confirmedRes = confirmedFuture.get(15, TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(confirmedRes.getString("status") == "success") { "Reservation failed: $confirmedRes" }

            val launchPosts = evaluateInPage(
                test,
                "window.fixtureCalls.filter(c => c.method === 'POST' && c.url.includes('/resource/launch')).length"
            ).toIntOrNull() ?: 0
            check(launchPosts == 1) { "Confirmed manual reservation must send exactly 1 POST, got: $launchPosts" }
            out.putInt("confirmed_posts", launchPosts)
            setStep("manual_cancel_one_record")
            val cancelled=callVenueHost(venueHost,"cancel",JSONObject().put("appointment_id",30))
            clickConfirmWhenReady(test,activity,"取消预约")
            val cancellation=cancelled.get(20,TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(cancellation.getString("status")=="cancelled" && cancellation.getInt("appointment_id")==30)
            val cancellationsSent=evaluateInPage(test,"window.fixtureCalls.filter(c=>c.method==='POST' && c.url.includes('cancel-appointment')).length").toInt()
            check(cancellationsSent==1);out.putInt("confirmed_cancel_posts",cancellationsSent)

            setStep("verify_no_jobs_or_timers_for_manual")
            val jobs = rt.request("jobs.status") as JSONArray
            val manualJobs = (0 until jobs.length()).map { jobs.getJSONObject(it) }.filter {
                it.optJSONObject("data")?.optString("plugin_id") == CampusVenueHost.BUILTIN_PLUGIN_ID
            }
            check(manualJobs.any { it.optJSONObject("data")?.optString("action")=="reserve" && it.optString("state")=="succeeded" })
            check(manualJobs.none {
                val d=it.getJSONObject("data"); d.has("run_at") || d.has("prepare_at") || d.has("deadline_at") || it.optString("state")=="scheduled"
            }) { "Manual invocation must not schedule a future job" }

            val subscriptions = rt.subscriptions()
            val manualSubs = (0 until subscriptions.length()).map { subscriptions.getJSONObject(it) }.filter {
                manualJobs.any { job -> job.getString("id")==it.optString("job_id") } ||
                it.optString("job_id").contains(prep.getJSONObject("canonical_input").optString("task_id"))
            }
            check(manualSubs.isEmpty()) { "Manual reservation must NOT register alarm/timer subscriptions" }

            setStep("uncertain_write_loss_simulation")
            val uncertainTaskId = "manual-uncertain-" + UUID.randomUUID().toString().take(8)
            val uncertainPrep = callVenueHost(
                venueHost,
                "prepareManual",
                JSONObject()
                    .put("venue_id", 900)
                    .put("target_date", "2099-01-03")
                    .put("period_id", 71)
                    .put("court_id", 901)
                    .put("time", "10:00-11:00")
                    .put("task_id", uncertainTaskId)
            ).get(10, TimeUnit.SECONDS).getOrThrow() as JSONObject

            evaluateInPage(test, "window.fixtureCalls = []; window.fixtureNextWriteError = true;")
            val uncertainFuture = callVenueHost(venueHost, "reserve", uncertainPrep)
            clickConfirmWhenReady(test, activity, "确认预约", timeoutMs = 20_000L)
            val uncertainResult = runCatching { uncertainFuture.get(15, TimeUnit.SECONDS).getOrThrow() }
            check(uncertainResult.isFailure) { "Write with network error must fail" }
            val uncertainErr = uncertainResult.exceptionOrNull()
            check(uncertainErr is PortError && uncertainErr.code == "NeedsReconciliation") {
                "Expected NeedsReconciliation on dropped write, got: $uncertainErr"
            }

            setStep("unknown_result_never_resubmitted")
            val postsBeforeDup = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(postsBeforeDup == 1) { "Expected exactly 1 failed POST, got: $postsBeforeDup" }

            // Resubmit attempt must immediately fail with NeedsReconciliation without sending a 2nd POST
            val dupFuture = callVenueHost(venueHost, "reserve", uncertainPrep)
            clickConfirmWhenReady(test, activity, "确认预约", timeoutMs = 20_000L)
            val dupResult = runCatching { dupFuture.get(15, TimeUnit.SECONDS).getOrThrow() }
            check(dupResult.isFailure) { "Resubmitting uncertain reservation must fail" }
            val dupErr = dupResult.exceptionOrNull()
            check(dupErr is PortError && dupErr.code == "NeedsReconciliation") {
                "Expected duplicate call to fail with NeedsReconciliation, got: $dupErr"
            }

            val postsAfterDup = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(postsAfterDup == postsBeforeDup) {
                "Uncertain result must NEVER be resubmitted: POST count went from $postsBeforeDup to $postsAfterDup"
            }

            setStep("reconcile_uncertain_reservation")
            val recRes = callVenueHost(
                venueHost,
                "reconcile",
                JSONObject().put("task_id", uncertainTaskId)
            ).get(10, TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(recRes.has("status")) { "Reconciliation result missing status" }
            out.putString("reconcile_status", recRes.getString("status"))

            setStep("optional_scheduler_session_sharing")
            testSchedulerSessionSharing(test, rt, initialAccount, out)

            setStep("pigeon_host_bridge_check")
            checkPigeonHostBridge(activity, out)

        } finally {
            teardown(test, rt, activity)
        }
    }

    /** The school locks accounts after a few wrong passwords, so these paths count every submission. */
    private fun verifySavedPasswordLogin(
        test: Instrumentation,
        rt: RuntimeHost,
        activity: MainActivity,
        venueHost: CampusVenueHost,
        account: String,
        out: Bundle,
        setStep: (String) -> Unit
    ) {
        val vaultKey = "campus-login/v1/uis/$account"
        rt.vault.set(vaultKey, JSONObject().put("email", "").put("secret", "fixture-only").toString())
        try {
            setStep("saved_password_hidden_login")
            var shown = OfflineApplication.interactiveShown.get()
            val hidden = callVenueHost(venueHost, "visibleLogin", JSONObject()).get(20, TimeUnit.SECONDS).getOrThrow() as JSONObject
            check(hidden.optBoolean("authenticated", false)) { "Hidden login must authenticate" }
            check(OfflineApplication.interactiveShown.get() == shown) { "A saved password must log in without showing a page" }

            setStep("wrong_password_submitted_once_then_visible")
            OfflineApplication.syntheticLoginHtml = SYNTHETIC_LOGIN_HTML
            shown = OfflineApplication.interactiveShown.get()
            val wrong = callVenueHost(venueHost, "visibleLogin", JSONObject())
            awaitInteractive(shown + 1, VisiblePage.SILENT_TIMEOUT_MS + 10_000L)
            check(!wrong.isDone) { "The fallback must keep the login open" }
            check(rt.visiblePage.silentBlocked(account)) { "A failed hidden attempt must start the cooldown" }
            check(rt.campusLogins.venuePasswordSuspended(account) && !rt.campusLogins.canRestoreVenue(account)) {
                "A failure after the password went out must stop every automatic path, including the scheduled wake"
            }
            check(rt.prefs.getBoolean("venue-password-suspended/$account", false)) { "The suspension must survive a restart" }
            val loadsAtFallback = OfflineApplication.pageLoads.get()
            // Several rounds of the watcher.
            Thread.sleep(3_000L)
            check(evaluateInPage(test, "window.fixtureSubmits") == "1") { "The password must be submitted exactly once" }
            check(OfflineApplication.pageLoads.get() == loadsAtFallback) { "The visible fallback must not reload the page" }
            var attached = false
            test.runOnMainSync { attached = OfflineApplication.lastLoadedWebView?.isAttachedToWindow == true }
            check(attached) { "The fallback must show the same WebView" }
            clickConfirmWhenReady(test, activity, "取消", timeoutMs = 5_000L)
            val wrongErr = wrong.get(10, TimeUnit.SECONDS).exceptionOrNull()
            check((wrongErr as? PortError)?.code == "AuthenticationRequired") { "Cancelling must end the login, got: $wrongErr" }
            out.putString("hidden_failure", "submitted_once_then_same_page")

            setStep("cooldown_stops_automatic_password")
            val loadsInCooldown = OfflineApplication.pageLoads.get()
            val blockedRead = callVenueHost(venueHost, "venues", JSONObject()).get(20, TimeUnit.SECONDS).exceptionOrNull()
            check((blockedRead as? PortError)?.code == "AuthenticationRequired") { "A blocked read must reach the login button, got: $blockedRead" }
            check(OfflineApplication.pageLoads.get() == loadsInCooldown) { "A read must not start a login during the cooldown" }
            shown = OfflineApplication.interactiveShown.get()
            val visible = callVenueHost(venueHost, "visibleLogin", JSONObject())
            awaitInteractive(shown + 1, 10_000L)
            Thread.sleep(2_000L)
            check(evaluateInPage(test, "window.fixtureSubmits") == "null") { "The login button must not submit during the cooldown" }

            setStep("visible_login_clears_cooldown")
            // The person finished on the school's page, which now lands on the booking site.
            OfflineApplication.syntheticLoginHtml = null
            applyWorkbenchFixture(test, account)
            test.runOnMainSync {
                OfflineApplication.lastLoadedWebView!!.loadDataWithBaseURL(VenueAuthRestoreHelper.TOPIC,
                    OfflineApplication.syntheticPageHtml, "text/html", "UTF-8", VenueAuthRestoreHelper.TOPIC)
            }
            check((visible.get(15, TimeUnit.SECONDS).getOrThrow() as JSONObject).optBoolean("authenticated", false)) { "The watcher must finish the visible login" }
            check(!rt.visiblePage.silentBlocked(account)) { "A verified login must end the cooldown" }
            check(!rt.campusLogins.venuePasswordSuspended(account)) { "A verified login must end the suspension" }

            setStep("read_restores_session_without_ui")
            val cleared = CountDownLatch(1)
            rt.browserPort.logout(account) { cleared.countDown() }
            check(cleared.await(5, TimeUnit.SECONDS)) { "Session did not clear" }
            shown = OfflineApplication.interactiveShown.get()
            OfflineApplication.loadedViews.clear()
            val reads = listOf("venues", "appointments").map { callVenueHost(venueHost, it, JSONObject()) }
            for (read in reads) read.get(60, TimeUnit.SECONDS).getOrThrow()
            check(OfflineApplication.interactiveShown.get() == shown) { "A read must never show a page" }
            // Each login builds a new WebView; one login may still load the topic page and then SSO.
            check(OfflineApplication.loadedViews.toSet().size == 1) { "Concurrent reads must share one hidden login" }
            out.putString("read_restore", "hidden_single_login")
        } finally {
            OfflineApplication.syntheticLoginHtml = null
            rt.vault.delete(vaultKey)
            rt.campusLogins.clearVenueSuspension(account)
        }
    }

    private fun awaitInteractive(expected: Int, timeoutMs: Long) {
        val until = android.os.SystemClock.elapsedRealtime() + timeoutMs
        while (OfflineApplication.interactiveShown.get() < expected && android.os.SystemClock.elapsedRealtime() < until) Thread.sleep(100)
        check(OfflineApplication.interactiveShown.get() == expected) { "Expected the visible page to open" }
    }

    private fun testSchedulerSessionSharing(
        test: Instrumentation,
        rt: RuntimeHost,
        account: String,
        out: Bundle
    ) {
        val hasSportsAsset = try {
            test.context.assets.list("")?.any { it.startsWith("official.fudan-sports") && it.endsWith(".dspack") } == true
        } catch (_: Exception) {
            false
        }
        if (!hasSportsAsset) {
            error("Missing external scheduling test package")
            return
        }

        val staged = stageSchedulerPackage(test)
        try {
            // 1. Install scheduler plugin separately
            val installed = rt.request(
                "plugins.install",
                JSONObject().put("path", staged.pkgDir.absolutePath)
            ) as JSONObject
            check(!installed.optBoolean("enabled", false)) { "Newly installed scheduler must be disabled" }

            rt.bindPackage(staged.pluginId, staged.manifest, staged.policy, staged.zipHash)
            rt.request(
                "permissions.set",
                JSONObject().put("subject", "plugin:" + staged.pluginId).put(
                    "grant",
                    JSONObject()
                        .put("account_ids", JSONArray().put(account))
                        .put("origins", staged.manifest.getJSONArray("network"))
                        .put("capabilities", staged.manifest.getJSONArray("capabilities"))
                )
            )
            rt.request("plugins.enable", JSONObject().put("plugin_id", staged.pluginId))
            rt.activate(staged.pluginId)

            // 2. Share Auth: scheduler inherits active session established by official.fudan-venues
            val sportsVenues = rt.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "venues")
                    .put("input", JSONObject().put("account_id", account))
            ) as JSONArray
            check(sportsVenues.length() > 0) { "Scheduler should read venues through shared page session" }
            out.putString("scheduler_shared_auth", "verified")

            // 3. Without duplicating write authority:
            // scheduler CANNOT execute writes using official.fudan-venues consent
            evaluateInPage(test, "window.fixtureCalls = [];")
            val unauthSportsWrite = runCatching {
                rt.request(
                    "plugins.run",
                    JSONObject()
                        .put("plugin_id", staged.pluginId)
                        .put("action", "cancelAppointment")
                        .put("input", JSONObject().put("account_id", account).put("appointment_id", 30))
                )
            }
            check(unauthSportsWrite.isFailure) { "Scheduler must not write without its own specific consent" }
            val sportsPosts = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(sportsPosts == 0) { "Scheduler unauthorized write must send zero POSTs, got: $sportsPosts" }
            out.putString("scheduler_write_authority", "fenced_zero_posts")

        } finally {
            try {
                rt.request("plugins.disable", JSONObject().put("plugin_id", staged.pluginId))
                rt.revoke(staged.pluginId)
                rt.request("plugins.uninstall", JSONObject().put("plugin_id", staged.pluginId))
                staged.stagedDir.deleteRecursively()
            } catch (_: Exception) {}
        }
    }

    private fun checkPigeonHostBridge(activity: MainActivity, out: Bundle) {
        val pigeonAvailable = runCatching {
            if (activity is DanshengApi) {
                // Verify Pigeon DanshengApi interface on activity handles basic commands
                val infoFuture = CompletableFuture<String>()
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val res = activity.invoke(HostCommand.INFO, "{}")
                        infoFuture.complete(res)
                    } catch (t: Throwable) {
                        infoFuture.completeExceptionally(t)
                    }
                }
                val infoStr = infoFuture.get(5, TimeUnit.SECONDS)
                check(infoStr.isNotEmpty())
                "available"
            } else {
                "not_dansheng_api"
            }
        }.getOrElse { it.javaClass.simpleName }
        out.putString("pigeon_status", pigeonAvailable)
    }

    private fun callVenueHost(
        venueHost: CampusVenueHost,
        action: String,
        params: JSONObject
    ): CompletableFuture<Result<Any?>> {
        val future = CompletableFuture<Result<Any?>>()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val res = venueHost.call(action, params)
                future.complete(Result.success(res))
            } catch (t: Throwable) {
                future.complete(Result.failure(t))
            }
        }
        return future
    }

    private fun loadWorkbenchFixtureHtml(test: Instrumentation, identity: String): String {
        val rawHtml = try {
            test.context.assets.open("workbench/fixture.html").bufferedReader().use { it.readText() }
        } catch (_: Exception) {
            FALLBACK_WORKBENCH_HTML
        }
        val quoted = JSONObject.quote(identity)
        return rawHtml
            .replace("window.fixtureIdentity = 'fixture-workbench-account';", "window.fixtureIdentity = $quoted;")
            .replace("'fixture-workbench-account'", quoted)
    }

    private fun applyWorkbenchFixture(test: Instrumentation, identity: String) {
        val html = loadWorkbenchFixtureHtml(test, identity)
        OfflineApplication.syntheticPageHtml = html
        val latch = CountDownLatch(1)
        test.runOnMainSync {
            val wv = OfflineApplication.lastLoadedWebView
            if (wv != null) {
                val quoted = JSONObject.quote(identity)
                wv.evaluateJavascript(
                    "window.fixtureIdentity = $quoted; " +
                    "window.fixtureCalls = []; " +
                    "window.fixtureNextWriteError = false; " +
                    "window.fixtureNextWriteTimeout = false; " +
                    "window.fixtureReply = null; " +
                    "window.fixtureAppointments = null;",
                    null
                )
            }
            latch.countDown()
        }
        latch.await(2, TimeUnit.SECONDS)
    }

    private fun stageSchedulerPackage(test: Instrumentation): StagedSchedulerPackage {
        val inputStream = try {
            test.context.assets.open("official.fudan-sports-0.2.0.dspack")
        } catch (_: Exception) {
            val assetName = test.context.assets.list("")?.firstOrNull {
                it.startsWith("official.fudan-sports") && it.endsWith(".dspack")
            } ?: error("official.fudan-sports package asset not found")
            test.context.assets.open(assetName)
        }

        val stagedDir = inputStream.use { input ->
            PackageImport.stage(test.targetContext, input)
        }
        val zipFile = File(stagedDir, "download.zip")
        check(zipFile.isFile) { "Staged download.zip not found" }
        val zipHash = PackageImport.digest(zipFile)
        val pkgDir = File(stagedDir, "package")
        val manifest = JSONObject(File(pkgDir, "manifest.json").readText())
        val policy = JSONObject(File(pkgDir, "host-policy.json").readText())

        return StagedSchedulerPackage(
            pluginId = manifest.getString("id"),
            stagedDir = stagedDir,
            pkgDir = pkgDir,
            manifest = manifest,
            policy = policy,
            zipHash = zipHash
        )
    }

    private fun foregroundActivity(test: Instrumentation, intent: Intent): MainActivity {
        val activity = test.startActivitySync(intent) as MainActivity
        val until = android.os.SystemClock.elapsedRealtime() + 90_000
        while (android.os.SystemClock.elapsedRealtime() < until) {
            var ready = false
            test.runOnMainSync {
                ready = activity.hasWindowFocus() && activity.window.decorView.isShown && !activity.isFinishing
            }
            if (ready) {
                test.waitForIdleSync()
                return activity
            }
            Thread.sleep(100)
        }
        error("Product Activity did not receive foreground window focus")
    }

    private fun findActiveRoots(fallbackActivity: MainActivity): List<View> {
        if(android.os.Build.VERSION.SDK_INT>=29)
            return android.view.inspector.WindowInspector.getGlobalWindowViews().asReversed()
        val roots = mutableListOf<View>()
        try {
            val wmgClass = Class.forName("android.view.WindowManagerGlobal")
            val getInstance = wmgClass.getMethod("getInstance")
            val wmg = getInstance.invoke(null)
            val mViewsField = wmgClass.getDeclaredField("mViews")
            mViewsField.isAccessible = true
            val views = mViewsField.get(wmg) as? List<*>
            if (views != null) {
                for (v in views) {
                    if (v is View) roots.add(v)
                }
            }
        } catch (_: Throwable) {}
        if (roots.isEmpty()) {
            roots.add(fallbackActivity.window.decorView)
        }
        return roots.asReversed()
    }

    private fun findButtonWithText(view: View?, text: String): Button? {
        if (view == null) return null
        if (view is Button && (view.text == text || view.text.toString().trim() == text.trim())) {
            return view
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findButtonWithText(view.getChildAt(i), text)
                if (found != null) return found
            }
        }
        return null
    }

    private fun clickConfirmWhenReady(
        test: Instrumentation,
        activity: MainActivity,
        expectedText: String = "确认预约",
        timeoutMs: Long = 40_000L
    ) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var clicked = false
        while (!clicked && System.currentTimeMillis() < deadline) {
            val latch = CountDownLatch(1)
            test.runOnMainSync {
                val roots = findActiveRoots(activity)
                for (root in roots) {
                    val btn = findButtonWithText(root, expectedText)
                    if (btn != null && btn.isShown) {
                        btn.performClick()
                        clicked = true
                        break
                    }
                }
                latch.countDown()
            }
            latch.await(1, TimeUnit.SECONDS)
            if (!clicked) Thread.sleep(60)
        }
        check(clicked) { "Failed to find and click native button ('$expectedText') within ${timeoutMs}ms" }
    }

    private fun evaluateInPage(test: Instrumentation, script: String, timeoutMs: Long = 3000L): String {
        val latch = CountDownLatch(1)
        var result = ""
        test.runOnMainSync {
            val wv = OfflineApplication.lastLoadedWebView
            if (wv != null) {
                wv.evaluateJavascript(script) { res ->
                    result = res ?: ""
                    latch.countDown()
                }
            } else {
                latch.countDown()
            }
        }
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return result.trim().removeSurrounding("\"")
    }

    private fun teardown(
        test: Instrumentation,
        rt: RuntimeHost,
        activity: MainActivity
    ) {
        try {
            rt.attach(null)
            test.runOnMainSync {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    activity.finish()
                }
            }
        } catch (_: Throwable) {}

        try {
            val cleared = CountDownLatch(1)
            val acc = rt.account()
            if (acc != null) {
                rt.browserPort.logout(acc) { cleared.countDown() }
                cleared.await(5, TimeUnit.SECONDS)
            }
        } catch (_: Throwable) {}
    }
}
