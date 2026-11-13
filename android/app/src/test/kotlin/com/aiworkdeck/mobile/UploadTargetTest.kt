package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.CaptureManifest
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.BackendUploader
import com.aiworkdeck.mobile.services.MemorySessionStore
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * 上传的 deviceId 必须是收件方（项目所在电脑，云端项目为 "cloud"），不是本机。
 * 曾误传本机安装 ID：服务端按它入箱，桌面端永远取不到，云端项目也进不了云端存储。
 */
class UploadTargetTest {
    private lateinit var server: MockWebServer
    private lateinit var uploader: BackendUploader

    @Before fun setUp() {
        server = MockWebServer(); server.start()
        val session = MemorySessionStore().also { it.save("sess-1") }
        uploader = BackendUploader(Backend(server.url("/").toString().trimEnd('/'), session))
    }
    @After fun tearDown() { server.shutdown() }

    private fun item(): CaptureItem {
        val f = File.createTempFile("cap", ".jpg").apply { writeBytes(byteArrayOf(1, 2, 3)); deleteOnExit() }
        val m = CaptureManifest("cm-1", "00", "2026-11-12T10:00:00+08:00", deviceModel = "t", osVersion = "t", appVersion = "t", fromCamera = true)
        return CaptureItem("cm-1", MediaKind.photo, TransferState.waiting, m, f, 0.0, null, false, null)
    }

    private suspend fun sentDeviceId(project: RelayProject): String {
        server.enqueue(MockResponse().setBody("""{"code":0,"id":1,"clientMediaId":"cm-1","delivered":false}"""))
        uploader.upload(item(), project, "a.jpg") {}
        val body = server.takeRequest().body.readUtf8()
        return Regex("name=\"deviceId\"\\r\\n(?:[^\\r\\n]*\\r\\n)*?\\r\\n([^\\r\\n]*)").find(body)!!.groupValues[1]
    }

    @Test fun desktopProjectUploadsAddressTheDesktop() = runTest {
        assertTrue(sentDeviceId(RelayProject("desk-42", "MacBook", "p1", "案卷")) == "desk-42")
    }

    @Test fun cloudProjectUploadsAddressTheCloud() = runTest {
        assertTrue(sentDeviceId(RelayProject("cloud", null, "c1", "云端案卷")) == "cloud")
    }
}
