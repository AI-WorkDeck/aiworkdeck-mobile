package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.Unauthorized
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

class BackendTest {
    private lateinit var server: MockWebServer
    private lateinit var session: MemorySessionStore
    private lateinit var backend: Backend

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
        session = MemorySessionStore()
        backend = Backend(server.url("/").toString().trimEnd('/'), session)
    }

    @After fun tearDown() { server.shutdown() }

    @Test fun consentGateBlocksNetworkUntilAccepted() = runTest {
        var accepted = false
        val gated = Backend(
            baseUrlProvider = { server.url("/").toString().trimEnd('/') },
            session = session,
            accountActive = { accepted },
        )
        val result = runCatching { gated.accountLogin("synthetic@example.invalid", "synthetic") }
        assertTrue(result.exceptionOrNull() is IllegalStateException)
        assertEquals(0, server.requestCount)
        accepted = true
        server.enqueue(MockResponse().setBody(
            """{"code":0,"data":{"sessionId":"device-token","user":{"id":71,"username":"existing-user","displayName":"Test"}}}"""
        ))
        assertEquals(71L, gated.accountLogin("synthetic@example.invalid", "synthetic").user.id)
        assertEquals(1, server.requestCount)
    }

    @Test fun passwordLoginPreservesIdentityAndExactPassword() = runTest {
        server.enqueue(MockResponse().setBody(
            """{"code":0,"data":{"sessionId":"device-token","user":{"id":71,"username":"existing-user","displayName":"Test"}}}"""
        ))
        val result = backend.accountLogin("synthetic@example.invalid", "  synthetic password  ")
        assertEquals(71L, result.user.id)
        assertEquals("device-token", session.current())
        val request = server.takeRequest()
        assertEquals("/api/auth/account-login", request.path)
        assertTrue(request.body.readUtf8().contains("\"password\":\"  synthetic password  \""))
    }

    @Test fun setupChallengeNeverBecomesAMobileSession() = runTest {
        server.enqueue(MockResponse().setBody(
            """{"code":0,"data":{"passwordSetupRequired":true,"setupToken":"synthetic-setup"}}"""
        ))
        var rejected = false
        try { backend.accountLogin("synthetic@example.invalid", "synthetic") }
        catch (_: Exception) { rejected = true }
        assertTrue(rejected)
        assertNull(session.current())
    }

    @Test fun verifyLoginCodeDecodesEnvelopeAndSavesSession() = runTest {
        server.enqueue(MockResponse().setBody(
            """{"code":0,"data":{"sessionId":"sess-1","isNewUser":true,"user":{"id":1,"username":"u","displayName":"U"}}}"""
        ))

        val result = backend.verifyLoginCode("13800000000", "1234")

        assertEquals("sess-1", result.sessionId)
        assertEquals(true, result.isNewUser)
        assertEquals("U", result.user.displayName)
        assertEquals("sess-1", session.current())
    }

    @Test fun subscriptionAllowanceIsSeparateFromZeroCashAndUnknownStorageQuota() = runTest {
        server.enqueue(MockResponse().setBody("""{"balanceCents":0,"currency":"CNY","plan":"paid","subscription":{"active":true,"availableCents":2500,"monthlyLimitCents":14900,"monthlyUsedCents":2000,"weeklyLimitCents":4500,"weeklyUsedCents":2000}}"""))
        val balance = backend.billingBalance()
        assertEquals(0L, balance.balanceCents)
        assertEquals(2500L, balance.subscription?.availableCents)
        assertEquals(14900L, balance.subscription?.monthlyLimitCents)
        server.enqueue(MockResponse().setBody("""{"usedBytes":9,"quotaBytes":209715200,"persistentUsedBytes":42,"persistentQuotaBytes":null,"persistentQuotaAvailable":false}"""))
        val usage = backend.mediaUsage()
        assertEquals(9L, usage.usedBytes)
        assertEquals(42L, usage.persistentUsedBytes)
        assertNull(usage.persistentQuotaBytes)
        assertEquals(false, usage.persistentQuotaAvailable)
    }

    @Test fun myProjectsDecodesBareArray() = runTest {
        server.enqueue(MockResponse().setBody("""[{"projectUid":"uid","name":"n1","locations":[{"kind":"desktop","deviceId":"d1","key":"k1","online":true}]}]"""))

        val projects = backend.myProjects()

        assertEquals("uid", projects.single().id)
        assertEquals("d1", projects.single().deviceId)
        assertEquals("/api/mobile/catalog", server.takeRequest().path)
    }

    @Test fun unauthorizedEnvelopeThrowsAndClearsSession() = runTest {
        session.save("stale-session")
        server.enqueue(MockResponse().setBody("""{"code":4010}"""))

        try {
            backend.myProjects()
            fail("expected Unauthorized")
        } catch (expected: Unauthorized) {
            // expected
        }
        assertNull(session.current())
    }

    @Test fun uploadSendsMultipartFieldsAndSessionHeader() = runTest {
        session.save("sess-2")
        server.enqueue(MockResponse().setBody("""{"code":0,"id":9,"clientMediaId":"c1","delivered":false}"""))
        val file = File.createTempFile("upload", ".jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }

        val result = backend.upload(file, "d1", "k1", "c1", "photo.jpg", "image", "2026-09-02T00:00:00+08:00") {}

        assertEquals(9L, result.id)
        assertEquals("c1", result.clientMediaId)
        assertFalse(result.delivered)

        val request = server.takeRequest()
        assertEquals("sess-2", request.getHeader("X-Session-Id"))
        val body = request.body.readUtf8()
        for (field in listOf("deviceId", "projectKey", "clientMediaId", "fileName", "mediaType", "capturedAt", "file")) {
            assertTrue("missing multipart field $field", body.contains("name=\"$field\""))
        }
    }

    @Test fun businessErrorThrowsApiErrorWithMessage() = runTest {
        server.enqueue(MockResponse().setBody("""{"code":1,"message":"boom"}"""))

        try {
            backend.sendLoginCode("13800000000")
            fail("expected ApiError")
        } catch (e: ApiError) {
            assertEquals(1, e.code)
            assertEquals("boom", e.message)
        }
    }

    @Test fun mediaStatusJoinsClientMediaIdsIntoQuery() = runTest {
        server.enqueue(MockResponse().setBody(
            """[{"clientMediaId":"a","delivered":true,"waitingSeconds":0},{"clientMediaId":"b","delivered":false,"waitingSeconds":5}]"""
        ))

        val result = backend.mediaStatus(listOf("a", "b"))

        assertEquals(2, result.size)
        val request = server.takeRequest()
        assertEquals("/api/mobile/media/status?clientMediaIds=a,b", request.path)
    }
}
