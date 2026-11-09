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
    @Test fun emptyServerErrorStillShowsRetryableFailure() = runTest {
        MockWebServer().use { server ->
            server.start(); server.enqueue(MockResponse().setBody("""{"code":1,"message":""}"""))
            val state = state(server); state.submitReport()
            assertFalse(state.reportSubmitted); assertFalse(state.reporting)
            assertFalse(state.reportError.isNullOrBlank())
            assertEquals("Reported concern", state.reportDescription)
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
    @Test fun submittedIdReadsBackResolvedHumanResponse() = runTest {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setBody("{\"code\":0,\"data\":{\"id\":123,\"status\":\"NEW\"}}"))
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"userId":7,"kind":"BUG","text":"private report","status":"RESOLVED","aiContentReport":true,"uploaded":true,"reporterResponse":"Verified and adjusted the safety handling","responsePublishedAt":"2026-11-09T08:00:00Z","resolvedAt":"2026-11-09T08:00:00Z","internalNote":"not public"}]}}"""))
            val state = state(server); state.submitReport()
            assertEquals(123L, state.reportId); assertTrue(state.reportSubmitted)
            state.refreshReportProgress()
            val progress = state.reportProgress
            assertNotNull(progress); assertTrue(progress!!.resolved)
            assertEquals("Verified and adjusted the safety handling", progress.reporterResponse)
            assertEquals("2026-11-09T08:00:00Z", progress.responsePublishedAt)
            assertNull(state.reportProgressError); assertFalse(state.reportRefreshing)
            assertEquals("/api/feedback", server.takeRequest().path)
            val query = server.takeRequest()
            assertEquals("/api/feedback/mine", query.path); assertEquals("GET", query.method)
            assertEquals("synthetic", query.getHeader("X-Session-Id"))
        }
    }
    @Test fun newAndEmailedStayInProgressAndNoResponseIsDistinct() = runTest {
        MockWebServer().use { server ->
            server.start(); val state = state(server); state.reportId = 123
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"status":"NEW","aiContentReport":true,"reporterResponse":null,"responsePublishedAt":null}]}}"""))
            state.refreshReportProgress()
            assertEquals("NEW", state.reportProgress?.status); assertFalse(state.reportProgress!!.resolved)
            assertNull(state.reportProgress?.reporterResponse); assertNull(state.reportProgressError)
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"status":"EMAILED","aiContentReport":true,"reporterResponse":null,"responsePublishedAt":null}]}}"""))
            state.refreshReportProgress()
            assertEquals("EMAILED", state.reportProgress?.status); assertFalse(state.reportProgress!!.resolved)
            assertNull(state.reportProgress?.reporterResponse); assertNull(state.reportProgressError)
            assertEquals(2, server.requestCount)
        }
    }
    @Test fun failedRefreshRetainsVisibleResponseAndReportsError() = runTest {
        MockWebServer().use { server ->
            server.start(); val state = state(server); state.reportId = 123
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"status":"RESOLVED","aiContentReport":true,"reporterResponse":"Published answer","responsePublishedAt":"2026-11-09T08:00:00Z"}]}}"""))
            state.refreshReportProgress(); val visible = state.reportProgress
            server.enqueue(MockResponse().setResponseCode(503))
            state.refreshReportProgress()
            assertSame(visible, state.reportProgress); assertEquals("Published answer", state.reportProgress?.reporterResponse)
            assertNotNull(state.reportProgressError); assertFalse(state.reportRefreshing)
        }
    }
    @Test fun feedbackQueryFiltersNonAiAndUnrelatedIds() = runTest {
        MockWebServer().use { server ->
            server.start()
            val backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore().also { it.save("synthetic") }).accountSnapshot()
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"userId":7,"status":"RESOLVED","aiContentReport":false,"reporterResponse":"not AI"},{"id":124,"userId":8,"status":"RESOLVED","aiContentReport":true,"reporterResponse":"unrelated"},{"id":123,"userId":7,"status":"RESOLVED","aiContentReport":true,"reporterResponse":"allowed"}]}}"""))
            assertEquals("allowed", backend.assistantReport(123)?.reporterResponse)
            server.enqueue(MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"status":"RESOLVED","aiContentReport":false,"reporterResponse":"not AI"},{"id":124,"status":"RESOLVED","aiContentReport":true,"reporterResponse":"unrelated"}]}}"""))
            assertNull(backend.assistantReport(123))
        }
    }
    @Test fun accountChangeCannotPublishLateProgress() = runTest {
        MockWebServer().use { server ->
            server.start(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val sessions = MemorySessionStore().also { it.save("synthetic") }
            server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest): MockResponse {
                entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
                return MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"status":"RESOLVED","aiContentReport":true,"reporterResponse":"late private answer"}]}}""")
            } }
            val state = state(server, sessions); state.reportId = 123
            val first = async { state.refreshReportProgress() }
            testScheduler.runCurrent(); assertTrue(entered.await(5, TimeUnit.SECONDS)); assertTrue(state.reportRefreshing)
            sessions.save("other-account"); release.countDown(); first.await()
            assertNull(state.reportProgress); assertNull(state.reportProgressError); assertFalse(state.reportRefreshing)
        }
    }
    @Test fun inFlightRefreshPreventsDuplicateRequests() = runTest {
        MockWebServer().use { server ->
            server.start(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
            server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest): MockResponse {
                entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
                return MockResponse().setBody("""{"code":0,"data":{"items":[{"id":123,"status":"NEW","aiContentReport":true}]}}""")
            } }
            val state = state(server); state.reportId = 123
            val first = async { state.refreshReportProgress() }
            testScheduler.runCurrent(); assertTrue(entered.await(5, TimeUnit.SECONDS)); assertTrue(state.reportRefreshing)
            state.refreshReportProgress(); assertEquals(1, server.requestCount)
            release.countDown(); first.await()
            assertEquals("NEW", state.reportProgress?.status); assertFalse(state.reportRefreshing)
        }
    }
}
