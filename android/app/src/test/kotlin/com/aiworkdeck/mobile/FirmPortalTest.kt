// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.services.firm.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/** Portal client and connection state against a local server; mirrors the iOS client/link tests. */
class FirmPortalTest {
    private val server = MockWebServer()
    private val routes = mutableMapOf<String, Pair<Int, String>>()
    private val allowed = listOf("aifirm.aiworkdeck.com/all", "ai-firm.aiworkdeck.com/sv", "ai-firm.aiworkdeck.com/tw")

    @Before fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val (code, body) = routes[request.requestUrl!!.encodedPath] ?: (404 to """{"error":"not_found"}""")
                return MockResponse().setResponseCode(code).setBody(body)
            }
        }
        server.start()
    }
    @After fun stop() { server.shutdown() }

    private fun client(portal: String, credential: String = "s") = FirmPortalClient(portal, credential, OkHttpFirmTransport(), server.url("/"), allowed)

    @Test fun clientSendsBearerUsesOfficePrefixAndMapsErrors() = runTest {
        routes["/sv/api/portal/me"] = 200 to """{"kind":"lawyer","name":"Han","status":"approved","extra":1}"""
        assertEquals("approved", client("ai-firm.aiworkdeck.com/sv", "awdt_x").me().status)
        val req = server.takeRequest()
        assertEquals("Bearer awdt_x", req.getHeader("Authorization"))
        assertEquals("/sv/api/portal/me", req.requestUrl!!.encodedPath)

        routes["/sv/api/portal/matters"] = 401 to """{"error":"trial_expired"}"""
        val e = runCatching { client("ai-firm.aiworkdeck.com/sv").matters() }.exceptionOrNull() as FirmPortalError
        assertEquals("trial_expired", e.code); assertEquals(401, e.status)
        routes["/sv/api/portal/matters"] = 502 to "gateway"
        assertEquals("http_502", (runCatching { client("ai-firm.aiworkdeck.com/sv").matters() }.exceptionOrNull() as FirmPortalError).code)
        routes["/sv/api/portal/matters"] = 200 to "not json"
        assertEquals("bad_response", (runCatching { client("ai-firm.aiworkdeck.com/sv").matters() }.exceptionOrNull() as FirmPortalError).code)
    }

    @Test fun clientRefusesPortalsOutsideTheContract() = runTest {
        val e = runCatching { client("evil.example").me() }.exceptionOrNull() as FirmPortalError
        assertEquals("host_not_allowed", e.code)
        assertEquals(0, server.requestCount)
    }

    @Test fun signoffSendsConfirmationsAndOnlyTheDetailsGiven() = runTest {
        routes["/all/api/portal/matter/signoff"] = 200 to """{"ok":true,"finalPdf":"https://aifirm.aiworkdeck.com/m/1.pdf"}"""
        assertEquals("https://aifirm.aiworkdeck.com/m/1.pdf", client("aifirm.aiworkdeck.com/all").signoff("m1", 2, "Han", mapOf("title" to "Partner", "firm" to "")))
        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("Partner", body["title"]!!.jsonPrimitive.content)
        assertFalse("empty details are omitted", "firm" in body)
        assertEquals(setOf("conflicts", "engagement", "reviewed"), body["checks"]!!.jsonObject.keys)
        assertEquals(2, body["version"]!!.jsonPrimitive.content.toInt())
    }

    private fun portal(trials: FirmTrialStore = MemoryFirmTrialStore(), settings: FirmSettings = MemoryFirmSettings(), userId: Long = 7) =
        FirmPortal(trials, settings, { "https://addin.workdeck.ai" to "s" }, { userId }, OkHttpFirmTransport(), server.url("/"), allowed)

    private val matters = """{"matters":[{"id":"m1","status":"review","updatedAt":"2026-11-21T00:00:00Z"}]}"""

    @Test fun linkedPortalsKeepTheirMattersApartAndOneApprovalOpensTheTab() = runTest {
        routes["/sv/api/portal/me"] = 200 to """{"kind":"lawyer","name":"Han","status":"approved","firm":{"en":"Venture AI · Silicon Valley"}}"""
        routes["/tw/api/portal/me"] = 200 to """{"kind":"lawyer","name":"Han","status":"pending"}"""
        routes["/sv/api/portal/matters"] = 200 to matters
        routes["/tw/api/portal/matters"] = 200 to matters
        val p = portal(); p.restore()
        assertNull(p.connect("ai-firm.aiworkdeck.com/sv"))
        assertEquals(FirmAccess.approved, p.access)
        assertNull("a pending portal is kept, not refused", p.connect("ai-firm.aiworkdeck.com/tw"))
        assertEquals(listOf("ai-firm.aiworkdeck.com/sv"), p.matters.map { it.linkID })
        assertTrue(p.listed)
        assertEquals(1, p.needsYouCount)
        assertEquals("Venture AI · Silicon Valley", p.link("ai-firm.aiworkdeck.com/sv")!!.firmName)
        assertTrue("no roster: the lawyer may add title, firm and admission", p.link("ai-firm.aiworkdeck.com/sv")!!.asksDetails)
    }

    @Test fun aFailedCodeSaveRefusesToJoinInsteadOfSendingTheSession() = runTest {
        val trials = MemoryFirmTrialStore().apply { failSaves = true }
        val p = portal(trials); p.restore()
        assertEquals("error.sessionSaveFailed", p.connect("ai-firm.aiworkdeck.com/sv", "TRIAL-1"))
        assertTrue(p.links.value.isEmpty())
        assertEquals(0, server.requestCount)
    }

    @Test fun anInvalidTrialCodeIsNotKept() = runTest {
        routes["/sv/api/portal/me"] = 401 to """{"error":"unauthorized"}"""
        val trials = MemoryFirmTrialStore()
        val p = portal(trials); p.restore()
        assertEquals("firm.trial.invalid", p.connect("ai-firm.aiworkdeck.com/sv", " TRIAL-1 "))
        assertEquals("Bearer TRIAL-1", server.takeRequest().getHeader("Authorization"))
        assertTrue(p.links.value.isEmpty())
        assertTrue("the code is forgotten with the link", trials.values.isEmpty())
    }

    @Test fun linksAreSavedPerAccountAndRestored() = runTest {
        routes["/sv/api/portal/me"] = 200 to """{"kind":"lawyer","name":"Han","status":"approved"}"""
        routes["/sv/api/portal/matters"] = 200 to matters
        val settings = MemoryFirmSettings(); val trials = MemoryFirmTrialStore()
        portal(trials, settings).apply { restore(); connect("ai-firm.aiworkdeck.com/sv", "T1") }
        val again = portal(trials, settings); again.restore()
        assertEquals(listOf("ai-firm.aiworkdeck.com/sv"), again.links.value.map { it.portalID })
        assertEquals("T1", again.links.value.single().trialCode)
        val other = portal(trials, settings, userId = 8); other.restore()
        assertTrue("another account never sees these links", other.links.value.isEmpty())
        val unknown = portal(trials, settings, userId = 0); unknown.restore()
        assertNull("no verified user id, no scope", unknown.scope)
    }

    @Test fun aNetworkErrorKeepsAnApprovedLinkAndDisconnectAllForgetsEverything() = runTest {
        routes["/sv/api/portal/me"] = 200 to """{"kind":"lawyer","name":"Han","status":"approved"}"""
        routes["/sv/api/portal/matters"] = 200 to matters
        val trials = MemoryFirmTrialStore(); val settings = MemoryFirmSettings()
        val p = portal(trials, settings); p.restore(); p.connect("ai-firm.aiworkdeck.com/sv", "T1")
        p.saveDetails("ai-firm.aiworkdeck.com/sv", mapOf("title" to "Partner"))
        routes["/sv/api/portal/matters"] = 503 to "down"
        p.refresh()
        assertEquals(FirmAccess.approved, p.access)
        assertEquals("firm.error.network", p.loadErrorKey)
        assertEquals(1, p.matters.size)
        p.disconnectAll()
        assertTrue(p.links.value.isEmpty()); assertTrue(trials.values.isEmpty()); assertTrue(settings.values.isEmpty())
    }

    @Test fun aLateReplyForAClosedLinkIsIgnored() = runTest {
        routes["/sv/api/portal/me"] = 200 to """{"kind":"lawyer","name":"Han","status":"approved"}"""
        val link = FirmLink("ai-firm.aiworkdeck.com/sv", null, { "s" }) { p, c -> FirmPortalClient(p, c, OkHttpFirmTransport(), server.url("/"), allowed) }
        link.closed = true
        link.check()
        assertEquals(FirmAccess.none, link.state.value.access)
    }
}
