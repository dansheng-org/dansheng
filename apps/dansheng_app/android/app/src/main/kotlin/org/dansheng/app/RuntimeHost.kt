// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.app.Activity
import android.content.Context
import android.os.Looper
import org.dansheng.android.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class RuntimeHost(private val context: Context, browserIsolated:Boolean=true, pageFactory:(GrantGate)->VisiblePage = ::VisiblePage) : AutoCloseable {
    internal val prefs = context.getSharedPreferences("dansheng-app-state-v1", Context.MODE_PRIVATE)
    @Volatile private var activeAccount: String? = prefs.getString("active_account", null)

    val notifications = Notifications(context) { account() }
    val grantGate = GrantGate(context) { account() }
    val visiblePage = pageFactory(grantGate)
    val wakePort = AndroidWakePort(context.applicationContext)
    val vault = KeystoreVault(context)
    internal val powerAlerts=PowerAlerts(context,this)
    internal val authGuard = Any()
    @Volatile internal var accountEpoch = 0L
        private set
    internal val campusLogins = CampusLogins(this)
    init { visiblePage.attachVenueCredentials(campusLogins::savedUisForVenue,campusLogins::canRestoreVenue,
        campusLogins::suspendVenuePassword,campusLogins::clearVenueSuspension,campusLogins::venueAccountActive) }

    val browserPort = WebViewBrowserPort(context, visiblePage, grantGate.mutationAuthorizer,grantGate::sharedVenueSession)
    internal val browserDispatcher = VenueWriteBoundary(BrowserDispatcher(browserPort)) { request("jobs.status") as JSONArray }

    private val engineRef = AtomicLong(0L)
    private val engineLock = Any()
    private var platformPump: PlatformPump? = null
    @Volatile private var nativeLoaded = false

    private val resolverProxy = object : JobBindingResolver {
        override fun resolve(jobId: String, reply: (Result<CoreJobBinding>) -> Unit) {
            wakeHost.resolve(jobId, reply)
        }
    }

    private val jobWakeDispatcher = JobWakeDispatcher(context, resolverProxy)
    val compositeDispatcher = if(browserIsolated) CompositeDispatcher(browserDispatcher, vault, jobWakeDispatcher, notifications)
        else CompositeDispatcher(vault,jobWakeDispatcher,notifications)

    private val nativeJobClient = NativeCoreJobClient(::openOrGetEngine)

    val wakeHost = CoreJobWakeHost(
        client = nativeJobClient,
        accountNow = { account() },
        permissionNow = { spec -> grantGate.isWakeAuthorized(spec) },
        onResumeRequired = { spec, reason ->
            prefs.edit().putString("resume:"+spec.jobId,reason).apply()
            notifications.notifyResumeRequired(spec, reason)
        }
    )

    fun initializeOnCreate() {
        notifications.ensureChannels()
        wakeHost.prepareSession={spec,ready->
            val owner="plugin:"+OfficialSports.id
            val account=spec.account
            if(spec.owner!=owner || account==null || !grantGate.trustedVenueLogin(owner) || !campusLogins.canRestoreVenue(account))ready()
            else Thread({
                try {
                    if(grantGate.isWakeAuthorized(spec) && System.currentTimeMillis()<spec.deadline)
                        visiblePage.withoutPrompt(account){
                            request("plugins.run", JSONObject().put("plugin_id",OfficialSports.id).put("action","visibleLogin")
                                .put("input",JSONObject().put("account_id",account)))
                        }
                } catch (_:Exception) {
                    // The real tick still checks its own session and reports waiting_for_auth.
                } finally { ready() }
            },"venue-session-prepare").start()
        }
        // Register execution port for alarm and background wake delivery immediately
        AndroidRuntime.execution = wakeHost
        Thread({try{powerAlerts.restore()}catch(_:Exception){}}, "electricity-alert-restore").start()
    }

    fun ensureNativeLoaded(): Boolean {
        if (nativeLoaded) return true
        return synchronized(engineLock) {
            if (nativeLoaded) return true
            try {
                NativeCore.load()
                nativeLoaded = true
                true
            } catch (_: Throwable) {
                false
            }
        }
    }

    fun openOrGetEngine(reply: (Result<Long>) -> Unit) {
        val current = engineRef.get()
        if (current > 0L) {
            reply(Result.success(current))
            return
        }
        synchronized(engineLock) {
            val recheck = engineRef.get()
            if (recheck > 0L) {
                reply(Result.success(recheck))
                return
            }
            try {
                if (!ensureNativeLoaded()) {
                    reply(Result.failure(PortError("NativeLibraryUnavailable")))
                    return
                }
                val coreDir = File(context.filesDir, "core").apply { mkdirs() }
                val options = JSONObject()
                    .put("data_dir", coreDir.absolutePath)
                    .put("platform_capabilities", JSONArray(compositeDispatcher.capabilities.toList()))
                val op = NativeCore.open(options.toString().toByteArray(Charsets.UTF_8))
                val deadline = System.currentTimeMillis() + 15_000L
                var responseBytes: ByteArray? = null
                while (System.currentTimeMillis() < deadline) {
                    responseBytes = NativeCore.poll(op)
                    if (responseBytes != null) break
                    Thread.sleep(10)
                }
                if (responseBytes == null) {
                    NativeCore.cancel(op)
                    reply(Result.failure(PortError("NativeCoreOpenTimeout")))
                    return
                }
                val opened = JSONObject(responseBytes.toString(Charsets.UTF_8))
                if (opened.has("error")) {
                    reply(Result.failure(PortError(opened.getJSONObject("error").optString("code", "CoreOpenFailed"))))
                    return
                }
                val engine = opened.getJSONObject("result").getLong("engine")
                engineRef.set(engine)
                val pump = PlatformPump(engine, compositeDispatcher)
                platformPump = pump
                pump.start()
                reply(Result.success(engine))
            } catch (e: Exception) {
                reply(Result.failure(if (e is PortError) e else PortError("CoreOpenFailed")))
            }
        }
    }

    fun getOrOpenEngineBlocking(): Long {
        val current = engineRef.get()
        if (current > 0L) return current
        var result: Result<Long>? = null
        val latch = CountDownLatch(1)
        openOrGetEngine { res ->
            result = res
            latch.countDown()
        }
        latch.await(20, TimeUnit.SECONDS)
        return result?.getOrThrow() ?: throw PortError("CoreUnavailable")
    }

    /**
     * Public boundary for other worker:
     * Blocking request to Core engine. Only callable off main thread.
     * Returns actual result value (e.g. JSONArray, JSONObject, Boolean) or null.
     * Throws sanitized failures.
     */
    fun request(method: String, params: JSONObject = JSONObject()): Any? {
        if(method.startsWith("fudan.") || method.startsWith("community.") || method.startsWith("canvas.")) ensureCampusNetwork()
        try { return callCore(method,params) } catch(e:PortError) {
            if(method!="plugins.run" || e.code!="JobNotRunnable")throw e
            // An explicit invocation after login/approval may refer to the
            // existing job. Only resume an identical, immediate owner action.
            val rows=callCore("jobs.status",JSONObject()) as JSONArray
            val input=PortUtils.canonicalJson(params.optJSONObject("input") ?: JSONObject())
            val match=(0 until rows.length()).map { rows.getJSONObject(it) }.singleOrNull { job->
                val data=job.optJSONObject("data")
                job.optJSONObject("owner")?.optString("kind")=="owner" &&
                    job.optString("state") in setOf("waiting_for_auth","waiting_for_approval") &&
                    data!=null && !data.has("deadline_at") && data.optString("plugin_id")==params.optString("plugin_id") &&
                    data.optString("action")==params.optString("action") && PortUtils.canonicalJson(data.opt("input"))==input
            } ?: throw e
            val key=JSONObject().put("job_id",match.getString("id"))
            callCore("jobs.resume",key)
            val until=android.os.SystemClock.elapsedRealtime()+58_000
            while(android.os.SystemClock.elapsedRealtime()<until) {
                val job=callCore("jobs.status",key) as JSONObject
                when(job.getString("state")){
                    "succeeded"->return job.opt("result")?.takeUnless { it===JSONObject.NULL }
                    "running","scheduled"->Thread.sleep(150)
                    else->throw PortError(job.optJSONObject("result")?.optJSONObject("error")?.optString("code") ?: "JobNotRunnable")
                }
            }
            throw PortError("DeadlineExceeded")
        }
    }
    @Volatile private var networkConfigured=false
    private val networkConfigLock=Any()
    private fun ensureCampusNetwork() {
        if(networkConfigured)return
        synchronized(networkConfigLock) {
            if(networkConfigured)return
            val origins=listOf("auth.fduhole.com","forum.fduhole.com","danke.fduhole.com","elearning.fudan.edu.cn",
                "fdjwgl.fudan.edu.cn","ecard.fudan.edu.cn","zlapp.fudan.edu.cn","webvpn.fudan.edu.cn",
                "my.fudan.edu.cn","mlibrary.fudan.edu.cn").map { "https://$it" }
            callCore("http.policy.set",JSONObject().put("private_network_origins",JSONArray(origins)))
            networkConfigured=true
        }
    }
    private fun callCore(method: String, params: JSONObject): Any? {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw PortError("BlockingCallOnMainThread")
        }

        val engine = getOrOpenEngineBlocking()
        val id = UUID.randomUUID().toString()
        val requestBytes = JSONObject()
            .put("id", id)
            .put("method", method)
            .put("params", params)
            .toString()
            .toByteArray(Charsets.UTF_8)

        val op = NativeCore.request(engine, requestBytes)
        // Visible SSO may take up to 50 s and the native card connector has a
        // 45 s exchange deadline. Do not abandon either operation at 30 s.
        val bulkRead=method in setOf("fudan.ecard.statement","fudan.ecard.statistics","fudan.electricity.statistics")
        val deadline = System.currentTimeMillis() + if(bulkRead)180_000L else 58_000L
        var responseBytes: ByteArray? = null
        try { while (System.currentTimeMillis() < deadline) {
            responseBytes = NativeCore.poll(op)
            if (responseBytes != null) break
            Thread.sleep(10)
        }}catch(_:InterruptedException){
            NativeCore.cancel(op)
            val until=System.currentTimeMillis()+3000
            while(System.currentTimeMillis()<until){if(NativeCore.poll(op)!=null)break;Thread.sleep(10)}
            throw PortError("Cancelled")
        }

        if (responseBytes == null) {
            NativeCore.cancel(op)
            // Collect/drain cancelled operation to prevent leaking operations in Core
            val drainDeadline = System.currentTimeMillis() + 3000L
            while (System.currentTimeMillis() < drainDeadline) {
                if (NativeCore.poll(op) != null) break
                Thread.sleep(10)
            }
            throw PortError("DeadlineExceeded")
        }

        val responseJson = try {
            JSONObject(responseBytes.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            throw PortError("InvalidCoreResponse")
        }

        if (responseJson.has("error")) {
            val err = responseJson.getJSONObject("error")
            val code = err.optString("code", "CoreError")
            throw PortError(code)
        }

        if (!responseJson.has("result") || responseJson.isNull("result")) {
            return null
        }

        val res = responseJson.get("result")
        return if (res === JSONObject.NULL) null else res
    }

    fun attach(activity: Activity?) {
        visiblePage.attach(activity)
    }

    fun setAccount(account: String):Unit = synchronized(authGuard) {
        val sanitized = account.trim()
        if (sanitized.isNotEmpty() && !sanitized.matches(Regex("^[A-Za-z0-9_.:@-]{1,128}$"))) {
            throw PortError("InvalidAccount")
        }
        val previous = activeAccount
        if (previous == sanitized) return
        accountEpoch++
        campusLogins.accountChanged(previous,sanitized.isEmpty())
        CampusAgent.accountChanged()

        if (previous != null) {
            val latch = CountDownLatch(1)
            browserPort.logout(previous) { latch.countDown() }
            wakePort.cancelAccount(previous)
            if(!latch.await(10, TimeUnit.SECONDS)) throw PortError("AccountCleanupPending")
            request("auth.logout",JSONObject().put("account_id",previous))
            val readerRoot=File(context.cacheDir,"course-reader").canonicalFile
            val oldFiles=File(readerRoot,PortUtils.sha256(previous.toByteArray(Charsets.UTF_8))).canonicalFile
            if(oldFiles.parentFile==readerRoot && oldFiles.isDirectory) {
                oldFiles.walkTopDown().filter{it.isFile}.forEach { f->
                    val uri=androidx.core.content.FileProvider.getUriForFile(context,context.packageName+".coursefiles",f)
                    context.revokeUriPermission(uri,android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                if(!oldFiles.deleteRecursively())throw PortError("AccountCleanupPending")
            }
        }

        if(sanitized.isEmpty()) {
            check(prefs.edit().remove("active_account").commit()); activeAccount=null; powerAlerts.cancel(); return
        }
        request("accounts.upsert", JSONObject().put("account_id", sanitized).put("label", sanitized))
        check(prefs.edit().putString("active_account", sanitized).commit())
        activeAccount = sanitized
        powerAlerts.cancel()
        powerAlerts.restore()
    }

    fun account(): String? = activeAccount

    private val repairing = java.util.concurrent.atomic.AtomicBoolean(false)
    private val visited = java.util.concurrent.atomic.AtomicBoolean(false)
    fun onForeground() {
        val exact = wakePort.capabilities().optBoolean("exact_available")
        val changed = exact != prefs.getBoolean("last_exact",false)
        if (!visited.compareAndSet(false,true) && !changed) return
        if (!repairing.compareAndSet(false,true)) return
        Thread {
            try {
                // Rebind future persisted jobs after force-stop or an exact-permission change.
                // Never reclaim executed/missed generations or start a service here.
                val jobs=request("jobs.status") as JSONArray
                for (index in 0 until jobs.length()) {
                    val job=jobs.getJSONObject(index); if(job.optString("state")!="scheduled") continue
                    val data=job.optJSONObject("data") ?: continue
                    val owner=job.getJSONObject("owner").getString("id")
                    val id=job.getString("id")
                    if(wakePort.load(id)?.let(wakePort::claimed)==true) continue
                    val account=data.optJSONObject("input")?.optString("account_id")?.takeIf { it.isNotEmpty() }
                        ?: data.optString("account_id").takeIf { it.isNotEmpty() && it!="null" } ?: continue
                    val at=job.getString("run_at")
                    val prepare=data.optString("prepare_at",at)
                    val deadline=data.optString("deadline_at").takeIf { it.isNotBlank() } ?: continue
                    val stamp:(String)->Long={ java.time.OffsetDateTime.parse(it).toInstant().toEpochMilli() }
                    if(stamp(prepare)<=System.currentTimeMillis() || account!=activeAccount) continue
                    val precision=data.optString("wake_precision",if(data.has("prepare_at")) "exact" else "inexact")
                    if(precision=="exact" && !exact)continue
                    val spec=WakeSpec(id,account,owner,stamp(prepare),stamp(deadline),executeAt=stamp(at),precision=precision)
                    if(!grantGate.isWakeAuthorized(spec)) continue
                    if(owner!="owner"){
                        val grant=request("permissions.get",JSONObject().put("subject",owner)) as JSONObject
                        if(grant.optJSONArray("capabilities")?.let { caps->(0 until caps.length()).any{caps.optString(it)=="jobs.schedule"} }!=true)continue
                        if(grant.optJSONArray("account_ids")?.let { accounts->(0 until accounts.length()).any{accounts.optString(it)==account} }!=true)continue
                        val expires=grant.optString("expires_at"); if(expires.isNotBlank() && expires!="null" && stamp(expires)<=System.currentTimeMillis())continue
                    }
                    // Core may cancel while the foreground scan is running.
                    val current=request("jobs.status",JSONObject().put("job_id",id)) as JSONObject
                    if(current.optString("state")=="scheduled" && wakePort.load(id)?.let(wakePort::claimed)!=true) {
                        if(!wakePort.rearmIfUnclaimed(spec)) continue
                        val after=request("jobs.status",JSONObject().put("job_id",id)) as JSONObject
                        if(after.optString("state")=="cancelled")wakePort.cancel(id,owner)
                    }
                }
                prefs.edit().putBoolean("last_exact",exact).apply()
            } catch (_:Exception) { visited.set(false) } finally { repairing.set(false) }
        }.start()
    }

    fun permissions(): JSONObject {
        val wakeCaps = wakePort.capabilities()
        return JSONObject()
            .put("exact_available", wakeCaps.optBoolean("exact_available", false))
            .put("exact_alarm_requires_visible_ui", wakeCaps.optBoolean("exact_permission_requires_visible_ui", false))
            .put("notifications_available", notifications.areNotificationsEnabled())
            .put("notifications_runtime_required", notifications.isRuntimePermissionRequired())
            .put("capabilities", wakeCaps)
    }

    /**
     * Binds package after Core install.
     * archiveHash: Verified full SHA-256 digest from independent expected source.
     * null policy clears prior policy (unprivileged package without browser mutation policy).
     */
    fun bindPackage(pluginId: String, manifest: JSONObject, policy: JSONObject?, archiveHash: String) {
        grantGate.bindPackage(pluginId, manifest, policy, archiveHash)
    }

    fun activate(pluginId: String) {
        grantGate.activate(pluginId)
    }

    fun recordConsent(pluginId: String, action: String, input: JSONObject, hash: String) {
        grantGate.recordConsent(pluginId, action, input, hash)
    }

    fun revoke(pluginId: String) {
        grantGate.revoke(pluginId)
        browserPort.releasePrincipal("plugin:"+pluginId)
        val specs = wakePort.all().filter { it.owner == "plugin:$pluginId" || it.owner == pluginId }
        for (spec in specs) {
            try {
                wakePort.cancel(spec.jobId, spec.owner)
            } catch (_: Exception) {}
        }
    }

    fun subscriptions(): JSONArray {
        val array = JSONArray()
        for (spec in wakePort.all()) {
            val item = JSONObject()
                .put("job_id", spec.jobId)
                .put("account_id", spec.account ?: JSONObject.NULL)
                .put("owner", spec.owner)
                .put("run_at", spec.runAt)
                .put("execute_at", spec.executeAt)
                .put("deadline", spec.deadline)
                .put("generation", spec.generation)
                .put("precision", spec.precision)
                .put("claimed", wakePort.claimed(spec))
                .put("resume_reason",prefs.getString("resume:"+spec.jobId,null))
                .put("scheduled", !wakePort.claimed(spec) && System.currentTimeMillis() < spec.deadline &&
                    (spec.precision != "exact" || wakePort.capabilities().optBoolean("exact_available")))
            array.put(item)
        }
        return array
    }

    override fun close() {
        CampusAgent.accountChanged()
        platformPump?.close()
        platformPump = null
        wakeHost.close()
        nativeJobClient.close()
        val engine = engineRef.getAndSet(0L)
        if (engine > 0L && nativeLoaded) {
            try {
                val op = NativeCore.close(engine)
                val end = System.currentTimeMillis() + 3000L
                while (System.currentTimeMillis() < end) {
                    if (NativeCore.poll(op) != null) break
                    Thread.sleep(10)
                }
            } catch (_: Exception) {}
        }
    }
}
