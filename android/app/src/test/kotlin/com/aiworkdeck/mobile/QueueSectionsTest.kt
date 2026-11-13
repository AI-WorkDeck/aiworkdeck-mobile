package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.features.queue.QueueSections
import com.aiworkdeck.mobile.features.queue.expiresSoon
import com.aiworkdeck.mobile.model.ArchiveMove
import com.aiworkdeck.mobile.model.ArchiveMoveStatus
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class QueueSectionsTest {
    private val a = RelayProject(deviceId = "d", key = "a", name = "甲")
    private val b = RelayProject(deviceId = "d", key = "b", name = "乙")

    private fun moving(item: CaptureItem, status: ArchiveMoveStatus, rejected: Boolean = false) = item.copy(
        uploadAttempted = true,
        archiveMove = ArchiveMove("r", item.manifest.clientMediaId, "t", a, b, "s", 1, "acct", status = status, registrationRejected = rejected),
    )

    @Test fun sectionsCoverAllProjectsAndUnassigned() {
        val failed = TestItems.make(TransferState.failed, a)
        val unassigned = TestItems.make(TransferState.waiting, null)
        val waiting = TestItems.make(TransferState.waiting, b)
        val uploading = TestItems.make(TransferState.uploading, a)
        val staged = TestItems.make(TransferState.uploaded, b)
        val landed = TestItems.make(TransferState.arrived, a)
        val s = QueueSections.of(listOf(failed, unassigned, waiting, uploading, staged, landed))
        assertEquals(listOf(failed), s.failed)
        assertEquals(listOf(unassigned), s.unassigned)
        assertEquals(listOf(waiting, uploading), s.active)
        assertEquals(listOf(staged), s.staged)
        assertEquals(listOf(landed), s.landed)
    }

    @Test fun pendingMoveCountsAsActiveAndFailedMoveAsFailed() {
        val pending = moving(TestItems.make(TransferState.uploaded, a), ArchiveMoveStatus.waitingTarget)
        val failedMove = moving(TestItems.make(TransferState.arrived, a), ArchiveMoveStatus.failed, rejected = true)
        val done = moving(TestItems.make(TransferState.arrived, b), ArchiveMoveStatus.done)
        val s = QueueSections.of(listOf(pending, failedMove, done))
        assertEquals(listOf(pending), s.active)
        assertEquals(listOf(failedMove), s.failed)
        assertEquals(listOf(done), s.landed)
        assertTrue(s.staged.isEmpty())
        assertEquals(ArchiveMoveStatus.waitingTarget.caption, pending.queueCaption)
        assertEquals(TransferState.uploading, pending.queueState)
        assertEquals(TransferState.failed, failedMove.queueState)
        assertEquals(TransferState.arrived.caption, done.queueCaption)
    }

    @Test fun expiresSoonUsesExactThreeDayWindow() {
        val now = Instant.parse("2026-09-02T00:00:00Z")
        assertTrue(expiresSoon("2026-09-04T23:59:00Z", now))
        assertFalse(expiresSoon("2026-09-05T00:00:00Z", now))
        assertTrue(expiresSoon("2026-09-01T00:00:00Z", now))
        assertFalse(expiresSoon(null, now))
        assertFalse(expiresSoon("不是时间", now))
    }
}
