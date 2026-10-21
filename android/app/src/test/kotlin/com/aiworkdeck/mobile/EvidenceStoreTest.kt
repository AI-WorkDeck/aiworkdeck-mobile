package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.services.DeviceFacts
import com.aiworkdeck.mobile.services.EvidenceStore
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.time.Instant

class EvidenceStoreTest {
    @Rule @JvmField val tmp = TemporaryFolder()

    private fun facts() = DeviceFacts(model = "Pixel 8", osVersion = "14", appVersion = "1.0.0")
    private fun newTemp(name: String, bytes: String): File = tmp.newFile(name).apply { writeBytes(bytes.toByteArray()) }

    // ① save 后 media/ 有文件、manifest/ 有 JSON，且 sha256 与 MessageDigest 直接算的一致
    @Test fun saveWritesMediaAndManifestWithMatchingSha() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val temp = newTemp("incoming.jpg", "hello-world")

        val item = store.save(MediaKind.photo, temp, Instant.parse("2026-01-01T00:00:00Z"), null, null)

        val mediaFile = File(root, "media/${item.id}.jpg")
        val manifestFile = File(root, "manifest/${item.id}.json")
        assertTrue(mediaFile.exists())
        assertTrue(manifestFile.exists())

        val expectedSha = MessageDigest.getInstance("SHA-256").digest(mediaFile.readBytes())
            .joinToString("") { "%02x".format(it) }
        assertEquals(expectedSha, item.manifest.sha256)
        assertEquals(TransferState.waiting, item.state)
    }

    // ② loadAll 解析出的 state、project
    @Test fun loadAllDecodesStateAndProject() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val temp = newTemp("incoming2.jpg", "abc")
        val project = RelayProject(deviceId = "dev-1", deviceName = "台式机", key = "proj-key", name = "现场勘验")

        val saved = store.save(MediaKind.photo, temp, Instant.parse("2026-01-02T00:00:00Z"), null, project)
        store.updateState(saved.id, TransferState.uploaded)

        val all = store.loadAll()
        assertEquals(1, all.size)
        assertEquals(TransferState.uploaded, all.first().state)
        assertEquals(project, all.first().project)
    }

    // ③ 旧 iOS 格式行（含 "state":"moving"）解码为 uploading
    @Test fun loadAllDecodesLegacyIosMovingState() = runTest {
        val root = tmp.newFolder()
        File(root, "media").mkdirs()
        val manifestDir = File(root, "manifest").apply { mkdirs() }
        val id = "11111111-1111-1111-1111-111111111111"
        val legacy = """
            {
              "kind": "photo",
              "state": "moving",
              "progress": 0.42,
              "manifest": {
                "clientMediaId": "$id",
                "sha256": "${"a".repeat(64)}",
                "capturedAt": "2026-01-03T00:00:00Z",
                "deviceModel": "iPhone",
                "osVersion": "17.0",
                "appVersion": "1.0.0",
                "fromCamera": true
              }
            }
        """.trimIndent()
        File(manifestDir, "$id.json").writeText(legacy)

        val store = EvidenceStore(root, facts())
        val items = store.loadAll()

        assertEquals(1, items.size)
        assertEquals(TransferState.uploading, items.first().state)
        assertEquals(MediaKind.photo, items.first().kind)
        assertEquals(id, items.first().id)
    }

    // ④ updateState 持久化
    @Test fun updateStatePersists() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val temp = newTemp("incoming4.jpg", "xyz")
        val saved = store.save(MediaKind.photo, temp, Instant.now(), null, null)

        store.updateState(saved.id, TransferState.failed, progress = 0.5, error = "网络超时")

        val reloaded = store.loadAll().first()
        assertEquals(TransferState.failed, reloaded.state)
        assertEquals(0.5, reloaded.progress, 0.0001)
        assertEquals("网络超时", reloaded.lastError)
    }

    // ⑤ 有原件无 manifest 的孤儿被 sweepOrphans 清掉
    @Test fun sweepOrphansRemovesMediaWithoutManifest() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val temp = newTemp("incoming5.jpg", "keep")
        val saved = store.save(MediaKind.photo, temp, Instant.now(), null, null)

        val orphan = File(root, "media/orphan.jpg")
        orphan.writeBytes("orphan-bytes".toByteArray())
        assertTrue(orphan.exists())

        val removed = store.sweepOrphans()

        assertEquals(1, removed)
        assertFalse(orphan.exists())
        assertTrue(File(root, "media/${saved.id}.jpg").exists())
    }

    // ⑥ manifest 解析不了时原件仍要留着（保留名单按文件名算，不按解析结果）
    @Test fun sweepOrphansKeepsMediaWhoseManifestIsCorrupt() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val temp = newTemp("incoming7.jpg", "corrupt-owner")
        val saved = store.save(MediaKind.photo, temp, Instant.now(), null, null)
        File(root, "manifest/${saved.id}.json").writeText("{ 这不是合法 JSON")

        assertTrue(store.loadAll().isEmpty())
        val removed = store.sweepOrphans()

        assertEquals(0, removed)
        assertTrue(File(root, "media/${saved.id}.jpg").exists())
    }

    // ⑦ delete 同时删原件与 manifest
    @Test fun deleteRemovesMediaAndManifest() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val temp = newTemp("incoming6.jpg", "bye")
        val saved = store.save(MediaKind.photo, temp, Instant.now(), null, null)

        store.delete(setOf(saved.id))

        assertFalse(File(root, "media/${saved.id}.jpg").exists())
        assertFalse(File(root, "manifest/${saved.id}.json").exists())
        assertTrue(store.loadAll().isEmpty())
    }
    @Test fun failedAudioManifestKeepsOriginalForRecovery() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, facts())
        val manifestDir = File(root, "manifest")
        manifestDir.delete()
        manifestDir.writeText("block directory creation")
        val audio = newTemp("failed-recording.m4a", "recorded-audio")
        try {
            store.save(MediaKind.audio, audio, Instant.now(), null, null)
            fail("Saving a manifest into a regular file must fail")
        } catch (_: Exception) {
            assertTrue(audio.exists())
            assertEquals("recorded-audio", audio.readText())
        }
    }

    @Test fun assigningUnclassifiedCaptureNeverChangesPreviouslyTransferredIdentity() = runTest {
        val store = EvidenceStore(tmp.newFolder(), facts())
        val first = RelayProject("one", key = "p", name = "One")
        val second = RelayProject("two", key = "q", name = "Two")
        val waiting = store.save(MediaKind.photo, newTemp("waiting.jpg", "bytes"), Instant.now(), null, null)
        store.setProject(waiting.id, first)
        store.setProject(waiting.id, second)
        assertEquals(first, store.loadAll().single().project)
        val transferred = store.save(MediaKind.photo, newTemp("transferred.jpg", "bytes"), Instant.now(), null, null)
        store.updateState(transferred.id, TransferState.uploaded)
        store.setProject(transferred.id, second)
        assertNull(store.loadAll().first { it.id == transferred.id }.project)
    }

}
