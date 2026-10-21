package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.nio.file.Files

class ProjectFilesServiceTest {
    private lateinit var server: MockWebServer
    private lateinit var root: File
    private var active = true
    private val project = RelayProject("desktop-1", key = "p", name = "Synthetic")
    private val file = ProjectFile("f", "sample.pdf", "folder/sample.pdf", 4)
    private fun service() = ProjectFilesService(server.url("/").toString().trimEnd('/'), "synthetic", "zh-CN", root, OkHttpClient()) { active }
    private fun body(value: String) = server.enqueue(MockResponse().setBody(value))
    private fun content(value: String = "test") = server.enqueue(MockResponse().setHeader("Content-Type", "application/octet-stream").setBody(value))
    private suspend fun rejected(action: suspend () -> Unit) { var rejected = false; try { action() } catch (_: Exception) { rejected = true }; assertTrue(rejected) }
    @Before fun setup() { server = MockWebServer(); server.start(); root = Files.createTempDirectory("android-preview-test").toFile(); active = true }
    @After fun cleanup() { server.shutdown(); root.deleteRecursively() }

    @Test fun directoryKeepsEmptyFoldersAndDoesNotFlattenPaths() {
        val files = listOf(file, file.copy(id = "2", name = "empty", path = "empty", isFolder = true), file.copy(id = "3", path = "another\\sample.pdf"))
        assertEquals(listOf("another", "empty", "folder"), folderEntries(files).map { it.name })
        assertEquals(listOf("sample.pdf"), folderEntries(files, "folder").map { it.name })
        assertTrue(folderEntries(files, "empty").isEmpty())
    }
    @Test fun unsupportedAndOversizedNeverSendRequests() = runTest {
        val s = service()
        rejected { s.download(project, file.copy(name = "app.exe")) }
        rejected { s.download(project, file.copy(size = ProjectFilesService.MAX_BYTES + 1)) }
        rejected { s.download(project, file.copy(isFolder = true)) }
        assertEquals(0, server.requestCount)
    }
    @Test fun legacyProjectStillListsLiveDesktop() = runTest {
        body("""{"id":1}""")
        body("""{"transfer":{"id":1,"kind":"LIST","status":"DONE","files":[{"id":"f","name":"sample.pdf","size":4}]}}""")
        val listing = service().files(project)
        assertEquals("desktop-1", listing.files.single().deviceId)
        assertEquals("/api/mobile/transfer/list", server.takeRequest().path)
    }
    @Test fun lostCreationResponseReusesRequestIdAcrossServiceRecreation() = runTest {
        server.enqueue(MockResponse().setResponseCode(503))
        rejected { service().download(project, file) }
        val first = server.takeRequest().body.readUtf8()
        body("""{"id":2}""")
        body("""{"transfer":{"id":2,"kind":"PULL","status":"STAGED","fileSize":4}}""")
        content(); body("""{"code":0}""")
        val s = service(); val local = s.download(project, file.copy(size = 8))
        assertEquals(first, server.takeRequest().body.readUtf8())
        assertEquals("test", local.readText())
        s.close(); assertFalse(local.exists())
        assertFalse(s.hasPending(project, file))
    }
    @Test fun ackRetryReusesSavedBytesAndTransfer() = runTest {
        body("""{"id":3}""")
        body("""{"transfer":{"id":3,"kind":"PULL","status":"STAGED","fileSize":4}}""")
        content(); server.enqueue(MockResponse().setResponseCode(503))
        val first = service(); rejected { first.download(project, file) }; first.close()
        body("""{"code":0}""")
        assertEquals("test", service().download(project, file).readText())
        assertEquals(5, server.requestCount)
        repeat(4) { server.takeRequest() }
        assertEquals("/api/mobile/transfer/3/ack", server.takeRequest().path)
    }
    @Test fun terminalFailureClearsOnlyUnfinishedRequest() = runTest {
        body("""{"id":4}""")
        body("""{"transfer":{"id":4,"kind":"PULL","status":"EXPIRED"}}""")
        val s = service(); rejected { s.download(project, file) }; assertFalse(s.hasPending(project, file))
    }
    @Test fun switchedAccountCannotSendOrReadPreview() = runTest {
        val s = service(); active = false
        rejected { s.download(project, file) }; assertEquals(0, server.requestCount)
    }
    @Test fun cloudIdentityWithoutSourceUsesConsentAndNeverCharges() = runTest {
        val cloud = project.copy(deviceId = "cloud", projectUid = "uid")
        assertTrue(isCloudFile(cloud, file))
        body("""{"enabled":true,"decided":true,"subscriptionActive":true}"""); content()
        val s = service(); val local = s.download(cloud, file.copy(uid = "fid"))
        assertEquals("/api/mobile/backup-consent", server.takeRequest().path)
        assertEquals("/api/mobile/preview/catalog/uid/files/fid/content", server.takeRequest().path)
        s.close(); assertFalse(local.exists())
    }
    @Test fun missingCloudConsentPreventsBytes() = runTest {
        body("""{"enabled":false,"decided":true,"subscriptionActive":true}""")
        rejected { service().download(project.copy(projectUid = "uid"), file.copy(uid = "fid", source = "backup")) }
        assertEquals(1, server.requestCount)
    }
    @Test fun invalidContentIsNotAcknowledgedOrRetained() = runTest {
        body("""{"id":5}"""); body("""{"transfer":{"id":5,"kind":"PULL","status":"STAGED","fileSize":4}}""")
        server.enqueue(MockResponse().setHeader("Content-Type", "text/html").setBody("oops"))
        rejected { service().download(project, file) }
        assertEquals(3, server.requestCount)
        assertEquals(0, root.walkTopDown().filter { it.extension == "pdf" }.count())
    }
    @Test fun redirectsDoNotForwardSessionToAnotherHost() = runTest {
        body("""{"id":6}"""); body("""{"transfer":{"id":6,"kind":"PULL","status":"STAGED","fileSize":4}}""")
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "http://127.0.0.1:1/private"))
        rejected { service().download(project, file) }; assertEquals(3, server.requestCount)
    }
    @Test fun explicitBackupChoiceUsesPutAndSharedConsentVersion() = runTest {
        val session = MemorySessionStore().also { it.save("synthetic") }
        val backend = Backend(server.url("/").toString().trimEnd('/'), session)
        body("""{"enabled":false,"decided":true,"subscriptionActive":false}""")
        assertTrue(backend.setBackupConsent(false).decided)
        val request = server.takeRequest(); assertEquals("PUT", request.method)
        assertTrue(request.body.readUtf8().contains(com.aiworkdeck.contract.ContractCapabilities.backupConsentVersion))
    }
    @Test fun backupConsentDialogCannotMutateNextAccount() = runTest {
        val session = MemorySessionStore().also { it.save("first") }
        val backend = Backend(server.url("/").toString().trimEnd('/'), session)
        val original = backend.accountSnapshot()
        session.save("second")
        rejected { original.setBackupConsent(true) }
        assertEquals(0, server.requestCount)
    }

}
