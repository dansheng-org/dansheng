// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

import org.junit.Assert.*
import org.junit.Test

class PolicyTest {
    private fun error(code: String, f: () -> Unit) {
        try { f(); fail("expected $code") } catch (e: PortError) { assertEquals(code, e.code) }
    }
    @Test fun crossAccountHandlesAndRevocation() {
        val ledger = SessionLedger(); val s = ledger.issue("a", "https://example.invalid/")
        error("SessionOwnershipMismatch") { ledger.require("b", s.handle) }
        error("SessionOwnershipMismatch") { ledger.require("a", "forged") }
        error("AccountBusy") { ledger.issue("b", "https://example.invalid/") }
        ledger.beginReset()
        error("SessionResetting") { ledger.issue("b", "https://example.invalid/") }
        ledger.finishReset(); val b = ledger.issue("b", "https://example.invalid/")
        assertNotEquals(s.handle, b.handle)
        error("SessionOwnershipMismatch") { ledger.require("b", s.handle) }
    }
    @Test fun grantsAreAccountOriginAndExpiryScoped() {
        val grant = Authority("plugin:test", false, setOf("browser.request"), setOf("a"), setOf("https://example.invalid"), 20)
        grant.check("browser.request", "a", "https://example.invalid/a", 19)
        error("PermissionDenied") { grant.check("browser.request", "a", "https://example.invalid", 20) }
        error("PermissionDenied") { grant.check("browser.request", "b", "https://example.invalid", 0) }
        error("PermissionDenied") { grant.check("browser.evaluate", "a", "https://example.invalid", 0) }
        error("PermissionDenied") { grant.check("browser.request", "a", "https://evil.invalid", 0) }
        error("InvalidUrl") { origin("https://user:password@example.invalid/") }
        error("InvalidUrl") { origin("file:///private") }
        error("InvalidUrl") { origin("https://example.invalid/../secret") }
    }
    @Test fun wakeRequiresCurrentAccountGenerationAndDeadline() {
        val wake = WakeSpec("j", "a", "plugin:test", 100, 200, "new")
        assertFalse(wake.mayRun(99, "a", "new")); assertTrue(wake.mayRun(100, "a", "new"))
        assertFalse(wake.mayRun(200, "a", "new")); assertFalse(wake.mayRun(110, "b", "new"))
        assertFalse(wake.mayRun(110, "a", "old")); assertFalse(wake.mayRun(110, null, "new"))
        error("DeadlineExceeded") { wake.validate(200) }
        error("InvalidWake") { wake.copy(deadline = 100).validate(0) }
    }
    @Test fun rollbackCannotExtendMonotonicDeadline() {
        val d = Deadline(200, 100, 1000)
        assertEquals(50L, d.remaining(150, 1050))
        assertEquals(0L, d.remaining(0, 1100))
        assertEquals(0L, d.remaining(200, 1001))
    }
    @Test fun prepareTimeDoesNotReplaceExecutionTimeOrAccountScope() {
        val s = WakeSpec("generic", null, "owner", 100, 300, "generation", executeAt = 200, precision = "inexact")
        s.validate(0)
        assertTrue(s.mayRun(100, null, "generation"))
        assertEquals(200L, s.executeAt)
        error("InvalidWake") { s.copy(executeAt = 99).validate(0) }
        error("InvalidWake") { s.copy(deadline = 200).validate(0) }
        error("InvalidWake") { s.copy(precision = "pretend-exact").validate(0) }
    }
}
