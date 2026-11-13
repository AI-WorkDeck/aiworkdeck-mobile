package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.ArchiveMove
import com.aiworkdeck.mobile.model.ArchiveMoveAccount
import com.aiworkdeck.mobile.model.ArchiveMoveRegistrationRejected
import com.aiworkdeck.mobile.model.ArchiveMoveReply
import com.aiworkdeck.mobile.model.ArchiveMoveService
import com.aiworkdeck.mobile.model.ArchiveMoveStatus
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.services.MediaStatus
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.services.ApiError
import com.aiworkdeck.mobile.services.ArchiveMoveQueue
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.DeviceFacts
import com.aiworkdeck.mobile.services.EvidenceStore
import com.aiworkdeck.mobile.services.UploadQueue
import com.aiworkdeck.mobile.services.UploadResult
import com.aiworkdeck.mobile.services.Uploader
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.time.Instant

/** 镜像 iOS ArchiveMoveQueueTests：已上传件改投项目的远端事务。 */
class ArchiveMoveQueueTest {
    @Rule @JvmField val tmp = TemporaryFolder()

    private val source = RelayProject(deviceId = "dev-1", key = "p-1", name = "甲案", projectUid = "uid-a")
    private val target = RelayProject(deviceId = "dev-2", key = "p-2", name = "乙案", projectUid = "uid-b")
    private val account = ArchiveMoveAccount(binding = "acct-1", baseUrl = "https://example.test", sessionId = "s-1")

    private class FakeService : ArchiveMoveService {
        val calls = mutableListOf<String>()
        val uploads = mutableListOf<Pair<String, String>>()
        var register: (ArchiveMove) -> ArchiveMoveReply = { reply(it, ArchiveMoveStatus.waitingTarget) }
        var status: (ArchiveMove) -> ArchiveMoveReply = { reply(it, ArchiveMoveStatus.done) }
        var retry: (ArchiveMove) -> ArchiveMoveReply = { reply(it, ArchiveMoveStatus.waitingTarget) }
        var upload: () -> Unit = {}
        override suspend fun registerMove(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply { calls += "register"; return register(move) }
        override suspend fun moveStatus(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply { calls += "status"; return status(move) }
        override suspend fun retryMove(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply { calls += "retry"; return retry(move) }
        override suspend fun uploadMoveTarget(item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount) {
            calls += "upload"; upload(); uploads += item.id to move.targetClientMediaId
        }
        companion object {
            fun reply(move: ArchiveMove, status: ArchiveMoveStatus, error: String? = null) =
                ArchiveMoveReply(move.requestId, status, move.targetClientMediaId, error)
        }
    }

    private fun newStore() = EvidenceStore(tmp.newFolder(), DeviceFacts("Pixel 8", "14", "1.0.0"))

    /** 一件已经传到中转区的件：有项目、尝试过上传。 */
    private suspend fun uploadedItem(store: EvidenceStore, bytes: String = "evidence"): CaptureItem {
        val temp = tmp.newFile().apply { writeText(bytes) }
        val item = store.save(MediaKind.photo, temp, Instant.parse("2026-11-01T08:00:00Z"), null, source)
        store.updateState(item.id, TransferState.uploading)
        store.updateState(item.id, TransferState.uploaded, progress = 1.0)
        return store.loadAll().single { it.id == item.id }
    }

    @Test fun movesUploadedItemThroughRegisterUploadAndDone() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        assertTrue(item.uploadAttempted)
        assertTrue(item.canRequestArchiveMove)
        assertFalse(item.canMoveToProject)
        val service = FakeService()
        val queue = ArchiveMoveQueue(store, service) { account }

        queue.begin(item.id, target)
        val pending = store.loadAll().single()
        assertTrue(pending.moveBlocksMutation)
        assertEquals(TransferState.uploading, pending.queueState)
        assertEquals(item.manifest.clientMediaId, pending.archiveMove!!.sourceClientMediaId)

        queue.kick()
        assertEquals(listOf("register", "upload", "status"), service.calls)
        assertEquals(pending.archiveMove!!.targetClientMediaId, service.uploads.single().second)
        val done = store.loadAll().single()
        assertEquals(ArchiveMoveStatus.done, done.archiveMove!!.status)
        assertEquals("uid-b", done.project!!.projectUid)
        assertEquals(TransferState.arrived, done.state)
        assertEquals(pending.archiveMove!!.targetClientMediaId, done.remoteClientMediaId)
        assertEquals(done.remoteClientMediaId, done.effectiveClientMediaId)
        // 本机证据身份不变
        assertEquals(item.id, done.id)
        assertEquals(item.manifest.clientMediaId, done.manifest.clientMediaId)
        assertFalse(done.moveBlocksMutation)
    }

    @Test fun explicitRegistrationRejectionUnlocksItem() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        val service = FakeService().apply { register = { throw ArchiveMoveRegistrationRejected("not registered") } }
        val queue = ArchiveMoveQueue(store, service) { account }
        queue.begin(item.id, target)
        queue.kick()
        val failed = store.loadAll().single()
        assertEquals(ArchiveMoveStatus.failed, failed.archiveMove!!.status)
        assertTrue(failed.archiveMove!!.registrationRejected)
        assertEquals("not registered", failed.queueError)
        assertFalse(failed.moveBlocksMutation)
        assertEquals(listOf("register"), service.calls)
        // 再踢不会再登记：被拒的事务不自动重来
        queue.kick()
        assertEquals(listOf("register"), service.calls)
    }

