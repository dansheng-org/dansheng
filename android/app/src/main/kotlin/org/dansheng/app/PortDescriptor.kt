// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.PortError
import org.dansheng.android.origin
import org.json.JSONArray
import org.json.JSONObject

/**
 * Portable descriptor and declarative policy models for binding_v1.
 * Enforces strict generic template references, primitive projections,
 * and fail-closed security.
 */

data class PortIdentityProbe(
    val url: String,
    val method: String = "GET",
    val topLevelOrigin: String,
    val jsonPointer: String? = null,
    val successPointer:String? = null,
    val successValue:String? = null,
    val headers:JSONObject = JSONObject()
)

sealed class PortKeyToken {
    data class Literal(val value: String) : PortKeyToken()
    data class InputRef(val key: String) : PortKeyToken()
    data class RowRef(val key: String) : PortKeyToken()
    object ChoiceRef : PortKeyToken()
    object PositiveInteger : PortKeyToken()
}

sealed class PortFormTemplate {
    data class Literal(val value: Any) : PortFormTemplate()
    data class InputRef(val key: String) : PortFormTemplate()
    data class RowRef(val key: String) : PortFormTemplate()
    object ChoiceRef : PortFormTemplate()
    data class EmbeddedJson(val template: Any) : PortFormTemplate()
    data class Text(val template: PortFormTemplate) : PortFormTemplate()
}

data class PortWriteRule(
    val action: String,
    val url: String,
    val transport: String,
    val headers: Map<String, String>,
    val keyTokens: List<PortKeyToken>,
    val rowsField: String? = null,
    val choicesField: String? = null,
    val formFields: Map<String, PortFormTemplate> = emptyMap()
) {
    fun matches(
        consentInput: JSONObject,
        requestKey: String,
        requestForm: JSONObject?
    ): Boolean {
        val rows = if (rowsField != null) consentInput.optJSONArray(rowsField) else null
        if (rows != null && choicesField != null) {
            for (r in 0 until rows.length()) {
                val rowObj = rows.optJSONObject(r) ?: continue
                val choices = rowObj.optJSONArray(choicesField) ?: continue
                for (c in 0 until choices.length()) {
                    val choice = choices.get(c)
                    if (matchesSingle(consentInput, rowObj, choice, requestKey, requestForm)) {
                        return true
                    }
                }
            }
            return false
        } else {
            return matchesSingle(consentInput, null, null, requestKey, requestForm)
        }
    }

    private fun matchesSingle(
        consentInput: JSONObject,
        rowObj: JSONObject?,
        choice: Any?,
        requestKey: String,
        requestForm: JSONObject?
    ): Boolean {
        // 1. Verify key tokens
        val actualTokens = requestKey.split(":")
        if (actualTokens.size != keyTokens.size) return false

        for (i in keyTokens.indices) {
            val expectedToken = keyTokens[i]
            val actualToken = actualTokens[i]
            val ok = when (expectedToken) {
                is PortKeyToken.Literal -> expectedToken.value == actualToken
                is PortKeyToken.InputRef -> {
                    val v = consentInput.opt(expectedToken.key) ?: return false
                    v.toString() == actualToken
                }
                is PortKeyToken.RowRef -> {
                    if (rowObj == null) return false
                    val v = rowObj.opt(expectedToken.key) ?: return false
                    v.toString() == actualToken
                }
                is PortKeyToken.ChoiceRef -> {
                    if (choice == null) return false
                    choice.toString() == actualToken
                }
                is PortKeyToken.PositiveInteger -> {
                    val n = actualToken.toLongOrNull()
                    n != null && n in 1..1000 // finite positive integer rounds
                }
            }
            if (!ok) return false
        }

        // 2. Verify form fields
        if (formFields.isEmpty()) {
            return requestForm == null || requestForm.length() == 0
        }
        if (requestForm == null) return false

        // Default deny: extra body/fields/keys forbidden
        val expectedKeys = formFields.keys
        val actualKeys = requestForm.keys().asSequence().toSet()
        if (expectedKeys != actualKeys) return false

        for ((fieldKey, template) in formFields) {
            val actualVal = requestForm.get(fieldKey)
            val expectedVal = projectTemplate(template, consentInput, rowObj, choice)
            if (!PortDescriptorParser.compareValues(expectedVal, actualVal)) {
                return false
            }
        }

        return true
    }

    private fun projectTemplate(
        template: PortFormTemplate,
        consentInput: JSONObject,
        rowObj: JSONObject?,
        choice: Any?
    ): Any? = when (template) {
        is PortFormTemplate.Literal -> template.value
        is PortFormTemplate.InputRef -> consentInput.opt(template.key)
        is PortFormTemplate.RowRef -> rowObj?.opt(template.key)
        is PortFormTemplate.ChoiceRef -> choice
        is PortFormTemplate.EmbeddedJson -> projectJsonValue(template.template, consentInput, rowObj, choice)
        is PortFormTemplate.Text -> when(val value=projectTemplate(template.template,consentInput,rowObj,choice)) {
            is Number, is Boolean, is String -> value.toString()
            else -> null
        }
    }

    private fun projectEmbeddedJson(
        template: Any,
        consentInput: JSONObject,
        rowObj: JSONObject?,
        choice: Any?
    ): Any = when (template) {
        is JSONObject -> {
            val obj = JSONObject()
            for (k in template.keys()) {
                val v = template.get(k)
                obj.put(k, projectJsonValue(v, consentInput, rowObj, choice))
            }
            obj
        }
        is JSONArray -> {
            val arr = JSONArray()
            for (i in 0 until template.length()) {
                arr.put(projectJsonValue(template.get(i), consentInput, rowObj, choice))
            }
            arr
        }
        else -> projectJsonValue(template, consentInput, rowObj, choice)
    }

    private fun projectJsonValue(
        v: Any,
        consentInput: JSONObject,
        rowObj: JSONObject?,
        choice: Any?
    ): Any = when (v) {
        is JSONObject -> {
            if (v.has("\$input")) {
                consentInput.opt(v.getString("\$input")) ?: JSONObject.NULL
            } else if (v.has("\$row")) {
                rowObj?.opt(v.getString("\$row")) ?: JSONObject.NULL
            } else if (v.optBoolean("\$choice", false)) {
                choice ?: JSONObject.NULL
            } else {
                projectEmbeddedJson(v, consentInput, rowObj, choice)
            }
        }
        is JSONArray -> projectEmbeddedJson(v, consentInput, rowObj, choice)
        else -> v
    }
}

