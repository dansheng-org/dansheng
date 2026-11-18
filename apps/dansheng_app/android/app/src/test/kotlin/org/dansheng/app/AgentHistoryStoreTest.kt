// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentHistoryStoreTest {
    private val data = mutableMapOf<String, String>()
    private var failWrite: (String) -> Boolean = { false }
    private var failRemove: (String) -> Boolean = { false }
    private val store = AgentHistoryStore(data::get, data::containsKey, { key, value ->
        data[key] = value
        if (failWrite(key)) error("commit failure after in-memory write")
    }, { key ->
        data.remove(key)
        if (failRemove(key)) error("commit failure after in-memory removal")
    })

    @Test fun accountMustMatchExactlyAndGuestRequiresExplicitNull() {
        val id = id(1)
        save(record(id, "Guest"), create = true)
        save(record(id, "Owner"), create = true, account = "owner")
        save(record(id, "Other"), create = true, account = "guest")

        assertEquals("Guest", get(id)?.getString("title"))
        assertEquals("Owner", get(id, "owner")?.getString("title"))
        assertEquals("Other", get(id, "guest")?.getString("title"))
        assertEquals(1, list("owner").length())
        assertCode("AccountMismatch") { invoke("owner", "list", params()) }
        assertCode("AccountMismatch") { invoke("owner", "delete", params("Owner").put("id", id)) }
        assertCode("AccountMismatch") { invoke(null, "get", params("null").put("id", id)) }
        assertCode("InvalidInput") { invoke(null, "list", JSONObject()) }
        assertCode("InvalidInput") { invoke(null, "list", params().put("account_id", false)) }
        assertEquals("Owner", get(id, "owner")?.getString("title"))
    }

    @Test fun retryCreatePreservesUpdatesAndDeleteCanBeRepeated() {
        val id = id(1)
        val original = record(id, "Original")
        assertCode("ConversationMissing") { save(original, create = false) }
        assertTrue(save(original, create = true).getBoolean("saved"))
        val updated = record(id, "Updated", turn().put("answer", "Completed"))
        assertTrue(save(updated, create = false).getBoolean("saved"))
        val rename = params().put("id", id).put("title", "Renamed").put("updated_at", 123L)
        assertTrue(call("rename", rename).getBoolean("saved"))
        assertTrue(call("rename", rename).getBoolean("saved"))
        assertTrue(save(original, create = true).getBoolean("saved"))

        assertEquals("Completed", get(id)?.getJSONArray("turns")?.getJSONObject(0)?.getString("answer"))
        val summary = list().getJSONObject(0)
        assertEquals(setOf("id", "title", "updated_at"), summary.keys().asSequence().toSet())
        assertEquals("Renamed", summary.getString("title"))
        assertEquals(123L, summary.getLong("updated_at"))
        repeat(2) { assertTrue(call("delete", params().put("id", id)).getBoolean("deleted")) }
        assertNull(get(id))
        assertCode("ConversationMissing") { save(updated, create = false) }
        assertCode("ConversationMissing") { call("rename", rename) }
    }

    @Test fun failedIndexWriteRollsBackRecordAndAllowsCreateRetry() {
        val first = record(id(1), "First")
        val second = record(id(2), "Second")
        save(first, create = true)
        val before = data.toMap()
        failWrite = { it.endsWith("/index") }
        assertCode("AgentHistoryUnavailable") { save(second, create = true) }
        assertEquals(before, data)
        assertNull(get(id(2)))
        failWrite = { false }
        assertTrue(save(second, create = true).getBoolean("saved"))
        assertEquals(2, list().length())
    }

    @Test fun deletionRetriesAfterIndexFailureAndMissingPointersAreInvisible() {
        val id = id(1)
        save(record(id, "First"), create = true)
        failRemove = { it.endsWith("/index") }
        assertCode("AgentHistoryUnavailable") { call("delete", params().put("id", id)) }
        assertEquals(1, data.size)
        assertEquals(0, list().length())
        assertNull(get(id))
        assertCode("ConversationMissing") { save(record(id, "Updated"), create = false) }
        failRemove = { false }
        assertTrue(call("delete", params().put("id", id)).getBoolean("deleted"))
        assertTrue(data.isEmpty())
    }

    @Test fun capacityDoesNotEvictAndMissingPointersCanBeReclaimed() {
        repeat(100) { save(record(id(it), "Thread"), create = true) }
        assertCode("AgentHistoryFull") { save(record(id(100), "Extra"), create = true) }
        assertEquals(100, list().length())
        assertTrue(save(record(id(0), "Retry"), create = true).getBoolean("saved"))
        assertEquals("Thread", get(id(0))?.getString("title"))
        data.remove(data.keys.single { it.endsWith("/thread/${id(0)}") })
        assertEquals(99, list().length())
        save(record(id(100), "Extra"), create = true)
        assertEquals(100, list().length())
    }

    @Test fun recordLimitCountsUtf8AndAllowsFullQuestionsAndResponses() {
        val id = id(1)
        val question = "问".repeat(4000)
        val answer = "答".repeat(7000)
        save(record(id, "会话", turn(question).put("answer", answer)), create = true)
        val saved = get(id)?.getJSONArray("turns")?.getJSONObject(0)
        assertEquals(question, saved?.getString("question"))
        assertEquals(answer, saved?.getString("answer"))

        val emojiQuestion = "😀".repeat(4000)
        val destination = "OpenAI · https://example.org/" + "x".repeat(2048)
        val emojiTurn = turn(emojiQuestion).put("destination", destination)
        save(record(id, "Emoji", emojiTurn), create = false)
        assertEquals(emojiTurn.toString(), get(id)?.getJSONArray("turns")?.getJSONObject(0)?.toString())

        val boundary = record(id, "Boundary", turn().put("answer", ""))
        val bytes = 220 * 1024 - boundary.toString().toByteArray(Charsets.UTF_8).size
        val boundaryTurn = boundary.getJSONArray("turns").getJSONObject(0)
        val edge = "答".repeat(bytes / 3) + "a".repeat(bytes % 3)
        boundaryTurn.put("answer", edge)
        save(boundary, create = false)
        boundaryTurn.put("answer", edge + "a")
        assertCode("AgentConversationTooLarge") { save(boundary, create = false) }
        assertEquals("Boundary", get(id)?.getString("title"))
    }

    @Test fun rejectsUnknownFieldsAndCoercions() {
        val id = id(1)
        for (invalid in listOf(
            record("A".repeat(32), "Title"),
            record(id, "x".repeat(73)),
            record(id, "Title").put("tool_result", "hidden"),
            record(id, "Title").put("updated_at", "123"),
            record(id, "Title").put("updated_at", 2.5),
            record(id, "Title", turn().put("remember", "true")),
            record(id, "Title", turn().put("answer", JSONObject.NULL)),
            record(id, "Title", turn().put("attachments", JSONArray().put("../../data.txt"))),
            record(id, "Title", turn().put("attachments", JSONArray().put(JSONObject().put("data", "bytes")))),
            record(id, "Title", turn().put("web_links", JSONArray().put(link("http://example.org")))),
            record(id, "Title", turn().put("web_links", JSONArray().put(link("https://user@example.org")))),
            record(id, "Title", turn().put("web_links", JSONArray().put(link("https://foo_bar.example:65536")))),
            record(id, "Title", turn().put("web_links", JSONArray().put(link().put("raw", "hidden")))),
        )) {
            assertCode("InvalidInput") { save(invalid, create = true) }
        }
        assertCode("InvalidInput") {
            call("save", params().put("conversation", record(id, "Title")).put("create", "true"))
        }
        assertTrue(data.isEmpty())
        val turn = turn("").put("attachments", JSONArray().put("document.pdf"))
            .put("web_links", JSONArray().put(link()).put(link("https://foo_bar.example:8443/path")))
        save(record(id, "Title", turn), create = true)
        assertEquals(turn.toString(), get(id)?.getJSONArray("turns")?.getJSONObject(0)?.toString())
    }

    @Test fun campusLinksAreOptionalAndOnlyAcceptInternalAgentUris() {
        val id = id(1)
        save(record(id, "Legacy"), create = true)
        assertEquals(false, get(id)?.getJSONArray("turns")?.getJSONObject(0)?.has("campus_links"))

        val links = JSONArray().put(link("dansheng://agent/forum/123"))
            .put(link("dansheng://agent/course/456"))
            .put(link("dansheng://agent/assignment/456/789"))
        val turn = turn().put("campus_links", links)
        save(record(id, "Campus", turn), create = false)
        assertEquals(links.toString(), get(id)?.getJSONArray("turns")?.getJSONObject(0)
            ?.getJSONArray("campus_links")?.toString())

        for (url in listOf(
            "https://example.org/agent/forum/123",
            "dansheng://other/forum/123",
            "dansheng://user@agent/forum/123",
            "dansheng://agent:1/forum/123",
            "dansheng://agent/forum/123?",
            "dansheng://agent/forum/123#",
            "dansheng://agent/",
            "dansheng://agent/forum/" + "1".repeat(2048),
        )) {
            turn.put("campus_links", JSONArray().put(link(url)))
            assertCode("InvalidInput") { save(record(id, "Campus", turn), create = false) }
        }
        val maximum = JSONArray(List(24) { link("dansheng://agent/forum/$it") })
        save(record(id, "Campus", turn.put("campus_links", maximum)), create = false)
        maximum.put(link("dansheng://agent/forum/24"))
        assertCode("InvalidInput") { save(record(id, "Campus", turn), create = false) }
        turn.remove("campus_links")
        turn.put("web_links", links)
        assertCode("InvalidInput") { save(record(id, "Campus", turn), create = false) }
    }

    private fun save(record: JSONObject, create: Boolean, account: String? = null): JSONObject =
        call("save", params(account).put("conversation", record).put("create", create))

    private fun get(id: String, account: String? = null): JSONObject? =
        invoke(account, "get", params(account).put("id", id)) as JSONObject?

    private fun list(account: String? = null): JSONArray =
        invoke(account, "list", params(account)) as JSONArray

    private fun call(operation: String, params: JSONObject): JSONObject =
        invoke(params.opt("account_id") as? String, operation, params) as JSONObject

    private fun invoke(account: String?, operation: String, params: JSONObject): Any? {
        requireAgentAccount(account, params)
        return store.call(account, "agent.history.$operation", params)
    }

    private fun params(account: String? = null) = JSONObject().put("account_id", account ?: JSONObject.NULL)

    private fun id(number: Int) = number.toString(16).padStart(32, '0')

    private fun record(id: String, title: String, turn: JSONObject = turn()) = JSONObject()
        .put("id", id).put("title", title).put("updated_at", 1_700_000_000_000L)
        .put("turns", JSONArray().put(turn))

    private fun turn(question: String = "Question") = JSONObject().put("question", question)
        .put("remember", false).put("attachments", JSONArray()).put("web_links", JSONArray())

    private fun link(url: String = "https://example.org/path") = JSONObject().put("title", "Source").put("url", url)

    private fun assertCode(code: String, operation: () -> Unit) {
        assertEquals(code, assertThrows(PortError::class.java) { operation() }.code)
    }
}
