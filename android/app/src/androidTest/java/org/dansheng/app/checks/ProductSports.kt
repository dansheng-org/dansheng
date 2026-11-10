// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app.checks

import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import org.dansheng.android.PortError
import org.dansheng.app.MainActivity
import org.dansheng.app.PackageImport
import org.dansheng.app.RuntimeHost
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object ProductSports {
    private val ACCOUNT = "fixture-sports-"+UUID.randomUUID().toString().take(8)
    private const val PLUGIN_ID = "official.fudan-sports"

    fun run(test: Instrumentation, runtime: RuntimeHost, output: Bundle, variant: String) {
        var currentStep = "initialization"
        fun setStep(name: String) {
            currentStep = name
            output.putString("step", name)
            test.sendStatus(1,Bundle().apply { putString("stage",name) })
        }

        try {
            when (variant) {
                "sports" -> runSports(test, runtime, output, ::setStep)
                "sportsCold" -> runSports(test,runtime,output,::setStep,true)
                "sportsLoss" -> runSportsLoss(test, runtime, output, ::setStep)
                else -> error("Unknown variant: $variant")
            }
            output.putString("result", "passed")
        } catch (t: Throwable) {
            output.putString("result", "failed")
            output.putString("step", currentStep)
            output.putString("reason", if (t is PortError) t.code else t.javaClass.simpleName)
            output.putString("probe_result", OfflineApplication.lastProbeCode)
            output.putInt("assertion_line",t.stackTrace.firstOrNull { it.fileName=="ProductSports.kt" }?.lineNumber ?: 0)
            throw t
        }
    }

    private data class StagedPackage(
        val pluginId: String,
        val stagedDir: File,
        val pkgDir: File,
        val manifest: JSONObject,
        val policy: JSONObject,
        val zipHash: String
    )

    private fun stagePackage(test: Instrumentation): StagedPackage {
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
        val manifestFile = File(pkgDir, "manifest.json")
        check(manifestFile.isFile) { "manifest.json not found in package" }
        val manifest = JSONObject(manifestFile.readText())

        val policyFile = File(pkgDir, "host-policy.json")
        check(policyFile.isFile) { "host-policy.json not found in package" }
        val policy = JSONObject(policyFile.readText())

        val pluginId = manifest.getString("id")
        check(pluginId == PLUGIN_ID) { "Unexpected plugin id: $pluginId" }

        return StagedPackage(
            pluginId = pluginId,
            stagedDir = stagedDir,
            pkgDir = pkgDir,
            manifest = manifest,
            policy = policy,
            zipHash = zipHash
        )
    }

    private fun runSports(
        test: Instrumentation,
        runtime: RuntimeHost,
        output: Bundle,
        setStep: (String) -> Unit, cold:Boolean=false
    ) {
        setStep("staging_package")
        val staged = stagePackage(test)

        setStep("runtime_onboarding")
        val info = runtime.request("core.info") as JSONObject
        check(info.length() > 0) { "Core info was empty" }
        runtime.setAccount(ACCOUNT)
        runtime.request(
            "accounts.upsert",
            JSONObject().put("account_id", ACCOUNT).put("label", "Synthetic Sports Account")
        )

        setStep("plugin_install")
        val existing = runtime.request("plugins.list") as JSONArray
        val isInstalled = (0 until existing.length()).any {
            existing.getJSONObject(it).getString("id") == staged.pluginId
        }
        if (!isInstalled) {
            val installed = runtime.request(
                "plugins.install",
                JSONObject().put("path", staged.pkgDir.absolutePath)
            ) as JSONObject
            check(!installed.optBoolean("enabled", false)) { "Newly installed plugin must be disabled" }
        }

        setStep("bind_package")
        runtime.bindPackage(staged.pluginId, staged.manifest, staged.policy, staged.zipHash)

        setStep("core_grant_and_enable")
        runtime.request(
            "permissions.set",
            JSONObject().put("subject", "plugin:" + staged.pluginId).put(
                "grant",
                JSONObject()
                    .put("account_ids", JSONArray().put(ACCOUNT))
                    .put("origins", staged.manifest.getJSONArray("network"))
                    .put("capabilities", staged.manifest.getJSONArray("capabilities"))
            )
        )
        runtime.request("plugins.enable", JSONObject().put("plugin_id", staged.pluginId))
        runtime.activate(staged.pluginId)

        setStep("attach_activity")
        val intent = Intent(test.targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val activity = foregroundActivity(test,intent)
        runtime.attach(activity)

        try {
            setStep("identity_mismatch_test")
            OfflineApplication.setSyntheticIdentity("wrong-student-number")
            val mismatchFuture = CompletableFuture<Result<Any?>>()
            Thread {
                try {
                    val res = runtime.request(
                        "plugins.run",
                        JSONObject()
                            .put("plugin_id", staged.pluginId)
                            .put("action", "visibleLogin")
                            .put("input", JSONObject().put("account_id", ACCOUNT))
                    )
                    mismatchFuture.complete(Result.success(res))
                } catch (t: Throwable) {
                    mismatchFuture.complete(Result.failure(t))
                }
            }.start()

            clickConfirmWhenReady(test, mismatchFuture)
            val mismatchResult = mismatchFuture.get(15, TimeUnit.SECONDS)
            check(mismatchResult.isFailure) { "Identity mismatch must fail login without accepting wrong account" }
            val mismatchErr = mismatchResult.exceptionOrNull()
            check(mismatchErr is PortError) { "Mismatch should fail with PortError, got: $mismatchErr" }

            setStep("identity_match_test")
            OfflineApplication.setSyntheticIdentity(ACCOUNT)
            val matchFuture = CompletableFuture<Result<Any?>>()
            Thread {
                try {
                    val res = runtime.request(
                        "plugins.run",
                        JSONObject()
                            .put("plugin_id", staged.pluginId)
                            .put("action", "visibleLogin")
                            .put("input", JSONObject().put("account_id", ACCOUNT))
                    )
                    matchFuture.complete(Result.success(res))
                } catch (t: Throwable) {
                    matchFuture.complete(Result.failure(t))
                }
            }.start()

            clickConfirmWhenReady(test, matchFuture)
            val matchResult = matchFuture.get(15, TimeUnit.SECONDS)
            val matchVal = matchResult.getOrThrow() as JSONObject
            check(matchVal.getBoolean("authenticated")) { "Session must be authenticated" }
            check(matchVal.getString("account_id") == ACCOUNT) { "Session account must match" }

            setStep("venues")
            val venues = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "venues")
                    .put("input", JSONObject().put("account_id", ACCOUNT))
            ) as JSONArray
            check(venues.length() > 0) { "Venues list was empty" }
            val venue0 = venues.getJSONObject(0)
            check(venue0.getInt("id") == 900) { "Expected venue id 900" }
            check(venue0.getString("name") == "Synthetic Badminton Court")

            setStep("calendar")
            val cal = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "calendar")
                    .put("input", JSONObject()
                        .put("account_id", ACCOUNT)
                        .put("venue_id", 900)
                        .put("target_date", "2099-01-03"))
            ) as JSONObject
            val periods = cal.getJSONArray("periods")
            check(periods.length() > 0) { "Calendar periods were empty" }
            check(periods.getJSONObject(0).getInt("id") == 71)

            setStep("appointments")
            val appts = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "appointments")
                    .put("input", JSONObject().put("account_id", ACCOUNT))
            ) as JSONArray
            check(appts.length() > 0) { "Appointments list was empty" }
            check(appts.getJSONObject(0).getInt("id") == 30)

            setStep("appointment_detail")
            val detail = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "appointmentDetail")
                    .put("input", JSONObject().put("account_id", ACCOUNT).put("appointment_id", 30))
            ) as JSONObject
            check(detail.getInt("id") == 30)
            check(detail.getString("resource_name") == "Synthetic Badminton Court")

            setStep("consent_and_schedule")
            val releaseEpoch = System.currentTimeMillis() + if(cold) 52_000L else 24_000L
            val releaseAt = OffsetDateTime.ofInstant(Instant.ofEpochMilli(releaseEpoch), ZoneOffset.ofHours(8))
                .format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)
            val taskId = "product-sports-task-" + UUID.randomUUID().toString().take(8)
            val planInput = JSONObject()
                .put("account_id", ACCOUNT)
                .put("task_id", taskId)
                .put("options",JSONObject().put("nativePrewarmMs",20000).put("browserPreloadMs",17000))
                .put("venue_id", 900)
                .put("target_date", "2099-01-04")
                .put("release_at", releaseAt)
                .put("plans", JSONArray().put(JSONObject()
                    .put("time", "10:00-11:00")
                    .put("period_id", 71)
                    .put("courts", JSONArray().put(901))
                ))

            val preview = runtime.request(
                "actions.preview",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "schedule")
                    .put("input", planInput)
            ) as JSONObject
            val previewHash = preview.getString("input_sha256")
            runtime.recordConsent(staged.pluginId, "schedule", planInput, previewHash)

            val schedRes = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "schedule")
                    .put("input", planInput)
            ) as JSONObject
            check(schedRes.getInt("sequence") == 1) { "Initial schedule sequence must be 1" }
            val scheduledJobId = schedRes.getString("job_id")
            if(cold) {
                output.putString("job_id",scheduledJobId); output.putLong("release_ms",releaseEpoch)
                output.putInt("claims_before",test.targetContext.getSharedPreferences("dansheng-mutations-v1",0).all.size)
                return
            }

            setStep("wait_native_worker_preload")
            var jobStatus = runtime.request(
                "jobs.status",
                JSONObject().put("job_id", scheduledJobId)
            ) as JSONObject
            val deadline = System.currentTimeMillis() + 25_000L
            while (jobStatus.getString("state") in listOf("scheduled", "running") && System.currentTimeMillis() < deadline) {
                Thread.sleep(100)
                jobStatus = runtime.request(
                    "jobs.status",
                    JSONObject().put("job_id", scheduledJobId)
                ) as JSONObject
            }
            check(jobStatus.getString("state") == "succeeded") {
                "Preload job did not succeed: ${jobStatus.optString("state")}"
            }
            check(jobStatus.getJSONObject("result").getString("status") == "preloaded")

            setStep("verify_continuation_sequence_2")
            val jobsList = runtime.request("jobs.status") as JSONArray
            val continuation = (0 until jobsList.length()).map { jobsList.getJSONObject(it) }.single {
                it.getString("id") != scheduledJobId &&
                it.getJSONObject("data").optString("plugin_id") == staged.pluginId &&
                it.getJSONObject("data").optString("action") == "tick" &&
                it.getJSONObject("data").optJSONObject("input")?.optString("task_id") == taskId
            }
            check(continuation.getString("state") == "scheduled")
            check(continuation.getJSONObject("data").getJSONObject("input").getInt("sequence") == 2)

            setStep("unauthorized_write_zero_posts")
            evaluateInPage(test, "window.fixtureCalls = [];")
            val unauthorizedInput = JSONObject().put("account_id", ACCOUNT).put("appointment_id", 31)
            val unauthRes = runCatching {
                runtime.request(
                    "plugins.run",
                    JSONObject()
                        .put("plugin_id", staged.pluginId)
                        .put("action", "cancelAppointment")
                        .put("input", unauthorizedInput)
                )
            }
            check(unauthRes.isFailure) { "Unauthorized form must fail without prior consent" }
            val zeroPosts = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(zeroPosts == 0) { "Unauthorized form must send exactly zero POSTs, got: $zeroPosts" }

            setStep("valid_write_once")
            val approvedInput = (runtime.request("plugins.run",JSONObject().put("plugin_id",staged.pluginId)
                .put("action","prepareCancelAppointment").put("input",JSONObject().put("account_id",ACCOUNT).put("appointment_id",30))) as JSONObject).getJSONObject("canonical_input")
            val cancelPreview = runtime.request(
                "actions.preview",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "cancelAppointment")
                    .put("input", approvedInput)
            ) as JSONObject
            val cancelHash = cancelPreview.getString("input_sha256")
            runtime.recordConsent(staged.pluginId, "cancelAppointment", approvedInput, cancelHash)

            val cancelRes = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "cancelAppointment")
                    .put("input", approvedInput)
            ) as JSONObject
            check(cancelRes.getString("status") == "cancelled")
            check(cancelRes.getInt("appointment_id") == 30)

            val writePosts = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST' && c.url.includes('cancel-appointment')).length").toInt()
            check(writePosts == 1) { "Valid write must send exactly 1 form POST, got: $writePosts" }
            setStep("scheduled_reservation")
            val end = releaseEpoch + 14000L
            val childArgs=JSONObject().put("job_id",continuation.getString("id"))
            var child=runtime.request("jobs.status",childArgs) as JSONObject
            while(child.optString("state") in listOf("running","scheduled") && System.currentTimeMillis()<end) {
                Thread.sleep(130); child=runtime.request("jobs.status",childArgs) as JSONObject
            }
            check(child.optString("state")=="succeeded" && child.optJSONObject("result")?.optString("status")=="completed")
            val launches=evaluateInPage(test,"window.fixtureCalls.filter(c=>c.method==='POST' && c.url.includes('/resource/launch')).length").toInt()
            check(launches==1); output.putInt("launch_posts",launches)

            setStep("stop_task")
            val stopRes = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "stop")
                    .put("input", JSONObject().put("account_id", ACCOUNT).put("task_id", taskId))
            ) as JSONObject
            check(stopRes.getString("status") == "stopped")

            output.putString("sports", "passed")
        } finally {
            if(!cold) teardown(test, runtime, activity, staged) else {
                runtime.attach(null); test.runOnMainSync { activity.finish() }; staged.stagedDir.deleteRecursively()
            }
        }
    }

    private fun runSportsLoss(
        test: Instrumentation,
        runtime: RuntimeHost,
        output: Bundle,
        setStep: (String) -> Unit
    ) {
        setStep("staging_package")
        val staged = stagePackage(test)

        setStep("runtime_onboarding")
        runtime.setAccount(ACCOUNT)
        runtime.request(
            "accounts.upsert",
            JSONObject().put("account_id", ACCOUNT).put("label", "Synthetic Sports Account")
        )

        setStep("plugin_install")
        val existing = runtime.request("plugins.list") as JSONArray
        val isInstalled = (0 until existing.length()).any {
            existing.getJSONObject(it).getString("id") == staged.pluginId
        }
        if (!isInstalled) {
            runtime.request(
                "plugins.install",
                JSONObject().put("path", staged.pkgDir.absolutePath)
            )
        }

        setStep("bind_package")
        runtime.bindPackage(staged.pluginId, staged.manifest, staged.policy, staged.zipHash)

        setStep("core_grant_and_enable")
        runtime.request(
            "permissions.set",
            JSONObject().put("subject", "plugin:" + staged.pluginId).put(
                "grant",
                JSONObject()
                    .put("account_ids", JSONArray().put(ACCOUNT))
                    .put("origins", staged.manifest.getJSONArray("network"))
                    .put("capabilities", staged.manifest.getJSONArray("capabilities"))
            )
        )
        runtime.request("plugins.enable", JSONObject().put("plugin_id", staged.pluginId))
        runtime.activate(staged.pluginId)

        setStep("attach_activity")
        val intent = Intent(test.targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val activity = foregroundActivity(test,intent)
        runtime.attach(activity)

        try {
            setStep("identity_match_login")
            OfflineApplication.setSyntheticIdentity(ACCOUNT)
            val matchFuture = CompletableFuture<Result<Any?>>()
            Thread {
                try {
                    val res = runtime.request(
                        "plugins.run",
                        JSONObject()
                            .put("plugin_id", staged.pluginId)
                            .put("action", "visibleLogin")
                            .put("input", JSONObject().put("account_id", ACCOUNT))
                    )
                    matchFuture.complete(Result.success(res))
                } catch (t: Throwable) {
                    matchFuture.complete(Result.failure(t))
                }
            }.start()

            clickConfirmWhenReady(test, matchFuture)
            val matchResult = matchFuture.get(15, TimeUnit.SECONDS)
            check(matchResult.isSuccess) { "Login must succeed" }

            setStep("simulated_loss_write")
            val planTaskId="stop-loss-"+UUID.randomUUID().toString().take(8)
            val parked=JSONObject().put("account_id",ACCOUNT).put("task_id",planTaskId).put("venue_id",900)
                .put("target_date","2099-01-04").put("release_at",Instant.now().plusSeconds(3600).toString())
                .put("plans",JSONArray().put(JSONObject().put("time","10:00-11:00").put("period_id",71).put("courts",JSONArray().put(901))))
            val parkedJob=(runtime.request("plugins.run",JSONObject().put("plugin_id",staged.pluginId).put("action","schedule").put("input",parked)) as JSONObject).getString("job_id")
            evaluateInPage(test, "window.fixtureCalls = []; window.fixtureNextWriteError = true;")
            val cancelLossInput = JSONObject().put("account_id", ACCOUNT).put("appointment_id", 31)

            val preview = runtime.request(
                "actions.preview",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "cancelAppointment")
                    .put("input", cancelLossInput)
            ) as JSONObject
            val previewHash = preview.getString("input_sha256")
            runtime.recordConsent(staged.pluginId, "cancelAppointment", cancelLossInput, previewHash)

            val lossResult = runCatching {
                runtime.request(
                    "plugins.run",
                    JSONObject()
                        .put("plugin_id", staged.pluginId)
                        .put("action", "cancelAppointment")
                        .put("input", cancelLossInput)
                )
            }
            val err = lossResult.exceptionOrNull()
            check(err is PortError && err.code == "NeedsReconciliation") {
                "Expected NeedsReconciliation, got: $err"
            }

            setStep("verify_needs_reconciliation_fence")
            val allJobs = runtime.request("jobs.status") as JSONArray
            val unknown = (0 until allJobs.length()).map { allJobs.getJSONObject(it) }.firstOrNull {
                it.getJSONObject("data").optString("action") == "cancelAppointment" &&
                it.getJSONObject("data").optJSONObject("input")?.optInt("appointment_id") == 31
            }
            checkNotNull(unknown) { "Expected uncertain job in jobs.status" }
            output.putString("uncertain_job",unknown.getString("id"))
            check(unknown.getString("state") == "needs_reconciliation") {
                "Expected needs_reconciliation state, got: ${unknown.getString("state")}"
            }

            val cancelAttempt = runCatching {
                runtime.request("jobs.cancel", JSONObject().put("job_id", unknown.getString("id")))
            }
            val cancelErr = cancelAttempt.exceptionOrNull()
            check(cancelErr is PortError && cancelErr.code == "NeedsReconciliation") {
                "Cancelling an uncertain job must fail with NeedsReconciliation, got: $cancelErr"
            }

            setStep("duplicate_write_no_second_post")
            val countBefore = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(countBefore == 1) { "Expected exactly 1 failed POST before duplicate attempt, got: $countBefore" }

            val duplicateResult = runCatching {
                runtime.request(
                    "plugins.run",
                    JSONObject()
                        .put("plugin_id", staged.pluginId)
                        .put("action", "cancelAppointment")
                        .put("input", cancelLossInput)
                )
            }
            val dupErr = duplicateResult.exceptionOrNull()
            check(dupErr is PortError && dupErr.code == "NeedsReconciliation") {
                "Duplicate call must fail with NeedsReconciliation, got: $dupErr"
            }

            val countAfterDup = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(countAfterDup == countBefore) {
                "Duplicate delivery must NOT send a second POST, count went from $countBefore to $countAfterDup"
            }

            setStep("blocked_write_no_second_post")
            val blockedInput = JSONObject().put("account_id", ACCOUNT).put("appointment_id", 32)
            val blockedResult = runCatching {
                runtime.request(
                    "plugins.run",
                    JSONObject()
                        .put("plugin_id", staged.pluginId)
                        .put("action", "cancelAppointment")
                        .put("input", blockedInput)
                )
            }
            val blockedErr = blockedResult.exceptionOrNull()
            check(blockedErr is PortError) {
                "Write while uncertain job exists must fail, got: $blockedErr"
            }

            val countAfterBlocked = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(countAfterBlocked == countBefore) {
                "Blocked write must NOT send POST, count went from $countBefore to $countAfterBlocked"
            }

            setStep("stop_task_no_second_post")
            val stopped=runtime.request("plugins.run", JSONObject().put("plugin_id",staged.pluginId).put("action","stop")
                .put("input",JSONObject().put("account_id",ACCOUNT).put("task_id",planTaskId))) as JSONObject
            check(stopped.getString("status")=="stopped")
            check((runtime.request("jobs.status",JSONObject().put("job_id",parkedJob)) as JSONObject).getString("state")=="cancelled")
            val countAfterStop = evaluateInPage(test, "window.fixtureCalls.filter(c => c.method === 'POST').length").toIntOrNull() ?: 0
            check(countAfterStop == countBefore) {
                "Stop must NOT send a POST, count went from $countBefore to $countAfterStop"
            }

            setStep("read_after_loss")
            val readAppts = runtime.request(
                "plugins.run",
                JSONObject()
                    .put("plugin_id", staged.pluginId)
                    .put("action", "appointments")
                    .put("input", JSONObject().put("account_id", ACCOUNT))
            ) as JSONArray
            check(readAppts.length() > 0) { "Appointments query must still succeed after loss" }

            output.putString("sportsLoss", "passed")
        } finally {
            teardown(test, runtime, activity, staged)
        }
    }

    private fun foregroundActivity(test:Instrumentation,intent:Intent):MainActivity {
        val activity=test.startActivitySync(intent) as MainActivity
        val until=android.os.SystemClock.elapsedRealtime()+90_000
        while(android.os.SystemClock.elapsedRealtime()<until) {
            var ready=false
            test.runOnMainSync { ready=activity.hasWindowFocus() && activity.window.decorView.isShown && !activity.isFinishing }
            if(ready)return activity
            Thread.sleep(100)
        }
        error("Product Activity did not receive foreground window focus")
    }

    /** For a recognized package the open dialog verifies by itself and may close before any click. */
    private fun clickConfirmWhenReady(test: Instrumentation, login: CompletableFuture<*>, timeoutMs: Long = 40_000L) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var clicked = false
        while (!clicked && !login.isDone && System.currentTimeMillis() < deadline) {
            val latch = CountDownLatch(1)
            test.runOnMainSync {
                val wv = OfflineApplication.lastLoadedWebView
                if (wv != null && wv.url != null) {
                    wv.evaluateJavascript("typeof window.fixtureIdentity !== 'undefined'") { ready ->
                        if (ready == "true") {
                            var current: View? = wv
                            while (current?.parent is View) {
                                current = current.parent as View
                            }
                            val btn = findConfirmButton(current) ?: findConfirmButton(wv.parent as? View)
                            if (btn != null) {
                                btn.performClick()
                                clicked = true
                            }
                        }
                        latch.countDown()
                    }
                } else {
                    latch.countDown()
                }
            }
            latch.await(1, TimeUnit.SECONDS)
            if (!clicked) Thread.sleep(60)
        }
        check(clicked || login.isDone) { "Login neither finished nor offered the native confirm button ('验证登录') within ${timeoutMs}ms" }
    }

    private fun findConfirmButton(view: View?): Button? {
        if (view == null) return null
        if (view is Button && (view.text == "验证登录" || view.text == "确认")) {
            return view
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findConfirmButton(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
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
        runtime: RuntimeHost,
        activity: MainActivity,
        staged: StagedPackage
    ) {
        try {
            runtime.attach(null)
            test.runOnMainSync {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    activity.finish()
                }
            }
        } catch (_: Throwable) {}

        try {
            val cleared = CountDownLatch(1)
            runtime.browserPort.logout(ACCOUNT) { cleared.countDown() }
            cleared.await(5, TimeUnit.SECONDS)
        } catch (_: Throwable) {}

        try {
            staged.stagedDir.deleteRecursively()
        } catch (_: Throwable) {}
    }
}
