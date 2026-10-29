package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.services.DeviceFacts
import com.aiworkdeck.mobile.services.EvidenceStore
import com.aiworkdeck.mobile.services.KickResult
import com.aiworkdeck.mobile.services.MediaStatus
import com.aiworkdeck.mobile.services.UploadQueue
import com.aiworkdeck.mobile.services.UploadResult
import com.aiworkdeck.mobile.services.Uploader
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.time.Instant

class UploadQueueTest {
    @Rule @JvmField val tmp = TemporaryFolder()

    private fun facts() = DeviceFacts(model = "Pixel 8", osVersion = "14", appVersion = "1.0.0")
    private fun newStore(): EvidenceStore = EvidenceStore(tmp.newFolder(), facts())
    private fun project() = RelayProject(deviceId = "dev-1", deviceName = null, key = "proj-1", name = "现场勘验")
    private fun tempFile(name: String): File = tmp.newFile(name).apply { writeBytes("x".toByteArray()) }

    private data class UploadCall(val itemId: String, val fileName: String, val projectKey: String)

    private class FakeUploader : Uploader {
        var shouldThrow: (() -> Exception)? = null
        var statusResponses: List<MediaStatus> = emptyList()
        var onUpload: suspend () -> Unit = {}
        val calls = mutableListOf<UploadCall>()

        override suspend fun upload(
            item: CaptureItem, project: RelayProject, fileName: String, onProgress: (Double) -> Unit,
        ): UploadResult {
            onUpload()
            shouldThrow?.let { throw it() }
            calls += UploadCall(item.id, fileName, project.key)
            onProgress(1.0)
            return UploadResult(code = 0, id = calls.size.toLong(), clientMediaId = item.manifest.clientMediaId, delivered = false)
        }

        override suspend fun mediaStatus(ids: List<String>): List<MediaStatus> = statusResponses
    }

    // ① 两个 waiting 件按拍摄时间顺序上传、都变 uploaded、fileName 前缀/扩展名正确
    @Test fun kickUploadsAllWaitingItemsInCapturedOrder() = runTest {
        val store = newStore()
        val proj = project()
        val older = store.save(MediaKind.photo, tempFile("a.jpg"), Instant.parse("2026-01-01T00:00:00Z"), null, proj)
        val newer = store.save(MediaKind.photo, tempFile("b.jpg"), Instant.parse("2026-01-02T00:00:00Z"), null, proj)
        val uploader = FakeUploader()
        val queue = UploadQueue(store, uploader)

        val result = queue.kick()

        assertEquals(KickResult.done, result)
        val all = store.loadAll().associateBy { it.id }
        assertEquals(TransferState.uploaded, all.getValue(older.id).state)
        assertEquals(TransferState.uploaded, all.getValue(newer.id).state)
        assertEquals(listOf(older.id, newer.id), uploader.calls.map { it.itemId })
        assertTrue(uploader.calls[0].fileName.startsWith("现场影像-"))
        assertTrue(uploader.calls[0].fileName.endsWith(".jpg"))
    }

    // ② 失败→failed 且 lastError 有值；nextAutoKickAt 首败 +60s，再败 +120s；成功后复位到 +60s
    @Test fun failureRecordsErrorAndBacksOffThenResetsOnSuccess() = runTest {
        val store = newStore()
        val proj = project()
        val item = store.save(MediaKind.photo, tempFile("f.jpg"), Instant.parse("2026-01-01T00:00:00Z"), null, proj)
        val now = 1_000_000L
        val uploader = FakeUploader()
        uploader.shouldThrow = { IOException("network down") }
        val queue = UploadQueue(store, uploader, clock = { now })

        queue.kick()
        var reloaded = store.loadAll().first()
        assertEquals(TransferState.failed, reloaded.state)
        assertEquals("network down", reloaded.lastError)
        assertEquals(now + 60_000, queue.nextAutoKickAt)

        queue.retryFailed()
        assertEquals(now + 120_000, queue.nextAutoKickAt)

        uploader.shouldThrow = null
        queue.retryFailed()
        reloaded = store.loadAll().first()
        assertEquals(TransferState.uploaded, reloaded.state)

        // 复位校验用一件全新的 waiting 件（前一件已经 uploaded，retryFailed 对它无事可做）
        val second = store.save(MediaKind.photo, tempFile("f2.jpg"), Instant.parse("2026-01-01T00:00:00Z"), null, proj)
        uploader.shouldThrow = { IOException("down again") }
        queue.kick()
        assertEquals(TransferState.failed, store.loadAll().first { it.id == second.id }.state)
        assertEquals(now + 60_000, queue.nextAutoKickAt)
    }

