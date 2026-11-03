// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.features.personal.PersonalWorkspaceState
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class PersonalReportTest {
    private val conversation = "65ef7d42-15a8-4c26-a781-12b146662a5b"
    private fun state(server: MockWebServer, sessions: MemorySessionStore = MemorySessionStore().also { it.save("synthetic") }): PersonalWorkspaceState {
        val backend = Backend(server.url("/").toString().trimEnd('/'), sessions).accountSnapshot()
        val store = PersonalConversationStore(backend::personalAccountScope, { null }, {})
        return PersonalWorkspaceState(backend, store).also {
            it.conversationId = conversation
            it.messages.add("assistant" to "PRIVATE CHAT MUST NOT BE SENT")
            it.openReport(); it.reportDescription = "Reported concern"
        }
    }
    @Test fun reportSendsExplicitDescriptionAndIdentityWithoutChatOrAttachments() = runTest {
        MockWebServer().use { server ->
            server.start(); server.enqueue(MockResponse().setBody("{\"code\":0,\"data\":{\"id\":123,\"status\":\"NEW\"}}"))
            val state = state(server); state.submitReport()
            assertTrue(state.reportSubmitted); assertNull(state.reportError); assertFalse(state.reporting)
            val request = server.takeRequest()
            assertEquals("/api/feedback", request.path); assertEquals("synthetic", request.getHeader("X-Session-Id"))
            val body = request.body.readUtf8()
            assertTrue(body.contains("Reported concern")); assertTrue(body.contains(conversation)); assertTrue(body.contains("ai-content-report"))
            assertFalse(body.contains("PRIVATE CHAT")); assertFalse(body.contains("filename=")); assertFalse(body.contains("name=\"files\""))
            state.submitReport(); assertEquals(1, server.requestCount)
        }
    }
    @Test fun blankDescriptionDoesNotSendAndMissingReceiptCannotClaimSuccess() = runTest {
        MockWebServer().use { server ->
            server.start(); val state = state(server); state.reportDescription = "  "
            state.submitReport(); assertEquals(0, server.requestCount); assertFalse(state.reportSubmitted)
            state.reportDescription = "Reported concern"
            server.enqueue(MockResponse().setBody("{\"code\":0,\"data\":{}}")); state.submitReport()
            assertFalse(state.reportSubmitted); assertNotNull(state.reportError)
        }
    }
    @Test fun failedReportRetainsDescriptionAndCanRetryWithoutClaimingSuccess() = runTest {
        MockWebServer().use { server ->
            server.start(); server.enqueue(MockResponse().setBody("{\"code\":1,\"message\":\"synthetic rejection\"}"))
            val state = state(server); state.submitReport()
            assertFalse(state.reportSubmitted); assertEquals("synthetic rejection", state.reportError)
            assertEquals("Reported concern", state.reportDescription); assertFalse(state.reporting)
            server.enqueue(MockResponse().setBody("{\"code\":0,\"data\":{\"id\":124}}")); state.submitReport()
            assertTrue(state.reportSubmitted); assertEquals(2, server.requestCount)
        }
    }
    @Test fun inFlightReportPreventsDuplicateAndAccountChangeCannotPublishSuccess() = runTest {
        MockWebServer().use { server ->
            server.start(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val sessions = MemorySessionStore().also { it.save("synthetic") }
            server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest): MockResponse {
                entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
                return MockResponse().setBody("{\"code\":0,\"data\":{\"id\":125}}")
            } }
            val state = state(server, sessions)
            val first = async { state.submitReport() }
            testScheduler.runCurrent(); assertTrue(entered.await(5, TimeUnit.SECONDS)); assertTrue(state.reporting)
            state.submitReport(); assertEquals(1, server.requestCount)
            sessions.save("other-account"); release.countDown(); first.await()
            assertFalse(state.reportSubmitted); assertFalse(state.reporting)
        }
    }
}
