// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import org.dansheng.android.MutationAuthorizer
import org.dansheng.android.PersistentMutationGate
import org.dansheng.android.PortError
import org.dansheng.android.WakeSpec
import org.dansheng.android.origin
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

class GrantGate(
    context: Context,
    private val activeAccountProvider: () -> String?
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val packagePrefs = context.getSharedPreferences("dansheng-packages-v1", Context.MODE_PRIVATE)
    private val consentPrefs = context.getSharedPreferences("dansheng-consents-v1", Context.MODE_PRIVATE)
    private val lock = Any()

    private val boundPackages = ConcurrentHashMap<String, BoundPackage>()
    private val revokedPlugins = ConcurrentHashMap.newKeySet<String>()

    data class StoredConsent(
        val pluginId: String,
        val action: String,
        val taskId: String,
        val input: JSONObject,
        val inputHash: String,
        val recordedAt: Long,
        val expiresAt: Long
    )

    init {
        // Rehydrate packages on startup
        rehydratePackages()
    }

    private fun rehydratePackages() = synchronized(lock) {
        val all = packagePrefs.all
        for ((key, value) in all) {
            if (key.startsWith("pkg:") && value is String) {
                try {
                    val json = JSONObject(value)
                    val pluginId = json.getString("plugin_id")
                    val archiveHash = json.getString("archive_hash")
                    val manifest = json.getJSONObject("manifest")
                    val policyObj = json.optJSONObject("policy")
                    val policy = policyObj?.let(PortDescriptorParser::parsePolicy)
                    boundPackages[pluginId] = BoundPackage(
                        pluginId = pluginId,
                        archiveHash = archiveHash,
                        manifest = manifest,
                        policy = policy,
                        rawPolicyJson = policyObj?.toString(),
                        boundAt = json.optLong("bound_at", System.currentTimeMillis())
                    )
                } catch (_: Exception) {}
            }
        }
    }

    val mutationAuthorizer: MutationAuthorizer = PersistentMutationGate(context) { principal, account, request, now ->
        isMutationApproved(principal, account, request, now)
    }

    /**
     * Binds package after Core install.
     * archiveHash: Verified full SHA-256 digest from independent expected source.
     * null policy clears prior policy (unprivileged package without browser mutation policy).
     */
    fun bindPackage(
        pluginId: String,
        manifest: JSONObject,
        policy: JSONObject?,
        archiveHash: String
    ) = synchronized(lock) {
        if (pluginId.isBlank()) throw PortError("InvalidPluginId")
        if (manifest.optString("id") != pluginId) throw PortError("ManifestIdMismatch")
        if (archiveHash.isBlank() || archiveHash.length != 64) throw PortError("InvalidArchiveHash")

        // Binding an installed version does not activate it.
        revokedPlugins.add(pluginId)
        check(packagePrefs.edit().putBoolean("enabled:$pluginId",false).commit())

        if (policy != null) {
            val root = when {
                policy.has("binding_v1") -> policy.getJSONObject("binding_v1")
                policy.has("plugin_policy") -> policy.getJSONObject("plugin_policy").optJSONObject("binding_v1") ?: policy
                else -> policy
            }
            val policyPluginId = root.optString("plugin_id").ifEmpty { policy.optString("plugin_id") }
            if (policyPluginId != pluginId) throw PortError("PolicyPluginIdMismatch")

            val parsedPolicy = PortDescriptorParser.parsePolicy(policy)
            val record = JSONObject()
                .put("plugin_id", pluginId)
                .put("archive_hash", archiveHash)
                .put("manifest", manifest)
                .put("policy", policy)
                .put("bound_at", System.currentTimeMillis())

            packagePrefs.edit().putString("pkg:$pluginId", record.toString()).commit()
            boundPackages[pluginId] = BoundPackage(
                pluginId = pluginId,
                archiveHash = archiveHash,
                manifest = manifest,
                policy = parsedPolicy,
                rawPolicyJson = policy.toString(),
                boundAt = System.currentTimeMillis()
            )
        } else {
            // Null policy clears prior policy
            val record = JSONObject()
                .put("plugin_id", pluginId)
                .put("archive_hash", archiveHash)
                .put("manifest", manifest)
                .put("policy", JSONObject.NULL)
                .put("bound_at", System.currentTimeMillis())

            packagePrefs.edit().putString("pkg:$pluginId", record.toString()).commit()
            boundPackages[pluginId] = BoundPackage(
                pluginId = pluginId,
                archiveHash = archiveHash,
                manifest = manifest,
                policy = null,
                rawPolicyJson = null,
                boundAt = System.currentTimeMillis()
            )
        }
    }

    fun activate(pluginId: String) = synchronized(lock) {
        revokedPlugins.remove(pluginId)
        if (!boundPackages.containsKey(pluginId)) {
            val saved = packagePrefs.getString("pkg:$pluginId", null) ?: throw PortError("PackageNotBound")
            val json = JSONObject(saved)
            val archiveHash = json.getString("archive_hash")
            val manifest = json.getJSONObject("manifest")
            val policyObj = json.optJSONObject("policy")
            val policy = policyObj?.let(PortDescriptorParser::parsePolicy)
            boundPackages[pluginId] = BoundPackage(
                pluginId = pluginId,
                archiveHash = archiveHash,
                manifest = manifest,
                policy = policy,
                rawPolicyJson = policyObj?.toString(),
                boundAt = json.optLong("bound_at", System.currentTimeMillis())
            )
        }
        check(packagePrefs.edit().putBoolean("enabled:$pluginId",true).commit())
    }

    fun revoke(pluginId: String) = synchronized(lock) {
        revokedPlugins.add(pluginId)
        check(packagePrefs.edit().putBoolean("enabled:$pluginId",false).commit())
        val editor = consentPrefs.edit()
        consentPrefs.all.keys.filter { it.startsWith("consent:$pluginId:") }.forEach {
            editor.remove(it)
        }
        editor.commit()
    }

    fun isRevoked(pluginId: String): Boolean = pluginId in revokedPlugins || !packagePrefs.getBoolean("enabled:$pluginId",false)

    fun getBoundPackage(pluginId: String): BoundPackage? = boundPackages[pluginId]

    /**
     * Persists future scheduled authorization up to approved plan release_at+windowMs,
     * exact canonical inputs by task ID, fallback 60s for immediate writes.
     */
    fun recordConsent(
        pluginId: String,
        action: String,
        input: JSONObject,
        hash: String
    ) = synchronized(lock) {
        if (pluginId.isBlank() || action.isBlank()) throw PortError("InvalidConsent")
        if(isRevoked(pluginId) || input.optString("account_id")!=activeAccountProvider()) throw PortError("PermissionDenied")
        val scope=boundPackages[pluginId]?.policy?.consentScopes?.optJSONObject(action)
        val now=System.currentTimeMillis()
        fun field(key:String):Any? = scope?.optString(key)?.takeIf { it.startsWith("/") }
            ?.let { PortDescriptorParser.evaluateJsonPointer(input,it) }
        val expiresAt=if(scope?.has("release")==true) {
            val release=(field("release") as? String)?.let { java.time.OffsetDateTime.parse(it).toInstant().toEpochMilli() } ?: throw PortError("InvalidConsent")
            val window=(field("window_ms") as? Number)?.toLong() ?: scope.optLong("default_window_ms",60_000L)
            if(window !in 1..600_000L) throw PortError("InvalidConsent")
            Math.addExact(release,window)
        } else now+60_000L
        if(expiresAt<=now) throw PortError("DeadlineExceeded")
        val taskId = action + ":" + (field("key")?.toString() ?: hash)

        val stored = JSONObject()
            .put("plugin_id", pluginId)
            .put("action", action)
            .put("task_id", taskId)
            .put("input", input)
            .put("input_hash", hash)
            .put("recorded_at", now)
            .put("expires_at", expiresAt)

        check(consentPrefs.edit().putString("consent:$pluginId:$taskId", stored.toString()).commit())
    }

    private fun getUnexpiredConsents(pluginId: String, now: Long): List<StoredConsent> {
        val list = mutableListOf<StoredConsent>()
        val prefix = "consent:$pluginId:"
        for ((key, value) in consentPrefs.all) {
            if (key.startsWith(prefix) && value is String) {
                try {
                    val json = JSONObject(value)
                    val expiresAt = json.optLong("expires_at", 0)
                    if (now < expiresAt) {
                        list.add(StoredConsent(
                            pluginId = json.getString("plugin_id"),
                            action = json.getString("action"),
                            taskId = json.getString("task_id"),
                            input = json.getJSONObject("input"),
                            inputHash = json.optString("input_hash"),
                            recordedAt = json.optLong("recorded_at"),
                            expiresAt = expiresAt
                        ))
                    }
                } catch (_: Exception) {}
            }
        }
        return list
    }

    /**
     * Strict generic declarative account/plan-to-form matching over independent package policy.
     * Scoped strictly to principal (no guessing from overlapping domains).
     * Rechecks active account, enabled/grant, and deadline.
     */
    fun isMutationApproved(
        principal: String,
        account: String,
        request: JSONObject,
        now: Long
    ): Boolean = synchronized(lock) {
        val activeAccount = activeAccountProvider()
        if (account.isBlank() || account != activeAccount) return false

        val pluginId = principal.removePrefix("plugin:")
        if (isRevoked(pluginId)) return false

        val pkg = boundPackages[pluginId] ?: return false
        val policy = pkg.policy ?: return false // Fail closed without a pinned descriptor for browser writes

        val deadline = request.optLong("deadline_epoch_ms", 0)
        if (deadline > 0 && now >= deadline) throw PortError("DeadlineExceeded")

        val reqUrl = request.optString("url")
        val reqMethod = request.optString("method", "GET").uppercase()
        val reqTransport = request.optString("transport", "fetch")
        val reqKey = request.optString("mutation_key")
        val reqHeaders = request.optJSONObject("headers") ?: JSONObject()
        val reqForm = request.optJSONObject("form_fields")

        if (reqMethod != "POST" || reqKey.isBlank() || request.has("body")) return false

        // Match against permitted rules in policy
        val matchingRules = policy.rules.filter { rule ->
            rule.url == reqUrl &&
            rule.transport.equals(reqTransport, ignoreCase = true) &&
            matchesHeaders(rule.headers, reqHeaders)
        }
        if (matchingRules.isEmpty()) return false

        // Match against unexpired consents
        val consents = getUnexpiredConsents(pluginId, now)
        if (consents.isEmpty()) return false

        for (consent in consents) {
            if (consent.input.optString("account_id") != account) continue
            for (rule in matchingRules) {
                if (rule.action == consent.action && rule.matches(consent.input, reqKey, reqForm)) {
                    return true
                }
            }
        }

        return false
    }

    private fun matchesHeaders(ruleHeaders: Map<String, String>, reqHeaders: JSONObject): Boolean {
        if (ruleHeaders.size != reqHeaders.length() ||
            reqHeaders.keys().asSequence().map { it.lowercase(java.util.Locale.ROOT) }.toSet().size != reqHeaders.length()) return false
        for ((k, v) in ruleHeaders) {
            var found = false
            for (reqKey in reqHeaders.keys()) {
                if (reqKey.equals(k, ignoreCase = true)) {
                    if (reqHeaders.getString(reqKey) != v) return false
                    found = true
                    break
                }
            }
            if (!found) return false
        }
        return true
    }

    fun isWakeAuthorized(spec: WakeSpec): Boolean {
        val now = System.currentTimeMillis()
        if (now >= spec.deadline) return false
        val activeAccount = activeAccountProvider()
        if (spec.account != null && spec.account != activeAccount) return false

        val owner = spec.owner
        if (owner == "owner") return true
        val pluginId = owner.removePrefix("plugin:")
        if (isRevoked(pluginId)) return false

        // Package must be installed/bound
        val pkg = boundPackages[pluginId] ?: return false
        return true
    }

    fun policyFor(principal:String,targetOrigin: String): PortBindingPolicy? {
        val safeOrigin = try { origin(targetOrigin) } catch (_: Exception) { return null }
        if(!principal.startsWith("plugin:")) return null
        val id=principal.removePrefix("plugin:")
        if(isRevoked(id)) return null
        val pkg=boundPackages[id] ?: return null
        val network=pkg.manifest.optJSONArray("network") ?: return null
        return pkg.policy?.takeIf { (0 until network.length()).any { i->network.optString(i)==safeOrigin } }
    }
    /** Only these two independently enabled and verified packages can use the same page;
     * each request still carries its own grants and its own write consent. */
    fun trustedVenueLogin(principal:String):Boolean {
        val id=principal.removePrefix("plugin:")
        if(principal!="plugin:$id" || isRevoked(id)) return false
        val pkg=boundPackages[id] ?: return false
        return id=="official.fudan-venues" || OfficialSports.recognized(id,pkg.manifest.optString("version"),pkg.archiveHash)
    }
    fun sharedVenueSession(from:String,to:String,account:String,page:String?):Boolean {
        if(account!=activeAccountProvider() || page==null ||
            setOf(from,to)!=setOf("plugin:official.fudan-venues","plugin:official.fudan-sports") ||
            !trustedVenueLogin(from) || !trustedVenueLogin(to)) return false
        val current=runCatching { origin(page.substringBefore('#')) }.getOrNull() ?: return false
        val first=policyFor(from,current)?.identityProbe ?: return false
        val next=policyFor(to,current)?.identityProbe ?: return false
        return first.url==next.url && first.jsonPointer==next.jsonPointer && first.topLevelOrigin==current &&
            next.topLevelOrigin==current && first.method=="GET" && next.method=="GET" &&
            first.successPointer==next.successPointer && first.successValue==next.successValue
    }

    /**
     * Strict identity probe:
     * - Only same-origin HTTPS GET
     * - Top-level origin verified before and after
     * - JSON pointer evaluated in Kotlin
     * - Exact match to active account
     * - Fails closed when missing or unverified
     */
    fun runIdentityProbe(
        principal:String,
        accountId: String,
        targetOrigin: String,
        webView: WebView,
        complete: (Result<String>) -> Unit
    ) {
        val activeAccount = activeAccountProvider()
        if (accountId.isBlank() || accountId != activeAccount) {
            complete(Result.failure(PortError("AccountMismatch")))
            return
        }

        mainHandler.post {
            // Origin check before
            val urlBefore = webView.url
            val originBefore = try { urlBefore?.substringBefore('#')?.let(::origin) } catch (_: Exception) { null }
            if (originBefore != targetOrigin) {
                complete(Result.failure(PortError("OriginMismatch")))
                return@post
            }

            val policy = policyFor(principal,targetOrigin)
            if (policy == null || policy.identityProbe == null) {
                // Fail closed when missing
                complete(Result.failure(PortError("IdentityVerificationUnavailable")))
                return@post
            }

            val probe = policy.identityProbe
            if (probe.method != "GET" || probe.jsonPointer.isNullOrBlank()) {
                // Fail closed when no authoritative JSON pointer to student ID is proven
                complete(Result.failure(PortError("IdentityVerificationUnavailable")))
                return@post
            }

            val probeOrigin = try { origin(probe.url) } catch (_: Exception) { null }
            if (probeOrigin != targetOrigin || !probe.url.startsWith("https://") || probe.topLevelOrigin != targetOrigin) {
                complete(Result.failure(PortError("OriginMismatch")))
                return@post
            }

            // Fixed host-owned runner script: HTTPS GET same-origin only, no arbitrary package JS
            val box = "__ds_identity_" + java.util.UUID.randomUUID().toString().replace("-","")
            val slot = "window[" + JSONObject.quote(box) + "]"
            // Only a boolean crosses out of the authenticated profile page.
            fun pointer(path:String) = JSONArray(path.removePrefix("/").split("/").map { it.replace("~1","/").replace("~0","~") }).toString()
            val success = if (probe.successPointer == null) "true" else "at(root,${pointer(probe.successPointer)}) === ${JSONObject.quote(probe.successValue)}"
            val script = """
                (()=>{ $slot={ready:false};
                    const at=(v,keys)=>keys.reduce((x,k)=>x!=null && Object.prototype.hasOwnProperty.call(x,k)?x[k]:undefined,v);
                    window.fetch(${JSONObject.quote(probe.url)},{method:'GET',headers:${probe.headers},credentials:'same-origin',cache:'no-store',redirect:'error'})
                        .then(async r=>{const got=new URL(r.url), wanted=new URL(${JSONObject.quote(probe.url)});
                            if(r.status!==200 || got.origin!==wanted.origin || got.pathname!==wanted.pathname) return null;
                            const t=await r.text(); if(t.length>65536)return null;
                            const root=JSON.parse(t);if(!($success))return null;
                            const id=at(root,${pointer(probe.jsonPointer)});
                            if(!(typeof id==='string' && id.trim().length) && !(Number.isSafeInteger(id) && id>0))return null;
                            return String(id)===${JSONObject.quote(accountId)};})
                        .catch(()=>null).then(value=>{if($slot)$slot={ready:true,value};}); })()
            """.trimIndent()
            webView.evaluateJavascript(script, null)

            val startTime = System.currentTimeMillis()
            val poll = object : Runnable {
                override fun run() {
                    if (System.currentTimeMillis() - startTime > 4000L) {
                        webView.evaluateJavascript("delete $slot",null)
                        complete(Result.failure(PortError("AuthenticationRequired")))
                        return
                    }
                    webView.evaluateJavascript("${slot} && ${slot}.ready === true ? ${slot}.value : '__not_ready__'") { rawValue ->
                        if (rawValue == null || rawValue == "\"__not_ready__\"" || rawValue == "__not_ready__") {
                            mainHandler.postDelayed(this, 50)
                            return@evaluateJavascript
                        }

                        // Clean up probe globals
                        webView.evaluateJavascript("delete $slot;", null)

                        // Origin check after
                        val urlAfter = webView.url
                        val originAfter = try { urlAfter?.substringBefore('#')?.let(::origin) } catch (_: Exception) { null }
                        if (originAfter != targetOrigin || webView.url != urlBefore || policyFor(principal,targetOrigin) !== policy) {
                            complete(Result.failure(PortError("OriginMismatch")))
                            return@evaluateJavascript
                        }

                        if (rawValue == "null") {
                            complete(Result.failure(PortError("AuthenticationRequired")))
                            return@evaluateJavascript
                        }

                        if (rawValue == "true" && accountId == activeAccountProvider()) {
                            complete(Result.success(accountId))
                        } else {
                            complete(Result.failure(PortError("AccountMismatch")))
                        }
                    }
                }
            }
            mainHandler.postDelayed(poll, 50)
        }
    }
}
