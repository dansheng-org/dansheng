// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PortRuntimeTest {

    @Test
    fun testPortUtilsSha256AndCanonicalJson() {
        val json = JSONObject().put("b", 2).put("a", 1)
        val canonical = PortUtils.canonicalJson(json)
        assertEquals("{\"a\":1,\"b\":2}", canonical)

        val hash = PortUtils.sha256(canonical.toByteArray(Charsets.UTF_8))
        assertNotNull(hash)
        assertEquals(64, hash.length)

        // Null handling
        assertEquals("null", PortUtils.canonicalJson(null))
        assertEquals("null", PortUtils.canonicalJson(JSONObject.NULL))

        // Array sorting preserved
        val arr = JSONArray().put("z").put("a")
        assertEquals("[\"z\",\"a\"]", PortUtils.canonicalJson(arr))
    }

    @Test
    fun testEvaluateJsonPointerRfc6901() {
        val json = JSONObject("""
            {
                "user": {
                    "id": "student_12345",
                    "details": {
                        "name": "Test User",
                        "tags": ["active", "student"]
                    }
                },
                "status": "OK",
                "code": 200,
                "escaped/key": "val1",
                "tilde~key": "val2"
            }
        """.trimIndent())

        assertEquals("student_12345", PortDescriptorParser.evaluateJsonPointer(json, "/user/id"))
        assertEquals("Test User", PortDescriptorParser.evaluateJsonPointer(json, "/user/details/name"))
        assertEquals("active", PortDescriptorParser.evaluateJsonPointer(json, "/user/details/tags/0"))
        assertEquals("student", PortDescriptorParser.evaluateJsonPointer(json, "/user/details/tags/1"))
        assertEquals("OK", PortDescriptorParser.evaluateJsonPointer(json, "/status"))
        assertEquals(200, PortDescriptorParser.evaluateJsonPointer(json, "/code"))

        // Escaped tokens: ~1 is /, ~0 is ~
        assertEquals("val1", PortDescriptorParser.evaluateJsonPointer(json, "/escaped~1key"))
        assertEquals("val2", PortDescriptorParser.evaluateJsonPointer(json, "/tilde~0key"))

        // Missing pointers return null
        assertNull(PortDescriptorParser.evaluateJsonPointer(json, "/nonexistent"))
        assertNull(PortDescriptorParser.evaluateJsonPointer(json, "/user/missing"))
        assertNull(PortDescriptorParser.evaluateJsonPointer(json, "/user/details/tags/5"))
        assertNull(PortDescriptorParser.evaluateJsonPointer(json, "invalid_pointer_without_slash"))
    }

    @Test
    fun testCompareValuesStrictWithoutBroadenedTypes() {
        // Primitive equality
        assertTrue(PortDescriptorParser.compareValues("test", "test"))
        assertFalse(PortDescriptorParser.compareValues("test", "other"))
        assertTrue(PortDescriptorParser.compareValues(123, 123L))
        assertFalse(PortDescriptorParser.compareValues(123, 124))
        assertTrue(PortDescriptorParser.compareValues(true, true))
        assertFalse(PortDescriptorParser.compareValues(true, false))

        // Type mismatches must fail
        assertFalse(PortDescriptorParser.compareValues("123", 123))
        assertFalse(PortDescriptorParser.compareValues(true, "true"))

        // Structural deep equality
        val obj1 = JSONObject("""{"a": 1, "b": [10, 20]}""")
        val obj2 = JSONObject("""{"b": [10, 20], "a": 1}""")
        assertTrue(PortDescriptorParser.compareValues(obj1, obj2))

        val obj3 = JSONObject("""{"a": 1, "b": [10, 99]}""")
        assertFalse(PortDescriptorParser.compareValues(obj1, obj3))

        // Extra key in actual must fail
        val objExtra = JSONObject("""{"a": 1, "b": [10, 20], "c": 3}""")
        assertFalse(PortDescriptorParser.compareValues(obj1, objExtra))
    }

    @Test
    fun testParseBindingV1Policy() {
        val policyJson = JSONObject("""
            {
                "binding_v1": {
                    "binding_version": 1,
                    "plugin_id": "test.plugin",
                    "identity_probe": {
                        "url": "https://service.example/api/whoami",
                        "method": "GET",
                        "top_level_origin": "https://service.example",
                        "json_pointer": "/account_id"
                    },
                    "rules": [
                        {
                            "action": "schedule",
                            "url": "https://service.example/api/launch",
                            "transport": "xhr",
                            "headers": {
                                "Accept": "application/json",
                                "sign-key": "launchpost"
                            },
                            "key": [
                                "task",
                                {"${'$'}input": "account_id"},
                                {"${'$'}input": "task_id"},
                                {"${'$'}positiveInteger": true},
                                {"${'$'}row": "period_id"},
                                {"${'$'}choice": true}
                            ],
                            "rows": "plans",
                            "choices": "courts",
                            "form": {
                                "data": {
                                    "${'$'}json": [
                                        {
                                            "venue_id": {"${'$'}input": "venue_id"},
                                            "court_id": {"${'$'}choice": true},
                                            "period_id": {"${'$'}row": "period_id"}
                                        }
                                    ]
                                },
                                "collective": "0"
                            }
                        }
                    ]
                }
            }
        """.trimIndent())

        val policy = PortDescriptorParser.parsePolicy(policyJson)
        assertEquals(1, policy.bindingVersion)
        assertEquals("test.plugin", policy.pluginId)
        assertNotNull(policy.identityProbe)
        assertEquals("https://service.example/api/whoami", policy.identityProbe?.url)
        assertEquals("/account_id", policy.identityProbe?.jsonPointer)

        assertEquals(1, policy.rules.size)
        val rule = policy.rules[0]
        assertEquals("schedule", rule.action)
        assertEquals("https://service.example/api/launch", rule.url)
        assertEquals("xhr", rule.transport)
        assertEquals("launchpost", rule.headers["sign-key"])
        assertEquals("plans", rule.rowsField)
        assertEquals("courts", rule.choicesField)
        assertEquals(6, rule.keyTokens.size)
        assertEquals(2, rule.formFields.size)
    }

    @Test
    fun testDeclarativeTemplateProjectionMatchingAndTamperRejection() {
        val policyJson = JSONObject("""
            {
                "binding_version": 1,
                "plugin_id": "official.sports",
                "rules": [
                    {
                        "action": "schedule",
                        "url": "https://booking.example/launch",
                        "transport": "xhr",
                        "headers": {
                            "Accept": "application/json",
                            "sign-key": "launchpost"
                        },
                        "key": [
                            "task",
                            {"${'$'}input": "account_id"},
                            {"${'$'}input": "task_id"},
                            {"${'$'}positiveInteger": true},
                            {"${'$'}row": "period_id"},
                            {"${'$'}choice": true}
                        ],
                        "rows": "plans",
                        "choices": "courts",
                        "form": {
                            "data": {
                                "${'$'}json": [
                                    {
                                        "group_id": {"${'$'}input": "venue_id"},
                                        "resource_ids": [{"${'$'}choice": true}],
                                        "period": [
                                            {
                                                "date": {"${'$'}input": "target_date"},
                                                "period_id": {"${'$'}row": "period_id"}
                                            }
                                        ],
                                        "number": 1
                                    }
                                ]
                            },
                            "data_colle": "[]",
                            "collective": "0"
                        }
                    }
                ]
            }
        """.trimIndent())

        val policy = PortDescriptorParser.parsePolicy(policyJson)
        val rule = policy.rules[0]

        val consentInput = JSONObject("""
            {
                "account_id": "student_a",
                "task_id": "plan_101",
                "venue_id": 900,
                "target_date": "2026-11-10",
                "release_at": "2026-11-09T00:00:00Z",
                "options": {
                    "windowMs": 300000
                },
                "plans": [
                    {
                        "time": "10:00-11:00",
                        "period_id": 70,
                        "courts": [901, 902]
                    }
                ]
            }
        """.trimIndent())

        // 1. Valid request for choice 901, round 1
        val validKey = "task:student_a:plan_101:1:70:901"
        val validForm = JSONObject()
            .put("data", "[{\"group_id\":900,\"resource_ids\":[901],\"period\":[{\"date\":\"2026-11-10\",\"period_id\":70}],\"number\":1}]")
            .put("data_colle", "[]")
            .put("collective", "0")

        assertTrue("Valid projection must match", rule.matches(consentInput, validKey, validForm))

        // 2. Valid request for choice 902, round 5
        val validKey2 = "task:student_a:plan_101:5:70:902"
        val validForm2 = JSONObject()
            .put("data", "[{\"group_id\":900,\"resource_ids\":[902],\"period\":[{\"date\":\"2026-11-10\",\"period_id\":70}],\"number\":1}]")
            .put("data_colle", "[]")
            .put("collective", "0")

        assertTrue("Valid projection for second choice must match", rule.matches(consentInput, validKey2, validForm2))

        // 3. Tampered choice (court 999 not in consent courts [901, 902])
        val tamperedChoiceKey = "task:student_a:plan_101:1:70:999"
        val tamperedChoiceForm = JSONObject()
            .put("data", "[{\"group_id\":900,\"resource_ids\":[999],\"period\":[{\"date\":\"2026-11-10\",\"period_id\":70}],\"number\":1}]")
            .put("data_colle", "[]")
            .put("collective", "0")

        assertFalse("Tampered choice must be rejected", rule.matches(consentInput, tamperedChoiceKey, tamperedChoiceForm))

        // 4. Tampered venue ID (999 instead of 900)
        val tamperedVenueForm = JSONObject()
            .put("data", "[{\"group_id\":999,\"resource_ids\":[901],\"period\":[{\"date\":\"2026-11-10\",\"period_id\":70}],\"number\":1}]")
            .put("data_colle", "[]")
            .put("collective", "0")

        assertFalse("Tampered venue ID must be rejected", rule.matches(consentInput, validKey, tamperedVenueForm))

        // 5. Extra unmapped field (default deny)
        val extraFieldForm = JSONObject(validForm.toString()).put("malicious_extra_field", "value")
        assertFalse("Extra body/form fields must be rejected by default deny", rule.matches(consentInput, validKey, extraFieldForm))

        // 6. Non-finite or negative round
        val invalidRoundKey = "task:student_a:plan_101:0:70:901"
        assertFalse("Round 0 must be rejected", rule.matches(consentInput, invalidRoundKey, validForm))

        val negativeRoundKey = "task:student_a:plan_101:-1:70:901"
        assertFalse("Negative round must be rejected", rule.matches(consentInput, negativeRoundKey, validForm))
    }

    @Test
    fun testCancelAppointmentProjectionMatching() {
        val policyJson = JSONObject("""
            {
                "binding_version": 1,
                "plugin_id": "official.sports",
                "rules": [
                    {
                        "action": "cancelAppointment",
                        "url": "https://booking.example/cancel",
                        "transport": "xhr",
                        "headers": {
                            "Accept": "application/json"
                        },
                        "key": [
                            "cancel",
                            {"${'$'}input": "account_id"},
                            {"${'$'}input": "appointment_id"}
                        ],
                        "form": {
                            "appointment_id": {"${'$'}input": "appointment_id"},
                            "appointment_detail_id": {"${'$'}input": "appointment_detail_id"},
                            "appointment_data_ids": {"${'$'}input": "appointment_data_ids"}
                        }
                    }
                ]
            }
        """.trimIndent())

        val policy = PortDescriptorParser.parsePolicy(policyJson)
        val rule = policy.rules[0]

        val consentInput = JSONObject("""
            {
                "account_id": "student_a",
                "appointment_id": "5566",
                "appointment_detail_id": "[101]",
                "appointment_data_ids": "[]"
            }
        """.trimIndent())

        val validKey = "cancel:student_a:5566"
        val validForm = JSONObject()
            .put("appointment_id", "5566")
            .put("appointment_detail_id", "[101]")
            .put("appointment_data_ids", "[]")

        assertTrue("Valid cancel request must match", rule.matches(consentInput, validKey, validForm))

        // Mismatched appointment ID in key or form
        val mismatchedKey = "cancel:student_a:9999"
        assertFalse("Mismatched appointment key must fail", rule.matches(consentInput, mismatchedKey, validForm))

        val mismatchedForm = JSONObject(validForm.toString()).put("appointment_id", "9999")
        assertFalse("Mismatched appointment form must fail", rule.matches(consentInput, validKey, mismatchedForm))
    }

    @Test
    fun unknownPolicyCannotImplicitlyGrantAWritingRule() {
        val descriptor = JSONObject().put("plugin_id","example.local")
            .put("permitted_writes",JSONObject().put("rules",org.json.JSONArray().put(JSONObject().put("action","save"))))
        val error = runCatching { PortDescriptorParser.parsePolicy(descriptor) }.exceptionOrNull()
        assertEquals("UnsupportedPolicyVersion",(error as org.dansheng.android.PortError).code)
    }
}
