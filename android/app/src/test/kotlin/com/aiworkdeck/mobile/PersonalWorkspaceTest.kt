// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile
import com.aiworkdeck.mobile.services.*
import com.aiworkdeck.mobile.features.personal.PersonalWorkspaceState
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class PersonalWorkspaceTest {
    @Test fun restoresRunningRequestBeforeHistoryWithoutPostingAndPersistsCompletion() = runTest {
        val server = MockWebServer(); server.start()
        try {
            val session = MemorySessionStore().also { it.save("synthetic-account") }
            val backend = Backend(server.url("/").toString().trimEnd('/'), session).accountSnapshot()
            var saved: String? = null
            fun store() = PersonalConversationStore(backend::personalAccountScope, { saved }, { saved = it })
            val requestId = "a8cd2df0-1eec-43f2-8d5b-a76aed02c4b8"
            val conversationId = "de85ec55-9f97-4a16-9d59-4e6dbab64112"
            store().save(PersonalConversation(pending = PersonalQuestion(message = "Synthetic", requestId = requestId)))
            fun reply(status: String) = MockResponse().setBody("""{"code":0,"data":{"status":"$status","conversationId":"$conversationId","requestId":"$requestId","answer":"Answer","sources":[]}}""")
            server.enqueue(reply("running")); server.enqueue(reply("completed"))
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"conversationId":"$conversationId","messages":[{"role":"user","content":"Synthetic","requestId":"$requestId"},{"role":"assistant","content":"Answer","sources":[{"deviceId":"desktop","projectKey":"alpha","projectName":"Synthetic"}]}]}}"""))
            val reopened = store()
            val state = PersonalWorkspaceState(backend, reopened)
            state.restoreConversation(reopened)
            assertEquals(listOf("user" to "Synthetic", "assistant" to "Answer"), state.messages.toList())
            assertEquals("alpha", state.sources.single().projectKey)
            assertNull(state.pending); assertEquals("", state.draft)
            assertEquals(PersonalConversation(conversationId), store().load())
            val calls = List(3) { server.takeRequest() }
            assertTrue(calls.all { it.method == "GET" })
            assertEquals(listOf("/api/mobile/assistant/requests/$requestId", "/api/mobile/assistant/requests/$requestId", "/api/mobile/assistant/conversations/$conversationId"), calls.map { it.path })
        } finally { server.shutdown() }
    }
    @Test fun failedRestoreRetainsOriginalRequestAndExplicitRetryDoesNotChangeBody() = runTest {
        val server = MockWebServer(); server.start()
        try {
            val backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore().also { it.save("synthetic") }).accountSnapshot()
            var saved: String? = null
            val store = PersonalConversationStore(backend::personalAccountScope, { saved }, { saved = it })
            val original = PersonalQuestion(message = "Synthetic", requestId = "a8cd2df0-1eec-43f2-8d5b-a76aed02c4b8")
            val conversationId = "de85ec55-9f97-4a16-9d59-4e6dbab64112"
            store.save(PersonalConversation(pending = original))
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"status":"failed","conversationId":"$conversationId","requestId":"${original.requestId}","answer":""}}"""))
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"conversationId":"$conversationId","messages":[{"role":"user","content":"Synthetic"}]}}"""))
            val state = PersonalWorkspaceState(backend, store)
            state.restoreConversation(store)
            assertEquals(original, state.pending); assertEquals(original, store.load().pending)
            assertEquals(2, server.requestCount)
            assertEquals("GET", server.takeRequest().method); assertEquals("GET", server.takeRequest().method)
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"status":"completed","conversationId":"$conversationId","requestId":"${original.requestId}","answer":"Answer"}}"""))
            state.status = PersonalStatus(true, true, true, 1)
            state.send()
            val retry = server.takeRequest()
            assertEquals("POST", retry.method)
            val body = kotlinx.serialization.json.Json.parseToJsonElement(retry.body.readUtf8()).toString()
            assertTrue(body.contains(original.requestId)); assertFalse(body.contains("conversationId"))
            assertEquals(2, state.messages.size)
            assertNull(store.load().pending)
        } finally { server.shutdown() }
    }
    @Test fun accountRegionChangeAndRevocationInvalidateOldWriters() {
        var scope: String? = "account-a-cn"; var saved: String? = null
        fun store() = PersonalConversationStore({ scope }, { saved }, { saved = it })
        val old = store(); old.save(PersonalConversation("conversation"))
        scope = "account-a-intl"
        assertFalse(old.save(PersonalConversation("late-answer")))
        assertEquals(PersonalConversation(), store().load())
        assertNull(saved)
        val next = store(); next.save(PersonalConversation("new-conversation"))
        PersonalConversationStore.invalidate(); saved = null
        assertFalse(next.save(PersonalConversation("late-answer"))); assertNull(saved)
        scope = null
        assertFalse(store().save(PersonalConversation("signed-out")))
    }
    @Test fun responseAfterRevocationDoesNotRecreateConversation() = runTest {
        val server = MockWebServer(); server.start()
        try {
            val backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore().also { it.save("synthetic") }).accountSnapshot()
            var saved: String? = null
            val store = PersonalConversationStore(backend::personalAccountScope, { saved }, { saved = it })
            val question = PersonalQuestion(message = "Synthetic", requestId = "a8cd2df0-1eec-43f2-8d5b-a76aed02c4b8")
            store.save(PersonalConversation(pending = question))
            server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
                override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                    PersonalConversationStore.invalidate(); saved = null
                    return MockResponse().setBody("""{"code":0,"data":{"status":"completed","conversationId":"de85ec55-9f97-4a16-9d59-4e6dbab64112","requestId":"${question.requestId}","answer":"Late answer"}}""")
                }
            }
            val state = PersonalWorkspaceState(backend, store)
            state.restoreConversation(store)
            assertNull(saved); assertTrue(state.messages.isEmpty()); assertEquals(1, server.requestCount)
        } finally { server.shutdown() }
    }
    @Test fun remindersExcludeDonePastAndMissingDatesAndLimitNext50() {
        val now = Instant.parse("2026-10-27T20:00:00Z")
        val event = PersonalCalendarEvent("1", "desktop", "alpha", projectName = "Synthetic", title = "Event", dueDate = "2026-10-28", timeZone = "Asia/Shanghai", remindAt = "2026-10-28T00:00:00Z", status = "OPEN")
        assertTrue(event.within(1, now))
        assertFalse(event.copy(timeZone = "America/Los_Angeles").within(1, now))
        val items = (1..60).map { event.copy(id = "$it", remindAt = now.plusSeconds(it.toLong()).toString()) }
        val reminders = reminderEvents(items.reversed() + event.copy(status = "DONE") + event.copy(remindAt = null), now)
        assertEquals(50, reminders.size)
        assertEquals("1", reminders.first().id)
        assertEquals("50", reminders.last().id)
    }
    @Test fun failedRequestCanRetrySameUuidAndRunningPollOnlyReturnsCompletedAnswer() = runTest {
        val server = MockWebServer(); server.start()
        try {
            val session = MemorySessionStore().also { it.save("synthetic-account") }
            val backend = Backend(server.url("/").toString().trimEnd('/'), session).accountSnapshot()
            val question = PersonalQuestion(message = "Synthetic question", requestId = "a8cd2df0-1eec-43f2-8d5b-a76aed02c4b8")
            fun reply(status: String, answer: String = "") = MockResponse().setBody("""{"code":0,"data":{"status":"$status","conversationId":"conversation","requestId":"${question.requestId}","answer":"$answer","sources":[]}}""")
            server.enqueue(reply("failed"))
            var failed = false
            try { backend.personalChat(question) } catch (_: Exception) { failed = true }
            assertTrue(failed)
            server.enqueue(reply("running")); server.enqueue(reply("completed", "Answer"))
            assertEquals("Answer", backend.personalChat(question).answer)
            val original = server.takeRequest(); val retry = server.takeRequest(); val poll = server.takeRequest()
            assertEquals(original.body.readUtf8(), retry.body.readUtf8())
            assertEquals("synthetic-account", retry.getHeader("X-Session-Id"))
            assertEquals("GET", poll.method)
            assertEquals("/api/mobile/assistant/requests/${question.requestId}", poll.path)
            session.save("other-account")
            try { backend.personalStatus(); fail("A frozen account must not use new credentials") } catch (_: IllegalStateException) { }
            assertEquals(3, server.requestCount)
        } finally { server.shutdown() }
    }
}
