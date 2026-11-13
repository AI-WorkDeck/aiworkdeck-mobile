package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.DeferredSessionStore
import com.aiworkdeck.mobile.services.DeviceFacts
import com.aiworkdeck.mobile.services.EvidenceStore
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.RecordingDrafts
import com.aiworkdeck.mobile.services.SessionSaveFailed
import com.aiworkdeck.mobile.services.SessionStore
import com.aiworkdeck.mobile.services.Unauthorized
import com.aiworkdeck.mobile.services.userFacingMessage
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.SerializationException
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

/** QA B3/B4/B5：会话存不住要登录失败、读不出的录音能丢弃、系统异常原文不上界面。 */
class ReliabilityTest {
    @Rule @JvmField val tmp = TemporaryFolder()

    private fun facts() = DeviceFacts(model = "Pixel 8", osVersion = "14", appVersion = "1.0.0")

    // ---- B5 userFacingMessage ----

    @Test fun networkExceptionsMapToContractStrings() {
        assertEquals(tr("error.unreachable"), userFacingMessage(UnknownHostException("Unable to resolve host \"api.example\"")))
        assertEquals(tr("error.unreachable"), userFacingMessage(ConnectException("Failed to connect to /10.0.0.1:443")))
        assertEquals(tr("error.unreachable"), userFacingMessage(SSLHandshakeException("Chain validation failed")))
        assertEquals(tr("error.network"), userFacingMessage(SocketTimeoutException("timeout")))
        assertEquals(tr("error.network"), userFacingMessage(IOException("unexpected end of stream")))
    }

    @Test fun businessErrorsKeepServerMessageAndRawTextNeverLeaks() {
        assertEquals("server says no", userFacingMessage(ApiError(1001, "server says no")))
        assertEquals(tr("error.unauthorized"), userFacingMessage(Unauthorized()))
        assertEquals(tr("error.unauthorized"), Unauthorized().message)
        assertEquals(tr("error.sessionSaveFailed"), userFacingMessage(SessionSaveFailed()))
        assertEquals(tr("error.badResponse"), userFacingMessage(SerializationException("Unexpected JSON token at offset 0")))
        assertEquals(tr("error.network"), userFacingMessage(RuntimeException("NullPointer in foo")))
        assertEquals(tr("error.network"), userFacingMessage(NumberFormatException("For input string: x")))
        assertEquals(tr("files.previewFailed"), userFacingMessage(RuntimeException("boom"), tr("files.previewFailed")))
        // 应用自己 check { tr(...) } 出来的文案照用
        assertEquals(tr("files.desktopRequired"), userFacingMessage(IllegalStateException(tr("files.desktopRequired"))))
    }

    // ---- B3 会话存不住 ----

    private class FailingSessionStore : SessionStore {
        override fun current(): String? = null
        override fun save(id: String) { throw SessionSaveFailed() }
        override fun clear() {}
    }

    @Test fun loginFailsWhenSessionCannotBePersisted() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            server.enqueue(MockResponse().setBody(
                """{"code":0,"data":{"sessionId":"device-token","user":{"id":71,"username":"u","displayName":"U"}}}"""))
            val backend = Backend(server.url("/").toString().trimEnd('/'), FailingSessionStore())
            val error = runCatching { backend.accountLogin("u", "p") }.exceptionOrNull()
            assertTrue(error is SessionSaveFailed)
            assertEquals(tr("error.sessionSaveFailed"), userFacingMessage(error!!))
            assertFalse(backend.hasSession())
        } finally { server.shutdown() }
    }

    @Test fun deferredStoreRefusesToPretendPersistence() {
        val unavailable = DeferredSessionStore { throw IllegalStateException("Keystore unavailable") }
        assertThrows(SessionSaveFailed::class.java) { unavailable.save("token") }
        assertNull(unavailable.current())

        val recovered = DeferredSessionStore { MemorySessionStore() }
        recovered.save("token")
        assertEquals("token", recovered.current())
        recovered.clear()
        assertNull(recovered.current())
    }

    // ---- B4 读不出的录音草稿 ----

    @Test fun discardRemovesOnlyUnreadableDrafts() = runTest {
        val root = tmp.newFolder("drafts")
        val drafts = RecordingDrafts(root) { it.readText() == "audio" }
        val bad = drafts.create(1_000, null).also { drafts.file(it).writeText("garbage") }
        val good = drafts.create(2_000, null).also { drafts.file(it).writeText("audio") }

        assertEquals(1, drafts.discardUnreadable())
        assertFalse(drafts.file(bad).exists())
        assertFalse(File(root, bad.name + ".json").exists())
        assertTrue(drafts.file(good).exists())
        assertTrue(File(root, good.name + ".json").exists())

        val store = EvidenceStore(tmp.newFolder("evidence"), facts())
        val result = drafts.recover(store)
        assertEquals(0, result.invalid)
        assertEquals(0, result.failed)
        assertEquals(1, store.loadAll().size)
        // 再启动一次：什么都不剩，不再提醒
        assertNull(drafts.recover(store).message)
    }

    @Test fun unreadableNoticeRecursUntilDiscarded() = runTest {
        val root = tmp.newFolder("drafts")
        val drafts = RecordingDrafts(root) { false }
        drafts.create(1_000, null).also { drafts.file(it).writeText("garbage") }
        val store = EvidenceStore(tmp.newFolder("evidence"), facts())
        assertEquals(1, drafts.recover(store).invalid)
        assertEquals(1, drafts.recover(store).invalid)
        drafts.discardUnreadable()
        val after = drafts.recover(store)
        assertEquals(0, after.invalid)
        assertNull(after.message)
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }
}
