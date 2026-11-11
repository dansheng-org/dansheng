// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.content.Intent
import android.test.InstrumentationTestCase
import org.dansheng.android.*
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Compiled only when -PrustJniDir is supplied. Never silently passes an absent native library. */
@Suppress("DEPRECATION")
class NativeAbiInstrumentationTest : InstrumentationTestCase() {
    private fun await(op: Long): JSONObject {
        val end = System.currentTimeMillis() + 10000
        while (System.currentTimeMillis() < end) {
            NativeCore.poll(op)?.let { return JSONObject(it.toString(Charsets.UTF_8)) }
            Thread.sleep(10)
        }
        fail("native operation exceeded test deadline"); throw IllegalStateException()
    }
    fun testNativeOpenRequestPlatformPumpAndClose() {
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, FixtureActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as FixtureActivity
        NativeCore.load()
        val options = JSONObject().put("data_dir", activity.filesDir.resolve("native-test-" + UUID.randomUUID()).absolutePath)
            .put("platform_capabilities", org.json.JSONArray().put("browser.evaluate"))
        val opened = await(NativeCore.open(options.toString().toByteArray(Charsets.UTF_8)))
        assertFalse(opened.has("error"))
        val engine = opened.getJSONObject("result").getLong("engine")
        val pump = PlatformPump(engine, BrowserDispatcher(activity.browser)); pump.start()
        try {
            val info = await(NativeCore.request(engine, "{\"id\":\"fixture-info\",\"method\":\"core.info\",\"params\":{}}".toByteArray()))
            assertEquals("dansheng-core", info.getJSONObject("result").getString("name"))
            val request = JSONObject().put("id", "fixture-browser").put("method", "browser.evaluate")
                .put("params", JSONObject().put("operation", "session.status").put("account_id", "fixture-a").put("url", "https://fixture.invalid/"))
            val response = await(NativeCore.request(engine, request.toString().toByteArray(Charsets.UTF_8)))
            assertFalse(response.has("error")); assertEquals("fixture-browser", response.getString("id"))
            assertFalse(response.getJSONObject("result").getBoolean("authenticated"))
        } finally {
            pump.close()
            val closed = await(NativeCore.close(engine))
            assertTrue(closed.getJSONObject("result").getBoolean("closed"))
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
    fun testQuickJsSportsPluginThroughJniAndSyntheticAuthenticatedPage() {
        sportsScenario(false)
    }
    fun testOwnerSportsCreatePreloadAndDeferredContinuationWithoutPluginSelfGrants() {
        sportsScenario(true)
    }
    fun testSportsSyntheticPostRequiresDeclaredAndGrantedBrowserWrite() {
        sportsScenario(false, syntheticWrite = true)
    }
    fun testRustScheduleArmsRealWakeAndNativeWorkerRunsThenCancels() {
        sportsScenario(true, wakeBridge = true)
    }
    fun testOriginalSportsPackagePairedFetchStorageSourcesAndUi() {
        sportsScenario(false, pairedPackage = true)
    }
    fun testPluginStorageMigrationRestartRollbackAndSnapshotRestoreThroughJni() {
        // No browser/platform port: every value and package is synthetic and app-private.
        val root = instrumentation.targetContext.filesDir.resolve("storage-fixture-" + UUID.randomUUID()).apply { mkdirs() }
        val packageDir = root.resolve("package").apply { mkdirs() }
        val pluginId = "fixture_android_storage"
        val plugin = JSONObject().put("plugin_id", pluginId)
        val options = JSONObject().put("data_dir", root.resolve("core").absolutePath).toString().toByteArray(Charsets.UTF_8)
        NativeCore.load()
        fun open(): Long {
            val response = await(NativeCore.open(options))
            assertFalse("storage fixture open failed", response.has("error"))
            return response.getJSONObject("result").getLong("engine")
        }
        var engine = open()
        fun raw(method: String, params: JSONObject = plugin): JSONObject = await(NativeCore.request(engine,
            JSONObject().put("id", method).put("method", method).put("params", params).toString().toByteArray(Charsets.UTF_8)))
        fun core(method: String, params: JSONObject = plugin): JSONObject {
            val response = raw(method, params)
            assertFalse("storage fixture $method: " + response.optJSONObject("error")?.optString("code"), response.has("error"))
            return response
        }
        fun run(account: String, key: String, value: Any? = null): Any {
            val input = JSONObject().put("account_id", account).put("key", key)
            if (value != null) input.put("value", value)
            return core("plugins.run", JSONObject().put("plugin_id", pluginId).put("action", "run").put("input", input)).get("result")
        }
        fun install(version: Int, schema: JSONObject? = null) {
            val manifest = JSONObject("""{"id":"$pluginId","name":"Synthetic Android storage","version":"$version.0.0","api_version":1,"entry":"main.js","capabilities":["storage.read","storage.write"],"network":[],"actions":{"run":{"description":"Synthetic private state","mutating":false}}}""")
            if (schema != null) manifest.put("storage_schema", schema)
            packageDir.resolve("manifest.json").writeText(manifest.toString())
            packageDir.resolve("main.js").writeText("""
                export async function run(ctx, input) {
                    if (Object.hasOwn(input, 'value')) await ctx.storage.set({key:input.key,value:input.value});
                    return await ctx.storage.get({key:input.key});
                }
            """.trimIndent())
            core("plugins.install", JSONObject().put("path", packageDir.absolutePath))
        }
        try {
            install(1)
            core("permissions.set", JSONObject().put("subject", "plugin:$pluginId").put("grant",
                JSONObject("""{"capabilities":["storage.read","storage.write"],"account_ids":["fixture-a","fixture-b"]}""")))
            assertEquals(0, core("plugins.enable").getJSONObject("result").getJSONObject("storage").getInt("version"))
            for (account in listOf("fixture-a", "fixture-b")) {
                run(account, "old", JSONObject().put("title", account).put("obsolete", true))
                run(account, "removed", "synthetic-discardable")
            }
            install(2, JSONObject("""{"version":1,"migrations":[{"from":0,"to":1,"operations":[
                {"op":"rename_key","from":"old","to":"current"},
                {"op":"patch_object","key":"current","rename_fields":{"title":"name"},"defaults":{"count":0},"remove_fields":["obsolete"]},
                {"op":"set_default","key":"settings","value":{"enabled":true}},
                {"op":"delete_key","key":"removed"}
            ]}]}"""))
            val migrated = core("plugins.enable").getJSONObject("result").getJSONObject("storage")
            assertEquals(0, migrated.getInt("from")); assertEquals(1, migrated.getInt("version"))
            val snapshot = migrated.getString("snapshot_id")
            assertTrue(snapshot.isNotEmpty())
            for (account in listOf("fixture-a", "fixture-b")) {
                assertEquals(JSONObject.NULL, run(account, "old"))
                assertEquals(JSONObject.NULL, run(account, "removed"))
                val current = run(account, "current") as JSONObject
                assertEquals(account, current.getString("name")); assertEquals(0, current.getInt("count"))
                assertFalse(current.has("title")); assertFalse(current.has("obsolete"))
                assertTrue((run(account, "settings") as JSONObject).getBoolean("enabled"))
            }
            run("fixture-a", "current", JSONObject().put("name", "synthetic-after-upgrade"))
            assertTrue(await(NativeCore.close(engine)).getJSONObject("result").getBoolean("closed"))
            engine = 0
            val sqliteHeader = ByteArray(16)
            root.resolve("core/dansheng.db").inputStream().use { assertEquals(16, it.read(sqliteHeader)) }
            assertEquals("SQLite format 3\u0000", sqliteHeader.toString(Charsets.US_ASCII))
            engine = open()
            assertTrue(core("plugins.enable").getJSONObject("result").getJSONObject("storage").isNull("snapshot_id"))
            assertEquals("synthetic-after-upgrade", (run("fixture-a", "current") as JSONObject).getString("name"))
            val persisted = core("plugins.storage.snapshots").getJSONObject("result")
            assertEquals(1, persisted.getInt("version"))
            val snapshots = persisted.getJSONArray("snapshots")
            assertEquals(1, snapshots.length())
            assertEquals(snapshot, snapshots.getJSONObject(0).getString("snapshot_id"))
            assertEquals(2, snapshots.getJSONObject(0).getInt("scopes"))
            assertEquals(4, snapshots.getJSONObject(0).getInt("entries"))
            assertEquals("1.0.0", core("plugins.rollback").getJSONObject("result").getString("version"))
            assertEquals("PluginStorageVersionMismatch", raw("plugins.enable").getJSONObject("error").getString("code"))
            val restored = core("plugins.storage.restore", JSONObject().put("plugin_id", pluginId).put("snapshot_id", snapshot)).getJSONObject("result")
            val reverse = restored.getString("recovery_snapshot_id")
            assertTrue(reverse.isNotEmpty()); assertFalse(snapshot == reverse)
            assertEquals(0, core("plugins.enable").getJSONObject("result").getJSONObject("storage").getInt("version"))
            for (account in listOf("fixture-a", "fixture-b")) {
                val old = run(account, "old") as JSONObject
                assertEquals(account, old.getString("title")); assertTrue(old.getBoolean("obsolete"))
                assertEquals("synthetic-discardable", run(account, "removed"))
                assertEquals(JSONObject.NULL, run(account, "current"))
                assertEquals(JSONObject.NULL, run(account, "settings"))
            }
            // Restore itself takes a recovery snapshot: recovering forward must
            // preserve the post-upgrade edit without merging the second account.
            assertEquals("2.0.0", core("plugins.rollback").getJSONObject("result").getString("version"))
            core("plugins.storage.restore", JSONObject().put("plugin_id", pluginId).put("snapshot_id", reverse))
            assertEquals(1, core("plugins.enable").getJSONObject("result").getJSONObject("storage").getInt("version"))
            assertEquals("synthetic-after-upgrade", (run("fixture-a", "current") as JSONObject).getString("name"))
            val second = run("fixture-b", "current") as JSONObject
            assertEquals("fixture-b", second.getString("name")); assertEquals(0, second.getInt("count"))
        } finally {
            if (engine != 0L) assertTrue(await(NativeCore.close(engine)).getJSONObject("result").getBoolean("closed"))
        }
    }
    private fun sportsScenario(continuations: Boolean, syntheticWrite: Boolean = false, wakeBridge: Boolean = false, pairedPackage: Boolean = false) {
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, FixtureActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as FixtureActivity
        val root = activity.filesDir.resolve("sports-fixture-" + UUID.randomUUID()).apply { mkdirs() }
        val manifest = JSONObject(activity.assets.open("fudan-sports/manifest.json").bufferedReader().use { it.readText() })
        val fixtureOrigin = manifest.getJSONArray("network").getString(0)
        // The trusted synthetic host grants this exact plugin/account/origin
        // access to the owner's fixture page. Production sharing defaults stay
        // in the adapter; plugin JSON cannot provide this host approval.
        instrumentation.runOnMainSync {
            activity.fixtureSharedReader = "plugin:" + manifest.getString("id")
            activity.fixtureSharedOrigin = fixtureOrigin
        }
        // The origin comes from typed plugin data. loadDataWithBaseURL + blockNetworkLoads
        // executes ONLY bundled fixture HTML; no request goes to the real school host.
        val loginDone = CountDownLatch(1); val loginResult = AtomicReference<Result<JSONObject>>()
        activity.browser.call("browser.login", activity.authority(), JSONObject().put("account_id", "fixture-a")
            .put("url", fixtureOrigin + "/")) { loginResult.set(it); loginDone.countDown() }
        if (continuations || pairedPackage) instrumentation.runOnMainSync { activity.allowFixtureWrites = false }
        val end = System.currentTimeMillis() + 5000
        var ready = false
        while (!ready && System.currentTimeMillis() < end) {
            val checked = CountDownLatch(1)
            instrumentation.runOnMainSync { activity.fixtureView?.evaluateJavascript("window.fixtureIdentity === 'fixture-a'") {
                ready = it == "true"; checked.countDown()
            } ?: checked.countDown() }
            checked.await(1, TimeUnit.SECONDS); if (!ready) Thread.sleep(25)
        }
        assertTrue(ready); instrumentation.runOnMainSync { activity.verifyLogin!!.invoke() }
        assertTrue(loginDone.await(5, TimeUnit.SECONDS)); loginResult.get().getOrThrow()
        val packageDir = root.resolve("package").apply { mkdirs() }
        for (file in activity.assets.list("fudan-sports")!!) {
            activity.assets.open("fudan-sports/$file").use { input -> packageDir.resolve(file).outputStream().use { input.copyTo(it) } }
        }
        var pairedRuntimeDigest = ""
        if (pairedPackage) {
            fun sha256(bytes: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it.toInt() and 255) }
            val files = packageDir.listFiles()!!.sortedBy { it.name }
            assertEquals(7, files.size)
            val inventory = files.joinToString("") { sha256(it.readBytes()) + "  " + it.name + "\n" }
            pairedRuntimeDigest = sha256(inventory.toByteArray(Charsets.UTF_8))
            // Pinned to this research branch's original seven runtime files.
            // Their hashes match source-before.json; pack.mjs is an authoring tool.
            assertEquals("current source runtime package bytes", "98545163241a0a31c7d53c3e26a9a35696cc2df65ea3d01ced7f1b4e73649547",
                pairedRuntimeDigest)
        }
        NativeCore.load()
        val engineRef = java.util.concurrent.atomic.AtomicLong()
        val wakeStarts = java.util.concurrent.CopyOnWriteArrayList<String>()
        val workerCalls = java.util.concurrent.CopyOnWriteArrayList<String>()
        val envelopes = java.util.concurrent.CopyOnWriteArrayList<Pair<String, JSONObject>>()
        val ownedWakeIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val initializeCompletions = java.util.concurrent.atomic.AtomicInteger()
        val nativeClient = if (wakeBridge) NativeCoreJobClient { ready ->
            val current = engineRef.get()
            ready(if (current > 0) Result.success(current) else Result.failure(PortError("CoreUnavailable")))
        } else null
        val client = nativeClient?.let { raw -> object : CoreJobClient {
            override fun beginLocal(jobId: String) = raw.beginLocal(jobId)
            override fun initialize(reply: (Result<Unit>) -> Unit) = raw.initialize { result ->
                if (result.isSuccess) initializeCompletions.incrementAndGet()
                reply(result)
            }
            override fun request(method: String, params: JSONObject, deadlineEpochMs: Long, reply: PortReply) {
                if (method == "jobs.run") {
                    workerCalls.add("jobs.run:" + params.getString("job_id"))
                    assertTrue("worker must initialize before jobs.run", initializeCompletions.get() > 0)
                }
                raw.request(method, params, deadlineEpochMs, reply)
            }
            override fun cancelLocal(jobId: String) = raw.cancelLocal(jobId)
        } }
        val worker = client?.let { CoreJobWakeHost(it, { "fixture-a" },
            { spec -> spec.owner == "owner" && spec.account == "fixture-a" }, { _, _ -> }) }
        val bridge = worker?.let { JobWakeDispatcher(activity, it) }
        if (worker != null) AndroidRuntime.execution = object : WakeExecutionPort {
            override fun activeAccount() = worker.activeAccount()
            override fun authorize(spec: WakeSpec) = worker.authorize(spec)
            override fun start(spec: WakeSpec, done: () -> Unit) { wakeStarts.add(spec.jobId); worker.start(spec, done) }
            override fun cancel(jobId: String) = worker.cancel(jobId)
            override fun needsUserResume(spec: WakeSpec, reason: String) = worker.needsUserResume(spec, reason)
        }
        val baseDispatcher = if (bridge == null) BrowserDispatcher(activity.browser) else CompositeDispatcher(BrowserDispatcher(activity.browser), bridge)
        val dispatcher = object : PlatformDispatcher {
            override val capabilities = baseDispatcher.capabilities
            override fun dispatch(capability: String, mediated: JSONObject, reply: PortReply) {
                if (capability.startsWith("jobs.wake.")) envelopes.add(capability to JSONObject(mediated.toString()))
                if (capability == "jobs.wake.schedule") ownedWakeIds.add(mediated.getJSONObject("input").getString("job_id"))
                baseDispatcher.dispatch(capability, mediated, reply)
            }
        }
        val opened = await(NativeCore.open(JSONObject().put("data_dir", root.resolve("core").absolutePath)
            .put("platform_capabilities", org.json.JSONArray(dispatcher.capabilities.toList())).toString().toByteArray()))
        val engine = opened.getJSONObject("result").getLong("engine")
        engineRef.set(engine)
        val pump = PlatformPump(engine, dispatcher); pump.start()
        fun rawCore(method: String, params: JSONObject): JSONObject =
            await(NativeCore.request(engine, JSONObject().put("id", method).put("method", method)
                .put("params", params).toString().toByteArray()))
        fun core(method: String, params: JSONObject): JSONObject {
            val response = rawCore(method, params)
            assertFalse("core fixture error in " + method + "/" + params.optString("action") + ": " + response.optJSONObject("error")?.optString("code"), response.has("error"))
            return response
        }
        fun setPluginGrant(capabilities: org.json.JSONArray) {
            core("permissions.set", JSONObject().put("subject", "plugin:" + manifest.getString("id"))
                .put("grant", JSONObject().put("capabilities", capabilities)
                    .put("origins", manifest.getJSONArray("network")).put("account_ids", org.json.JSONArray().put("fixture-a"))))
        }
        try {
            core("plugins.install", JSONObject().put("path", packageDir.absolutePath))
            core("plugins.enable", JSONObject().put("plugin_id", manifest.getString("id")))
            setPluginGrant(manifest.getJSONArray("capabilities"))
            val response = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id")).put("action", "venues")
                .put("input", JSONObject().put("account_id", "fixture-a")))
            assertEquals(900, response.getJSONArray("result").getJSONObject(0).getInt("id"))
            assertEquals("Synthetic court", response.getJSONArray("result").getJSONObject(0).getString("name"))
            if (pairedPackage) {
                val venue = response.getJSONArray("result").getJSONObject(0)
                assertEquals(1, venue.getInt("type"))
                val input = JSONObject("""{"account_id":"fixture-a","task_id":"paired-original-package","venue_id":900,
                    "target_date":"2099-01-03","release_at":"2099-01-01T00:00:00Z",
                    "plans":[{"time":"10:00-11:00","period_id":70,"courts":[901]}]}""")
                val scheduled = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id"))
                    .put("action", "schedule").put("input", input)).getJSONObject("result")
                assertEquals(1, scheduled.getInt("sequence"))
                assertEquals("2098-12-31T23:55:00.000Z", scheduled.getString("native_wake_at"))
                assertEquals("2099-01-01T00:05:00.000Z", scheduled.getString("deadline_at"))
                // stop must load the task written by schedule from scoped native storage.
                val stopped = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id"))
                    .put("action", "stop").put("input", JSONObject().put("account_id", "fixture-a").put("task_id", "paired-original-package")))
                    .getJSONObject("result")
                assertEquals("stopped", stopped.getString("status")); assertFalse(stopped.getBoolean("remote_effects_undone"))
                assertEquals("cancelled", core("jobs.status", JSONObject().put("job_id", scheduled.getString("job_id")))
                    .getJSONObject("result").getString("state"))
                // This owner-side ingestion is explicit: the original package does
                // not itself call sources.upsert, and its JS is never rewritten.
                val source = JSONObject().put("account_id", "fixture-a").put("source_id", "fixture.paired-sports")
                    .put("external_id", "fixture-a:venue:900").put("kind", "fixture.sports.venue").put("data", venue)
                core("sources.upsert", source)
                val records = core("sources.query", JSONObject().put("source_id", "fixture.paired-sports")
                    .put("account_id", "fixture-a").put("external_id", "fixture-a:venue:900")).getJSONArray("result")
                assertEquals(1, records.length())
                assertEquals("owner", records.getJSONObject(0).getString("owner"))
                assertEquals("Synthetic court", records.getJSONObject(0).getJSONObject("data").getString("name"))
                val ui = core("ui.get", JSONObject().put("principal", "plugin:" + manifest.getString("id")).put("id", "sports"))
                    .getJSONObject("result")
                assertEquals("card", ui.getString("type")); assertEquals("Sports task", ui.getString("title"))
                assertEquals("paired-original-package", ui.getString("task_id")); assertEquals("fixture-a", ui.getString("account_id"))
                // stop does not republish: read exactly the descriptor schedule published.
                assertEquals("scheduled", ui.getString("status")); assertEquals(0, ui.getInt("success_count")); assertEquals(1, ui.getInt("planned_count"))
                val checked = CountDownLatch(1); var onlySyntheticGet = false
                instrumentation.runOnMainSync {
                    assertTrue(activity.fixtureView!!.settings.blockNetworkLoads)
                    activity.fixtureView!!.evaluateJavascript("window.fixtureCalls.length===1 && window.fixtureCalls.every(c=>c.method==='GET'&&c.transport==='fetch')") {
                        onlySyntheticGet = it == "true"; checked.countDown()
                    }
                }
                assertTrue(checked.await(3, TimeUnit.SECONDS)); assertTrue("only the synthetic venue GET may execute", onlySyntheticGet)
                instrumentation.sendStatus(0, android.os.Bundle().apply {
                    putString("paired_package_sha256", pairedRuntimeDigest)
                    putString("paired_venue", venue.toString()); putString("paired_ui", ui.toString())
                    putString("paired_storage_stop", stopped.toString()); putString("paired_source_owner", "owner")
                })
            }
            if (wakeBridge) {
                val wake = AndroidWakePort(activity)
                assertTrue("Real exact-alarm access must be granted in Settings for this native wake fixture", wake.capabilities().getBoolean("exact_available"))
                val later = System.currentTimeMillis() + 60_000
                val generic = JSONObject().put("plugin_id", manifest.getString("id")).put("action", "venues")
                    .put("run_at", java.time.Instant.ofEpochMilli(later).toString())
                    .put("input", JSONObject().put("account_id", "fixture-a").put("tag", "default-deadline"))
                val scheduled = core("jobs.schedule", generic).getJSONObject("result")
                val genericId = scheduled.getString("job_id")
                assertTrue(scheduled.getJSONObject("wake_up").getBoolean("scheduled"))
                assertFalse(scheduled.getJSONObject("wake_up").getBoolean("exact"))
                val stored = core("jobs.status", JSONObject().put("job_id", genericId)).getJSONObject("result")
                assertEquals(later + 60_000, java.time.Instant.parse(stored.getJSONObject("data").getString("deadline_at")).toEpochMilli())
                assertEquals(later + 60_000, wake.load(genericId)!!.deadline)
                core("jobs.cancel", JSONObject().put("job_id", genericId)); assertNull(wake.load(genericId))
                val rejected = JSONObject(generic.toString()).put("wake_precision", "invalid-fixture-precision")
                    .put("input", JSONObject().put("account_id", "fixture-a").put("tag", "not-armed"))
                val notArmed = core("jobs.schedule", rejected).getJSONObject("result")
                assertEquals("not_armed", notArmed.getJSONObject("wake_up").getString("state"))
                assertEquals("InvalidWake", notArmed.getJSONObject("wake_up").getJSONObject("error").getString("code"))
                assertNull(wake.load(notArmed.getString("job_id")))
                core("jobs.cancel", JSONObject().put("job_id", notArmed.getString("job_id")))
            }
            if (syntheticWrite) {
                val declared = manifest.getJSONArray("capabilities")
                val readOnly = org.json.JSONArray()
                var declaresWrite = false
                for (i in 0 until declared.length()) {
                    if (declared.getString(i) == "browser.write") declaresWrite = true else readOnly.put(declared.getString(i))
                }
                assertTrue("sports package must declare browser.write", declaresWrite)
                val configured = CountDownLatch(1)
                instrumentation.runOnMainSync {
                    assertTrue(activity.fixtureView!!.settings.blockNetworkLoads)
                    activity.fixtureView!!.evaluateJavascript("window.fixtureReply={e:0,d:{data:[{id:30,type:7,slots:[]}]}}") { configured.countDown() }
                }
                assertTrue(configured.await(3, TimeUnit.SECONDS))
                setPluginGrant(readOnly)
                val cancel = JSONObject().put("plugin_id", manifest.getString("id")).put("action", "cancelAppointment")
                    .put("input", JSONObject().put("account_id", "fixture-a").put("appointment_id", 30))
                val denied = rawCore("plugins.run", cancel)
                assertEquals("PermissionDenied", denied.getJSONObject("error").getString("code"))
                val checked = CountDownLatch(1); var noPost = false
                instrumentation.runOnMainSync {
                    activity.fixtureView!!.evaluateJavascript("window.fixtureCalls.every(c=>c.method==='GET')") { noPost = it == "true"; checked.countDown() }
                }
                assertTrue(checked.await(3, TimeUnit.SECONDS)); assertTrue("denied write must not reach the page", noPost)
                val recorded = core("jobs.status", JSONObject()).getJSONArray("result")
                val deniedJobs = (0 until recorded.length()).map { recorded.getJSONObject(it) }.filter {
                    it.getJSONObject("data").optString("action") == "cancelAppointment" && it.optString("state") == "waiting_for_approval"
                }
                assertEquals("denied actual write must remain a durable waiting job", 1, deniedJobs.size)
                // This attempt is positively known to have been denied before page
                // dispatch. It can be dismissed; uncertain writes may NOT be dismissed.
                core("jobs.cancel", JSONObject().put("job_id", deniedJobs.single().getString("id")))
                // Restoring the concrete permission gives a fresh effective storage
                // scope. The only actual POST is to the bundled synthetic XHR class.
                setPluginGrant(declared)
                val cancelled = core("plugins.run", cancel).getJSONObject("result")
                assertEquals("cancelled", cancelled.getString("status"))
                assertEquals(30, cancelled.getInt("appointment_id"))
                val posted = CountDownLatch(1); var onePost = false
                instrumentation.runOnMainSync {
                    activity.fixtureView!!.evaluateJavascript("window.fixtureCalls.filter(c=>c.method==='POST'&&c.transport==='xhr').length===1") {
                        onePost = it == "true"; posted.countDown()
                    }
                }
                assertTrue(posted.await(3, TimeUnit.SECONDS)); assertTrue("one explicitly granted synthetic XHR POST expected", onePost)
                val failNext = CountDownLatch(1)
                instrumentation.runOnMainSync {
                    activity.fixtureView!!.evaluateJavascript("window.fixtureReply.d.data[0].id=31;window.fixtureNextWriteError=true") { failNext.countDown() }
                }
                assertTrue(failNext.await(3, TimeUnit.SECONDS))
                val uncertainInput = JSONObject().put("plugin_id", manifest.getString("id")).put("action", "cancelAppointment")
                    .put("input", JSONObject().put("account_id", "fixture-a").put("appointment_id", 31))
                assertEquals("NeedsReconciliation", rawCore("plugins.run", uncertainInput).getJSONObject("error").getString("code"))
                val afterLoss = core("jobs.status", JSONObject()).getJSONArray("result")
                val unknown = (0 until afterLoss.length()).map { afterLoss.getJSONObject(it) }.single {
                    it.getJSONObject("data").optString("action") == "cancelAppointment" &&
                        it.getJSONObject("data").optJSONObject("input")?.optInt("appointment_id") == 31
                }
                assertEquals("needs_reconciliation", unknown.getString("state"))
                // Dismissing a locally cancelled wait must not assert remote undo.
                assertEquals("NeedsReconciliation", rawCore("jobs.cancel", JSONObject().put("job_id", unknown.getString("id")))
                    .getJSONObject("error").getString("code"))
                assertEquals("needs_reconciliation", core("jobs.status", JSONObject().put("job_id", unknown.getString("id")))
                    .getJSONObject("result").getString("state"))
                val readAfterLoss = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id"))
                    .put("action", "appointments").put("input", JSONObject().put("account_id", "fixture-a")))
                assertEquals(31, readAfterLoss.getJSONArray("result").getJSONObject(0).getInt("id"))
                val newTarget = CountDownLatch(1)
                instrumentation.runOnMainSync {
                    activity.fixtureView!!.evaluateJavascript("window.fixtureReply.d.data[0].id=32") { newTarget.countDown() }
                }
                assertTrue(newTarget.await(3, TimeUnit.SECONDS))
                val blocked = JSONObject().put("plugin_id", manifest.getString("id")).put("action", "cancelAppointment")
                    .put("input", JSONObject().put("account_id", "fixture-a").put("appointment_id", 32))
                assertEquals("NeedsReconciliation", rawCore("plugins.run", blocked).getJSONObject("error").getString("code"))
                val blockedCheck = CountDownLatch(1); var noResubmit = false
                instrumentation.runOnMainSync {
                    activity.fixtureView!!.evaluateJavascript("window.fixtureCalls.filter(c=>c.method==='POST').length===2") {
                        noResubmit = it == "true"; blockedCheck.countDown()
                    }
                }
                assertTrue(blockedCheck.await(3, TimeUnit.SECONDS)); assertTrue("uncertain prior job must block another actual POST", noResubmit)
            }
            if (continuations) {
                // Only operational capabilities are installed. Deliberately DO NOT grant
                // plugin:<id>:tick / execute:<id>:tick to the plugin principal itself.
                val granted = core("permissions.get", JSONObject().put("subject", "plugin:" + manifest.getString("id"))).getJSONObject("result")
                val caps = granted.getJSONArray("capabilities")
                for (i in 0 until caps.length()) {
                    assertFalse(caps.getString(i).startsWith("plugin:"))
                    assertFalse(caps.getString(i).startsWith("execute:"))
                }
                val configured = CountDownLatch(1)
                instrumentation.runOnMainSync {
                    assertTrue(activity.fixtureView!!.settings.blockNetworkLoads)
                    activity.fixtureView!!.evaluateJavascript("window.fixtureReply={e:0,d:{time:[{id:71,str_time:'10:00-11:00'}],resource:[{id:901,name:'Synthetic court'}]}}") { configured.countDown() }
                }
                assertTrue(configured.await(3, TimeUnit.SECONDS))
                // Default 60s preload: first job is due in 8s, while the first shot
                // remains >60s away. The fixture host independently denies all writes.
                val release = System.currentTimeMillis() + 68_000
                val input = JSONObject().put("account_id", "fixture-a").put("task_id", "native-continuation-task")
                    .put("venue_id", 900).put("target_date", "2031-01-04")
                    .put("release_at", java.time.Instant.ofEpochMilli(release).toString())
                    .put("plans", org.json.JSONArray().put(JSONObject().put("time", "10:00-11:00")
                        .put("period_id", 70).put("courts", org.json.JSONArray().put(901))))
                val created = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id"))
                    .put("action", "schedule").put("input", input)).getJSONObject("result")
                val firstId = created.getString("job_id")
                var first = core("jobs.status", JSONObject().put("job_id", firstId)).getJSONObject("result")
                assertEquals("owner", first.getJSONObject("owner").getString("id"))
                assertEquals("owner", first.getJSONObject("owner").getString("kind"))
                assertEquals(release - 60_000, java.time.Instant.parse(first.getString("run_at")).toEpochMilli())
                assertEquals("tick", first.getJSONObject("data").getString("action"))
                assertEquals("fixture-a", first.getJSONObject("data").getJSONObject("input").getString("account_id"))
                assertEquals(1, first.getJSONObject("data").getJSONObject("input").getInt("sequence"))
                if (wakeBridge) {
                    val armed = AndroidWakePort(activity).load(firstId)!!
                    assertEquals("owner", armed.owner); assertEquals("fixture-a", armed.account)
                    assertEquals(release - 60_000, armed.executeAt)
                    assertEquals(release + 300_000, armed.deadline)
                    assertEquals("exact", armed.precision)
                }
                val preloadEnd = System.currentTimeMillis() + 22_000
                while (first.getString("state") in listOf("scheduled", "running") && System.currentTimeMillis() < preloadEnd) {
                    Thread.sleep(100)
                    first = core("jobs.status", JSONObject().put("job_id", firstId)).getJSONObject("result")
                }
                assertEquals("succeeded", first.getString("state"))
                assertEquals("preloaded", first.getJSONObject("result").getString("status"))
                if (wakeBridge) {
                    assertTrue("Actual AlarmManager/FGS must invoke the worker", firstId in wakeStarts)
                    assertTrue("Real NativeCoreJobClient must invoke jobs.run on wake", "jobs.run:$firstId" in workerCalls)
                }
                val jobs = core("jobs.status", JSONObject()).getJSONArray("result")
                val children = (0 until jobs.length()).map { jobs.getJSONObject(it) }
                    .filter { it.getString("id") != firstId && it.getJSONObject("data").optString("plugin_id") == manifest.getString("id") &&
                        it.getJSONObject("data").optString("action") == "tick" &&
                        it.getJSONObject("data").optJSONObject("input")?.optString("task_id") == "native-continuation-task" }
                assertEquals("preload must persist one continuation", 1, children.size)
                val child = children.single()
                assertEquals("owner", child.getJSONObject("owner").getString("id"))
                assertEquals("owner", child.getJSONObject("owner").getString("kind"))
                assertEquals("scheduled", child.getString("state"))
                assertEquals(release + 300, java.time.Instant.parse(child.getString("run_at")).toEpochMilli())
                assertEquals("tick", child.getJSONObject("data").getString("action"))
                assertEquals("native-continuation-task", child.getJSONObject("data").getJSONObject("input").getString("task_id"))
                assertEquals("fixture-a", child.getJSONObject("data").getJSONObject("input").getString("account_id"))
                assertEquals(2, child.getJSONObject("data").getJSONObject("input").getInt("sequence"))
                assertFalse("next transition must not dedup to its running parent", child.getString("id") == firstId)
                val stale = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id")).put("action", "tick")
                    .put("input", JSONObject().put("account_id", "fixture-a").put("task_id", "native-continuation-task").put("sequence", 1)))
                assertEquals("stale_sequence", stale.getJSONObject("result").getString("status"))
                val stopped = core("plugins.run", JSONObject().put("plugin_id", manifest.getString("id"))
                    .put("action", "stop").put("input", JSONObject().put("account_id", "fixture-a").put("task_id", "native-continuation-task")))
                assertEquals("stopped", stopped.getJSONObject("result").getString("status"))
                assertEquals("cancelled", core("jobs.status", JSONObject().put("job_id", child.getString("id"))).getJSONObject("result").getString("state"))
                if (wakeBridge) {
                    assertNull(AndroidWakePort(activity).load(child.getString("id")))
                    assertTrue(envelopes.any { it.first == "jobs.wake.cancel" && it.second.getJSONObject("input").optString("job_id") == child.getString("id") })
                    val pending = core("jobs.schedule", JSONObject().put("plugin_id", manifest.getString("id")).put("action", "venues")
                        .put("run_at", java.time.Instant.ofEpochMilli(System.currentTimeMillis() + 60_000).toString())
                        .put("input", JSONObject().put("account_id", "fixture-a").put("tag", "disable-cleanup"))).getJSONObject("result")
                    val pendingId = pending.getString("job_id")
                    assertNotNull(AndroidWakePort(activity).load(pendingId))
                    core("plugins.disable", JSONObject().put("plugin_id", manifest.getString("id")))
                    assertNull(AndroidWakePort(activity).load(pendingId))
                    assertEquals("cancelled", core("jobs.status", JSONObject().put("job_id", pendingId)).getJSONObject("result").getString("state"))
                    for ((_, envelope) in envelopes.filter { it.first == "jobs.wake.schedule" }) {
                        assertEquals("owner", envelope.getJSONObject("principal").getString("id"))
                        val caps = envelope.getJSONObject("grant").getJSONArray("capabilities")
                        assertTrue((0 until caps.length()).any { caps.getString(it) == "jobs.wake.schedule" })
                        assertTrue(envelope.getJSONObject("input").has("deadline_at"))
                    }
                }
                val checked = CountDownLatch(1); var noWrites = false
                instrumentation.runOnMainSync {
                    activity.fixtureView!!.evaluateJavascript("window.fixtureCalls.length>=2 && window.fixtureCalls.every(c=>c.method==='GET'&&c.transport==='fetch')") {
                        noWrites = it == "true"; checked.countDown()
                    }
                }
                assertTrue(checked.await(3, TimeUnit.SECONDS)); assertTrue("preload must issue only page GETs", noWrites)
            }
        } finally {
            if (wakeBridge) {
                worker?.close()
                val wake = AndroidWakePort(activity)
                ownedWakeIds.forEach { id -> wake.load(id)?.let { wake.cancel(it.jobId, it.owner) } }
            }
            pump.close(); await(NativeCore.close(engine))
            nativeClient?.close()
            if (wakeBridge) AndroidRuntime.execution = null
            val cleared = CountDownLatch(1); activity.browser.logout("fixture-a") { cleared.countDown() }
            cleared.await(5, TimeUnit.SECONDS); instrumentation.runOnMainSync { activity.finish() }
        }
    }
}
