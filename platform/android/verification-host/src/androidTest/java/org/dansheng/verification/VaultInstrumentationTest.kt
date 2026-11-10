// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.content.Context
import android.test.InstrumentationTestCase
import org.dansheng.android.KeystoreVault
import org.dansheng.android.PortError
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

@Suppress("DEPRECATION")
class VaultInstrumentationTest : InstrumentationTestCase() {
    fun testEncryptedReopenDeleteAndNoPlaintextFallback() {
        val context = instrumentation.targetContext
        val key = "synthetic-" + UUID.randomUUID()
        val marker = "synthetic-secret-marker-" + UUID.randomUUID()
        val vault = KeystoreVault(context)
        assertNull(vault.get(key)); vault.set(key, marker)
        assertEquals(marker, KeystoreVault(context).get(key))
        val prefs = context.getSharedPreferences("dansheng-vault-v1", Context.MODE_PRIVATE)
        assertFalse(prefs.all.toString().contains(marker)); assertFalse(prefs.all.toString().contains(key))
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        val firstCiphertext = prefs.getString(digest, null)
        vault.set(key, marker)
        assertNotSame(firstCiphertext, prefs.getString(digest, null))
        prefs.edit().putString(digest, "tampered-synthetic-ciphertext").commit()
        try { KeystoreVault(context).get(key); fail("tampered vault must fail closed") }
        catch (e: PortError) { assertEquals("VaultUnavailable", e.code) }
        vault.delete(key); assertNull(KeystoreVault(context).get(key))
    }
    fun testCiphertextCannotBeMovedToAnotherKeyAndPluginCannotReadCredentials() {
        val context = instrumentation.targetContext
        val a = "fixture-a-" + UUID.randomUUID(); val b = "fixture-b-" + UUID.randomUUID()
        val vault = KeystoreVault(context); vault.set(a, "synthetic-json-value")
        fun digest(key: String) = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        val prefs = context.getSharedPreferences("dansheng-vault-v1", Context.MODE_PRIVATE)
        prefs.edit().putString(digest(b), prefs.getString(digest(a), null)).commit()
        try { vault.get(b); fail("AAD key binding must reject swapped ciphertext") }
        catch (e: PortError) { assertEquals("VaultUnavailable", e.code) }
        var code = ""
        vault.dispatch("vault.get", JSONObject().put("principal", JSONObject().put("id", "plugin:fixture").put("kind", "plugin"))
            .put("input", JSONObject().put("key", a))) { code = (it.exceptionOrNull() as PortError).code }
        assertEquals("PermissionDenied", code)
        vault.delete(a); vault.delete(b)
    }
    fun testCoreInternalJsonShapePreservesSessionArrayAndMissingNull() {
        val vault = KeystoreVault(instrumentation.targetContext)
        val key = "fixture-json-" + UUID.randomUUID()
        val value = org.json.JSONArray().put(JSONObject().put("origin", "https://fixture.invalid").put("bearer", "synthetic-value").put("cookie_store", org.json.JSONArray()))
        var reply: JSONObject? = null
        vault.dispatch("vault.set", JSONObject().put("key", key).put("value", value)) { reply = it.getOrThrow() }
        assertTrue(reply!!.getBoolean("stored"))
        KeystoreVault(instrumentation.targetContext).dispatch("vault.get", JSONObject().put("key", key)) { reply = it.getOrThrow() }
        assertEquals(value.toString(), reply!!.getJSONArray("value").toString())
        vault.dispatch("vault.delete", JSONObject().put("key", key)) { reply = it.getOrThrow() }
        vault.dispatch("vault.get", JSONObject().put("key", key)) { reply = it.getOrThrow() }
        assertTrue(reply!!.isNull("value"))
    }
}