data class PortBindingPolicy(
    val bindingVersion: Int,
    val pluginId: String,
    val identityProbe: PortIdentityProbe?,
    val rules: List<PortWriteRule>,
    val consentScopes:JSONObject = JSONObject()
)

data class BoundPackage(
    val pluginId: String,
    val archiveHash: String,
    val manifest: JSONObject,
    val policy: PortBindingPolicy?,
    val rawPolicyJson: String?,
    val boundAt: Long
)

object PortDescriptorParser {

    /**
     * Parses RFC 6901 JSON pointer against a JSON root structure in pure Kotlin.
     */
    fun evaluateJsonPointer(root: Any, pointer: String): Any? {
        if (pointer.isEmpty()) return root
        if (!pointer.startsWith("/")) return null
        val tokens = pointer.substring(1).split("/").map {
            it.replace("~1", "/").replace("~0", "~")
        }
        var current: Any? = root
        for (token in tokens) {
            if (current == null) return null
            when (current) {
                is JSONObject -> {
                    if (!current.has(token)) return null
                    current = current.get(token)
                }
                is JSONArray -> {
                    val index = token.toIntOrNull() ?: return null
                    if (index < 0 || index >= current.length()) return null
                    current = current.get(index)
                }
                else -> return null
            }
        }
        return if (current === JSONObject.NULL) null else current
    }

    /**
     * Strict deep structural equality without type broadening.
     */
    fun compareValues(expected: Any?, actual: Any?): Boolean {
        if (expected == null || expected === JSONObject.NULL) {
            return actual == null || actual === JSONObject.NULL
        }
        if (actual == null || actual === JSONObject.NULL) return false

        // If expected is an embedded JSON structure and actual is a JSON string, parse actual
        if ((expected is JSONObject || expected is JSONArray) && actual is String) {
            val parsedActual = try {
                if (actual.trim().startsWith("[")) JSONArray(actual) else JSONObject(actual)
            } catch (_: Exception) {
                return false
            }
            return compareValues(expected, parsedActual)
        }

        return when {
            expected is JSONObject && actual is JSONObject -> {
                val expKeys = expected.keys().asSequence().toSet()
                val actKeys = actual.keys().asSequence().toSet()
                if (expKeys != actKeys) return false
                for (k in expKeys) {
                    if (!compareValues(expected.get(k), actual.get(k))) return false
                }
                true
            }
            expected is JSONArray && actual is JSONArray -> {
                if (expected.length() != actual.length()) return false
                for (i in 0 until expected.length()) {
                    if (!compareValues(expected.get(i), actual.get(i))) return false
                }
                true
            }
            expected is Number && actual is Number -> {
                if (expected is Double || expected is Float || actual is Double || actual is Float) {
                    expected.toDouble() == actual.toDouble()
                } else {
                    expected.toLong() == actual.toLong()
                }
            }
            expected is Boolean && actual is Boolean -> expected == actual
            expected is String && actual is String -> expected == actual
            else -> false
        }
    }

