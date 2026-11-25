package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppModelLogicTest {
    private val a = RelayProject(deviceId = "mac-1", key = "proj-a", name = "A")
    private val b = RelayProject(deviceId = "mac-2", key = "proj-b", name = "B")

    @Test
    fun `otherPendingCount 只数别的项目里没落盘的件`() {
        val items = listOf(
            TestItems.make(TransferState.waiting, a),      // 当前项目，不算
            TestItems.make(TransferState.failed, b),       // 别处、没落盘 → 算
            TestItems.make(TransferState.uploaded, b),     // 别处、没落盘 → 算
            TestItems.make(TransferState.arrived, b),      // 别处但已落盘 → 不算
            TestItems.make(TransferState.waiting, null),   // 没记项目 → 也算「别处」
        )
        assertEquals(3, otherPendingCount(items, a))
    }

    @Test
    fun `otherPendingCount 未选项目时把有项目的都算进别处`() {
        val items = listOf(TestItems.make(TransferState.waiting, a), TestItems.make(TransferState.waiting, null))
        assertEquals(1, otherPendingCount(items, null))
    }

    @Test
    fun `isDesktopOnline 三分钟窗口内为在线`() {
        val now = 1_700_000_000_000L
        assertTrue(isDesktopOnline(now - 1_000, now))
        assertTrue(isDesktopOnline(now - (DESKTOP_ONLINE_WINDOW_MS - 1), now))
        assertFalse(isDesktopOnline(now - DESKTOP_ONLINE_WINDOW_MS, now))
        assertFalse(isDesktopOnline(now - 10 * 60_000, now))
    }

    @Test
    fun `isDesktopOnline 没见过或时钟倒流一律离线`() {
        val now = 1_700_000_000_000L
        assertFalse(isDesktopOnline(null, now))
        // 时钟被改到过去：宁可说离线，也不要让人以为照片已经在往电脑走
        assertFalse(isDesktopOnline(now + 60_000, now))
    }

    @Test
    fun `offline desktop says how long it has been away`() {
        val now = 10_000_000L
        assertEquals("time.secondsAgo" to 5L, relativeShortKey(now - 5_000, now))
        assertEquals("time.minutesAgo" to 4L, relativeShortKey(now - 4 * 60_000, now))
        assertEquals("time.hoursAgo" to 2L, relativeShortKey(now - 2 * 3_600_000, now))
        assertEquals("time.daysAgo" to 1L, relativeShortKey(now - 86_400_000, now))
        assertEquals("never in the future", "time.secondsAgo" to 0L, relativeShortKey(now + 5_000, now))
    }
}
