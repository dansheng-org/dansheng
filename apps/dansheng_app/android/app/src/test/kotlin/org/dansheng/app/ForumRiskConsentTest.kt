// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import kotlinx.coroutines.runBlocking
import org.dansheng.android.PortError
import org.junit.Assert.*
import org.junit.Test

class ForumRiskConsentTest {
    private val versions = mutableMapOf<String, Int>()
    private fun consent() = ForumRiskConsent(
        readVersion = { versions[it] ?: 0 },
        writeVersion = { account, version ->
            if (version == null) versions.remove(account) else versions[account] = version
        },
    )

    private fun expectCode(expected: String, block: suspend () -> Unit) = runBlocking {
        try {
            block()
            fail("expected $expected")
        } catch (error: PortError) {
            assertEquals(expected, error.code)
        }
    }

    @Test fun oldAccountsCannotRestoreOrReadUntilAcknowledged() {
        val gate = consent()
        for (version in listOf(0, ForumRiskConsent.VERSION + 1)) {
            versions["account-a"] = version
            expectCode("ForumConsentRequired") { gate.requireAccepted("account-a") }
            expectCode("ForumConsentRequired") {
                gate.authorize("account-a", null) { it() }
            }
        }
    }

    @Test fun cancellationDoesNotAuthorizeOrContinueLogin() {
        var continued = false
        expectCode("Cancelled") {
            consent().authorize("account-a", { throw PortError("Cancelled") }) { it() }
            continued = true
        }
        assertFalse(continued)
        assertTrue(versions.isEmpty())
    }

    @Test fun acceptanceIsAccountScopedAndSurvivesGateRecreation() = runBlocking {
        var confirmed = 0
        consent().authorize("account-a", { confirmed++ }) { it() }
        assertEquals(1, confirmed)
        val restored = consent()
        restored.authorize("account-a", null) { it() }
        restored.requireAccepted("account-a")
        expectCode("ForumConsentRequired") { restored.requireAccepted("account-b") }
        restored.forget("account-a")
        expectCode("ForumConsentRequired") { restored.requireAccepted("account-a") }
    }

    @Test fun explicitLoginAlwaysRequiresFreshConfirmation() = runBlocking {
        versions["account-a"] = ForumRiskConsent.VERSION
        var confirmed = 0
        consent().authorize("account-a", { confirmed++ }) { it() }
        assertEquals(1, confirmed)
        expectCode("Cancelled") {
            consent().authorize("account-a", { throw PortError("Cancelled") }) { it() }
        }
    }

    @Test fun accountChangeWhileNoticeIsOpenDoesNotSaveConsent() {
        var active = true
        expectCode("AccountChanged") {
            consent().authorize("account-a", { active = false }) { action ->
                if (!active) throw PortError("AccountChanged")
                action()
            }
        }
        assertTrue(versions.isEmpty())
    }

    @Test fun storageFailureStopsLogin() {
        val gate = ForumRiskConsent({ 0 }, { _, _ -> throw PortError("StorageUnavailable") })
        var continued = false
        expectCode("StorageUnavailable") {
            gate.authorize("account-a", {}) { it() }
            continued = true
        }
        assertFalse(continued)
    }
}