    /**
     * Parses binding_v1 or host-policy.json into PortBindingPolicy.
     */
    fun parsePolicy(policyJson: JSONObject): PortBindingPolicy {
        val root = when {
            policyJson.has("binding_v1") -> policyJson.getJSONObject("binding_v1")
            policyJson.has("plugin_policy") -> policyJson.getJSONObject("plugin_policy").optJSONObject("binding_v1") ?: policyJson
            else -> policyJson
        }

        val pluginId = root.optString("plugin_id").ifEmpty { policyJson.optString("plugin_id") }
        if (pluginId.isBlank()) throw PortError("InvalidPolicyPluginId")

        val probe = parseIdentityProbe(root.optJSONObject("identity_probe") ?: policyJson.optJSONObject("identity_probe"))
        if(root.optInt("binding_version",-1)!=1) throw PortError("UnsupportedPolicyVersion")
        val rules = parseRules(root)

        return PortBindingPolicy(
            bindingVersion = root.optInt("binding_version", 1),
            pluginId = pluginId,
            identityProbe = probe,
            rules = rules,
            consentScopes = root.optJSONObject("consent_scopes") ?: JSONObject()
        )
    }

    private fun parseIdentityProbe(probeObj: JSONObject?): PortIdentityProbe? {
        if (probeObj == null) return null
        val url = probeObj.optString("url").ifEmpty {
            val entryPage = probeObj.optString("entry_page")
            val probePath = probeObj.optString("probe_path")
            if (entryPage.isNotEmpty() && probePath.isNotEmpty()) {
                val base = origin(entryPage)
                base + (if (probePath.startsWith("/")) probePath else "/$probePath")
            } else ""
        }
        if (!url.startsWith("https://") || java.net.URI(url).userInfo != null || java.net.URI(url).fragment != null) return null
        val headers = probeObj.optJSONObject("headers") ?: JSONObject()
        require(headers.keys().asSequence().all { it.lowercase(java.util.Locale.ROOT) in setOf("accept","sign-key") &&
            headers.get(it) is String && !headers.getString(it).contains(Regex("[\\r\\n]")) })

        val topLevelOrigin = probeObj.optString("top_level_origin").ifEmpty { origin(url) }
        val jsonPointer = probeObj.optString("json_pointer").takeIf { it.isNotEmpty() }

        return PortIdentityProbe(
            url = url,
            method = probeObj.optString("method", "GET").uppercase(),
            topLevelOrigin = topLevelOrigin,
            jsonPointer = jsonPointer,
            successPointer = probeObj.optString("success_pointer").takeIf { it.isNotBlank() },
            successValue = probeObj.optString("success_value").takeIf { it.isNotBlank() },
            headers = headers
        )
    }

    private fun parseRules(root:JSONObject):List<PortWriteRule> {
        val rules=root.optJSONArray("rules") ?: return emptyList()
        require(rules.length()<=64)
        return (0 until rules.length()).map { index ->
            val r=rules.getJSONObject(index)
            val url=r.getString("url"); val uri=java.net.URI(url)
            require(uri.scheme=="https" && uri.host!=null && uri.userInfo==null && uri.fragment==null)
            val transport=r.getString("transport"); require(transport=="xhr" || transport=="fetch")
            val headers=r.getJSONObject("headers")
            val tokens=r.getJSONArray("key")
            require(tokens.length() in 1..32)
            val key=(0 until tokens.length()).map { i->
                val t=tokens.get(i)
                if(t is String) PortKeyToken.Literal(t) else {
                    t as JSONObject; require(t.length()==1)
                    when {
                        t.has("\$input")->PortKeyToken.InputRef(t.getString("\$input"))
                        t.has("\$row")->PortKeyToken.RowRef(t.getString("\$row"))
                        t.opt("\$choice")==true->PortKeyToken.ChoiceRef
                        t.opt("\$positiveInteger")==true->PortKeyToken.PositiveInteger
                        else->throw PortError("InvalidBindingTemplate")
                    }
                }
            }
            val fields=r.getJSONObject("form")
            val rows=r.optString("rows").takeIf{it.isNotBlank()}
            val choices=r.optString("choices").takeIf{it.isNotBlank()}
            require((rows==null)==(choices==null))
            PortWriteRule(r.getString("action"),url,transport,headers.keys().asSequence().associateWith{headers.getString(it)},
                key,rows,choices,fields.keys().asSequence().associateWith{parseFormTemplate(fields.get(it))})
        }
    }

    private fun parseFormTemplate(v: Any): PortFormTemplate = when (v) {
        is JSONObject -> {
            when {
                v.has("\$json") -> PortFormTemplate.EmbeddedJson(v.get("\$json"))
                v.has("\$text") -> PortFormTemplate.Text(parseFormTemplate(v.get("\$text")))
                v.has("\$input") -> PortFormTemplate.InputRef(v.getString("\$input"))
                v.has("\$row") -> PortFormTemplate.RowRef(v.getString("\$row"))
                v.optBoolean("\$choice", false) -> PortFormTemplate.ChoiceRef
                else -> PortFormTemplate.Literal(v)
            }
        }
        else -> PortFormTemplate.Literal(v)
    }
}