    @Test fun uncertainRegistrationKeepsItemLockedAndRetriesNextRound() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        var fail = true
        val service = FakeService().apply { register = { if (fail) throw IOException("timeout") else FakeService.reply(it, ArchiveMoveStatus.waitingSource) } }
        val queue = ArchiveMoveQueue(store, service) { account }
        queue.begin(item.id, target)
        queue.kick()
        val uncertain = store.loadAll().single()
        assertFalse(uncertain.archiveMove!!.registered)
        assertNotNull(uncertain.archiveMove!!.lastError)
        assertTrue(uncertain.moveBlocksMutation)
        fail = false
        queue.kick()
        val waiting = store.loadAll().single()
        assertEquals(ArchiveMoveStatus.waitingSource, waiting.archiveMove!!.status)
        assertTrue(waiting.archiveMove!!.targetUploaded)
        assertNull(waiting.archiveMove!!.lastError)
        assertEquals(listOf("register", "register"), service.calls)
    }

    @Test fun changedAccountStopsWithoutWriting() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        var current: ArchiveMoveAccount? = account
        val service = FakeService()
        val queue = ArchiveMoveQueue(store, service) { current }
        queue.begin(item.id, target)
        current = account.copy(binding = "someone-else")
        queue.kick()
        assertTrue(service.calls.isEmpty())
        try { queue.retry(item.id); fail("换账号后不能重试别人的事务") } catch (_: ApiError) {}
        current = null
        try { queue.begin(item.id, source); fail("没账号不能发起") } catch (_: ApiError) {}
    }

    @Test fun manualRetryUsesRetryEndpointAndReuploadsTarget() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        val service = FakeService().apply { status = { FakeService.reply(it, ArchiveMoveStatus.failed, "relay expired") } }
        val queue = ArchiveMoveQueue(store, service) { account }
        queue.begin(item.id, target)
        queue.kick()
        val failed = store.loadAll().single()
        assertEquals(ArchiveMoveStatus.failed, failed.archiveMove!!.status)
        assertEquals(TransferState.failed, failed.queueState)
        assertEquals("relay expired", failed.queueError)
        // 失败的事务不自动重跑
        service.calls.clear()
        queue.kick()
        assertTrue(service.calls.isEmpty())

        service.status = { FakeService.reply(it, ArchiveMoveStatus.done) }
        queue.retry(item.id)
        queue.kick()
        assertEquals(listOf("retry", "upload", "status"), service.calls)
        assertEquals(ArchiveMoveStatus.done, store.loadAll().single().archiveMove!!.status)
    }

    @Test fun beginRefusesSameProjectUnattemptedAndInProgress() = runTest {
        val store = newStore()
        val queue = ArchiveMoveQueue(store, FakeService()) { account }
        val item = uploadedItem(store)
        try { queue.begin(item.id, source.copy(name = "改名")); fail() } catch (e: ApiError) {}
        val fresh = store.save(MediaKind.photo, tmp.newFile().apply { writeText("x") }, Instant.now(), null, source)
        assertTrue(store.loadAll().single { it.id == fresh.id }.canMoveToProject)
        try { queue.begin(fresh.id, target); fail("未上传过的件直接改目标，不走远端移动") } catch (e: ApiError) {}
        queue.begin(item.id, target)
        try { queue.begin(item.id, target); fail() } catch (e: ApiError) {}
    }

    @Test fun lateReplyNeverUndoesDoneAndMismatchedReplyIsRejected() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        val queue = ArchiveMoveQueue(store, FakeService()) { account }
        queue.begin(item.id, target)
        val move = store.loadAll().single().archiveMove!!
        try {
            store.applyArchiveMoveReply(item.id, move.requestId, ArchiveMoveReply(move.requestId, ArchiveMoveStatus.done, "other-target"))
            fail("目标回执对不上要报错")
        } catch (_: ApiError) {}
        store.applyArchiveMoveReply(item.id, move.requestId, FakeService.reply(move, ArchiveMoveStatus.done))
        store.applyArchiveMoveReply(item.id, move.requestId, FakeService.reply(move, ArchiveMoveStatus.waitingTarget))
        assertEquals(ArchiveMoveStatus.done, store.loadAll().single().archiveMove!!.status)
    }

    @Test fun corruptedLocalCopyFailsBeforeUploadingTarget() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        val service = FakeService()
        val queue = ArchiveMoveQueue(store, service) { account }
        queue.begin(item.id, target)
        item.localFile.writeText("tampered")
        queue.kick()
        assertEquals(listOf("register"), service.calls)
        val pending = store.loadAll().single()
        assertTrue(pending.moveBlocksMutation)
        assertFalse(pending.archiveMove!!.targetUploaded)
        assertNotNull(pending.archiveMove!!.lastError)
    }

    @Test fun uploadQueueAndStateUpdatesLeaveMovingItemsAlone() = runTest {
        val store = newStore()
        val item = uploadedItem(store)
        ArchiveMoveQueue(store, FakeService()) { account }.begin(item.id, target)
        store.updateState(item.id, TransferState.waiting)
        store.updateState(item.id, TransferState.failed, cloudResumeRequired = true)
        assertEquals(TransferState.uploaded, store.loadAll().single().state)
        assertFalse(store.loadAll().single().cloudResumeRequired)

        val uploads = mutableListOf<String>()
        val uploader = object : Uploader {
            override suspend fun upload(item: CaptureItem, project: RelayProject, fileName: String, onProgress: (Double) -> Unit): UploadResult {
                uploads += item.id; return UploadResult(0, 1, item.effectiveClientMediaId, false)
            }
            override suspend fun mediaStatus(ids: List<String>): List<MediaStatus> { uploads += "status"; return emptyList() }
        }
        UploadQueue(store, uploader).run { kick(); retryFailed(); checkDelivered() }
        assertTrue(uploads.isEmpty())
        assertFalse(store.delete(setOf(item.id)))
        assertEquals(1, store.loadAll().size)
    }

    @Test fun moveToProjectOnlyBeforeFirstUploadAttempt() = runTest {
        val store = newStore()
        val fresh = store.save(MediaKind.photo, tmp.newFile().apply { writeText("x") }, Instant.now(), null, null)
        assertTrue(store.loadAll().single().canMoveToProject)
        store.moveToProject(fresh.id, target)
        val moved = store.loadAll().single()
        assertEquals("uid-b", moved.project!!.projectUid)
        assertEquals(TransferState.waiting, moved.state)
        store.updateState(fresh.id, TransferState.uploading)
        store.updateState(fresh.id, TransferState.failed, error = "x")
        assertTrue(store.loadAll().single().uploadAttempted)
        try { store.moveToProject(fresh.id, source); fail("尝试过上传就不能悄悄改去向") } catch (_: ApiError) {}
    }

    @Test fun copyToProjectMakesIndependentTransfer() = runTest {
        val store = newStore()
        val item = uploadedItem(store, bytes = "original-bytes")
        val copy = store.copyToProject(item.id, target)
        assertNotEquals(item.id, copy.id)
        assertEquals(copy.id, copy.manifest.clientMediaId)
        assertEquals(item.manifest.sha256, copy.manifest.sha256)
        assertEquals(item.manifest.capturedAt, copy.manifest.capturedAt)
        assertEquals(TransferState.waiting, copy.state)
        assertFalse(copy.uploadAttempted)
        assertEquals("original-bytes", copy.localFile.readText())
        val original = store.loadAll().single { it.id == item.id }
        assertEquals(TransferState.uploaded, original.state)
        assertEquals("uid-a", original.project!!.projectUid)
    }

    @Test fun legacyRowsWithProjectCountAsAttempted() = runTest {
        val root = tmp.newFolder()
        val store = EvidenceStore(root, DeviceFacts("x", "x", "x"))
        val item = store.save(MediaKind.photo, tmp.newFile().apply { writeText("x") }, Instant.now(), null, source)
        val manifest = java.io.File(root, "manifest/${item.id}.json")
        manifest.writeText(manifest.readText().replace(Regex(",?\\s*\"uploadAttempted\":\\s*false"), ""))
        assertTrue(EvidenceStore(root, DeviceFacts("x", "x", "x")).loadAll().single().uploadAttempted)
    }

    @Test fun decodeMoveResponseOnlyUnlocksExplicitRejection() {
        val ok = """{"code":0,"data":{"requestId":"r","status":"WAITING_TARGET","targetClientMediaId":"t"}}"""
        assertEquals(ArchiveMoveStatus.waitingTarget, Backend.decodeMoveResponse(ok, 200, registration = true).status)
        val rejected = """{"code":1,"kind":"MOVE_NOT_REGISTERED","message":"no"}"""
        try { Backend.decodeMoveResponse(rejected, 409, registration = true); fail() } catch (e: ArchiveMoveRegistrationRejected) { assertEquals("no", e.message) }
        // 非登记、5xx、笼统 code=1 都只是普通失败
        for ((text, code, registration) in listOf(Triple(rejected, 409, false), Triple(rejected, 502, true),
                Triple("""{"code":1,"message":"busy"}""", 200, true), Triple("not json", 200, true))) {
            try { Backend.decodeMoveResponse(text, code, registration); fail() }
            catch (e: ArchiveMoveRegistrationRejected) { fail("不确定的登记不能解锁") }
            catch (_: ApiError) {}
        }
    }
}
