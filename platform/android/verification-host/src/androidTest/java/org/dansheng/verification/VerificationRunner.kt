// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.verification

import android.app.Activity
import android.os.Bundle
import android.test.InstrumentationTestRunner
import org.dansheng.android.KeystoreVault

/** Ordinary offline suite, plus an explicit two-process Keystore persistence probe. */
@Suppress("DEPRECATION")
class VerificationRunner : InstrumentationTestRunner() {
    private var phase: String? = null
    override fun onCreate(arguments: Bundle?) { phase = arguments?.getString("vault_phase"); super.onCreate(arguments) }
    override fun onStart() {
        if (phase == null) { super.onStart(); return }
        val output = Bundle().apply { putInt("pid", android.os.Process.myPid()) }
        try {
            val vault = KeystoreVault(targetContext)
            when (phase) {
                "seed" -> vault.set("fixture-process-restart", "synthetic-process-restart-value")
                "check" -> {
                    check(vault.get("fixture-process-restart") == "synthetic-process-restart-value")
                    vault.delete("fixture-process-restart")
                    check(KeystoreVault(targetContext).get("fixture-process-restart") == null)
                }
                else -> error("unknown probe phase")
            }
            output.putString("result", "passed"); finish(Activity.RESULT_OK, output)
        } catch (_: Exception) { output.putString("result", "failed"); finish(Activity.RESULT_CANCELED, output) }
    }
}