    // ③ kick 开头把滞留的 uploading 件回拨 waiting，再在同一次 kick 里传完
    @Test fun kickRecoversStaleUploadingBeforeUploading() = runTest {
        val store = newStore()
        val proj = project()
        val item = store.save(MediaKind.photo, tempFile("s.jpg"), Instant.parse("2026-01-01T00:00:00Z"), null, proj)
        store.updateState(item.id, TransferState.uploading, progress = 0.5)
        val uploader = FakeUploader()
        val queue = UploadQueue(store, uploader)

        val result = queue.kick()

        assertEquals(KickResult.done, result)
        assertEquals(TransferState.uploaded, store.loadAll().first().state)
        assertEquals(listOf(item.id), uploader.calls.map { it.itemId })
    }

    // ④ checkDelivered：delivered→arrived；pending 保持 uploaded 并返回 clientMediaId(小写)→expiresAt
    @Test fun checkDeliveredMergesStatusAndReturnsExpiryForPending() = runTest {
        val store = newStore()
        val proj = project()
        val delivered = store.save(MediaKind.photo, tempFile("d.jpg"), Instant.parse("2026-01-01T00:00:00Z"), null, proj)
        store.updateState(delivered.id, TransferState.uploaded, progress = 1.0)
        val pending = store.save(MediaKind.photo, tempFile("p.jpg"), Instant.parse("2026-01-01T00:00:01Z"), null, proj)
        store.updateState(pending.id, TransferState.uploaded, progress = 1.0)

        val uploader = FakeUploader()
        uploader.statusResponses = listOf(
            MediaStatus(clientMediaId = delivered.manifest.clientMediaId.uppercase(), delivered = true, waitingSeconds = 0, expiresAt = null),
            MediaStatus(clientMediaId = pending.manifest.clientMediaId, delivered = false, waitingSeconds = 120, expiresAt = "2026-01-08T00:00:00"),
        )
        val queue = UploadQueue(store, uploader)

        val expiry = queue.checkDelivered()

        val all = store.loadAll().associateBy { it.id }
        assertEquals(TransferState.arrived, all.getValue(delivered.id).state)
        assertEquals(TransferState.uploaded, all.getValue(pending.id).state)
        assertEquals(mapOf(pending.manifest.clientMediaId.lowercase() to "2026-01-08T00:00:00"), expiry)
    }

    // ⑤ 没有 project 的件跳过不上传，保持 waiting
    @Test fun kickSkipsItemsWithoutProject() = runTest {
        val store = newStore()
        val orphan = store.save(MediaKind.photo, tempFile("o.jpg"), Instant.parse("2026-01-01T00:00:00Z"), null, null)
        val uploader = FakeUploader()
        val queue = UploadQueue(store, uploader)

        val result = queue.kick()

        assertEquals(KickResult.done, result)
        assertEquals(TransferState.waiting, store.loadAll().first().state)
        assertTrue(uploader.calls.isEmpty())
    }

    @Test fun workerWaitsForConcurrentUploadBeforeReportingCompletion() = runTest {
        val store = newStore()
        store.save(MediaKind.photo, tempFile("concurrent.jpg"), Instant.now(), null, project())
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val uploader = FakeUploader().apply { onUpload = { started.complete(Unit); release.await() } }
        val queue = UploadQueue(store, uploader)
        val foregroundUpload = async { queue.kick() }
        started.await()
        assertEquals(KickResult.alreadyRunning, queue.kick())
        val worker = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) { queue.kick(waitForCurrent = true) }
        assertFalse(worker.isCompleted)
        release.complete(Unit)
        assertEquals(KickResult.done, foregroundUpload.await())
        assertEquals(KickResult.done, worker.await())
        assertEquals(1, uploader.calls.size)
        assertEquals(TransferState.uploaded, store.loadAll().single().state)
    }

    @Test fun cancellingWaitingWorkerDoesNotCancelTheOtherUploadOrKeepTheLock() = runTest {
        val store = newStore()
        store.save(MediaKind.photo, tempFile("cancel-wait.jpg"), Instant.now(), null, project())
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val uploader = FakeUploader().apply { onUpload = { started.complete(Unit); release.await() } }
        val queue = UploadQueue(store, uploader)
        val foregroundUpload = async { queue.kick() }
        started.await()
        val worker = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) { queue.kick(waitForCurrent = true) }
        worker.cancelAndJoin()
        assertTrue(worker.isCancelled)
        assertTrue(foregroundUpload.isActive)
        release.complete(Unit)
        assertEquals(KickResult.done, foregroundUpload.await())
        assertEquals(KickResult.done, queue.kick(waitForCurrent = true))
        assertEquals(1, uploader.calls.size)
    }
}
