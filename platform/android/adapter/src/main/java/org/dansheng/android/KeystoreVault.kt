// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Host-only persistent credential port. Values are opaque JSON strings, never logged.
 * Ciphertext is in app-private preferences; the AES key remains in AndroidKeyStore.
 * The application must disable cloud/device backup of this preferences file.
 */
class KeystoreVault(context: Context) : PlatformDispatcher {
    override val capabilities = setOf("vault.set", "vault.get", "vault.delete")
    private val prefs = context.getSharedPreferences("dansheng-vault-v1", Context.MODE_PRIVATE)
    companion object {
        private const val ALIAS = "org.dansheng.vault.aes-gcm.v1"
        private val lock = Any()
    }
    private fun storageKey(key: String): String {
        if (key.isBlank() || key.length > 1024) throw PortError("InvalidVaultKey")
        return MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
    private fun secret(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        // Lost/invalidated keys must not silently become an empty/new vault.
        if (!create || prefs.all.isNotEmpty()) throw PortError("VaultKeyUnavailable")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    fun set(key: String, value: String) = synchronized(lock) {
        val name = storageKey(key)
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size > 256 * 1024) throw PortError("VaultValueTooLarge")
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret(true))
            cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(bytes)
            val blob = JSONObject().put("v", 1).put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP)).toString()
            if (!prefs.edit().putString(name, blob).commit()) throw PortError("VaultStorageError")
        } catch (e: PortError) { throw e }
        catch (_: Exception) { throw PortError("VaultUnavailable") }
        finally { bytes.fill(0) }
    }
    fun contains(key: String): Boolean = prefs.contains(storageKey(key))
    fun get(key: String): String? = synchronized(lock) {
        val name = storageKey(key)
        val blob = prefs.getString(name, null) ?: return@synchronized null
        try {
            val json = JSONObject(blob)
            if (json.getInt("v") != 1) throw PortError("VaultUnavailable")
            val iv = Base64.decode(json.getString("iv"), Base64.NO_WRAP)
            if (iv.size != 12) throw PortError("VaultUnavailable")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret(false), GCMParameterSpec(128, iv))
            cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
            val bytes = cipher.doFinal(Base64.decode(json.getString("ciphertext"), Base64.NO_WRAP))
            try { bytes.toString(Charsets.UTF_8) } finally { bytes.fill(0) }
        } catch (e: PortError) { throw e }
        catch (_: Exception) { throw PortError("VaultUnavailable") }
    }
    fun delete(key: String) = synchronized(lock) {
        if (!prefs.edit().remove(storageKey(key)).commit()) throw PortError("VaultStorageError")
    }
    override fun dispatch(capability: String, mediated: JSONObject, reply: PortReply) {
        try {
            // Core-internal vault calls are {key,value}, unlike browser mediation.
            // Accept that shape ONLY on this trusted PlatformDispatcher/C-queue port.
            // If a principal envelope is supplied, it must be the trusted owner.
            val input = if (mediated.has("principal")) {
                val principal = mediated.getJSONObject("principal")
                if (principal.optString("kind") != "owner" || principal.optString("id") != "owner") throw PortError("PermissionDenied")
                mediated.getJSONObject("input")
            } else {
                if (mediated.has("input") || !mediated.has("key")) throw PortError("InvalidPlatformEnvelope")
                mediated
            }
            val key = input.getString("key")
            val result = when (capability) {
                "vault.set" -> {
                    if (!input.has("value")) throw PortError("InvalidInput")
                    // Preserve JSON type: core session exports are arrays, not strings.
                    set(key, JSONObject().put("value", input.get("value")).toString())
                    JSONObject().put("stored", true)
                }
                "vault.get" -> {
                    val encoded = get(key)
                    if (encoded == null) JSONObject().put("value", JSONObject.NULL) else JSONObject(encoded)
                }
                "vault.delete" -> { delete(key); JSONObject().put("deleted", true) }
                else -> throw PortError("CapabilityUnavailable")
            }
            reply(Result.success(result))
        } catch (e: Exception) { reply(Result.failure(if (e is PortError) e else PortError("VaultUnavailable"))) }
    }
}

/** Combine only installed providers. Pass this exact capability set to dansheng_open. */
class CompositeDispatcher(private vararg val providers: PlatformDispatcher) : PlatformDispatcher {
    override val capabilities: Set<String> = providers.flatMap { it.capabilities }.toSet()
    override fun dispatch(capability: String, mediated: JSONObject, reply: PortReply) {
        val provider = providers.singleOrNull { capability in it.capabilities }
        if (provider == null) reply(Result.failure(PortError("CapabilityUnavailable")))
        else provider.dispatch(capability, mediated, reply)
    }
}
