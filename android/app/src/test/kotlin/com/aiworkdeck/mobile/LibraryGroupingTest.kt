package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.model.LibraryGrouping
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.CatalogProject
import com.aiworkdeck.mobile.model.ProjectLocation
import com.aiworkdeck.mobile.model.TransferState
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class LibraryGroupingTest {
    private val zone = ZoneOffset.UTC

    @Test fun catalogIdentityKeepsLegacyCapturesAndCloudProjects() {
        val old = RelayProject(deviceId = "desk-a", key = "7", name = "Before")
        val catalog = CatalogProject("uid", "After", listOf(
            ProjectLocation("desktop", "desk-a", "7", online = false),
            ProjectLocation("desktop", "desk-b", "9", online = true)))
        val current = catalog.toRelayProject()
        val item = TestItems.make(TransferState.uploaded, project = old)
        assertEquals("desk-b", current.deviceId)
        assertTrue(current.matches(old))
        assertEquals(listOf("uid"), LibraryGrouping.projectsIn(listOf(item), current).map { it.id })
        assertEquals(listOf(item), LibraryGrouping.itemsIn(listOf(item), "uid", current))
        assertEquals("desk-a", item.project?.deviceId)
        val cloud = CatalogProject("cloud-uid", "After", listOf(ProjectLocation("cloud", "cloud", "3", online = true))).toRelayProject()
        assertEquals("cloud", cloud.deviceId)
        assertFalse(cloud.matches(current))
    }

    @Test fun groupByDayNewestFirstWithHeader() {
        val day1a = TestItems.make(TransferState.arrived, at = Instant.parse("2026-09-02T08:00:00Z"))
        val day1b = TestItems.make(TransferState.arrived, at = Instant.parse("2026-09-02T09:00:00Z"))
        val day0 = TestItems.make(TransferState.arrived, at = Instant.parse("2026-09-01T10:00:00Z"))
        val sections = LibraryGrouping.groupByDay(listOf(day0, day1a, day1b), zone)

        assertEquals(2, sections.size)
        assertEquals("9月2日 · 2 件", sections[0].title)
        assertEquals("9月1日 · 1 件", sections[1].title)
        // 段内按时间倒序：09:00 在 08:00 前面
        assertEquals(day1b.id, sections[0].items[0].id)
        assertEquals(day1a.id, sections[0].items[1].id)
    }

    @Test fun projectsInPutsCurrentFirstAndGroupsUnknown() {
        val current = RelayProject(deviceId = "d1", key = "k1", name = "现场 A")
        val other = RelayProject(deviceId = "d2", key = "k2", name = "现场 B")
        val items = listOf(
            TestItems.make(TransferState.arrived, project = current),
            TestItems.make(TransferState.arrived, project = other),
            TestItems.make(TransferState.arrived, project = null),
        )
        val choices = LibraryGrouping.projectsIn(items, current)

        assertEquals(current.id, choices[0].id)
        assertTrue(choices.any { it.id == "unknown" && it.name == "未归类" })
        assertTrue(choices.any { it.id == other.id })
    }

    @Test fun itemsInFiltersByProjectAndBucketsUnknown() {
        val a = RelayProject(deviceId = "d1", key = "k1", name = "现场 A")
        val mine = TestItems.make(TransferState.arrived, project = a)
        val orphan = TestItems.make(TransferState.arrived, project = null)
        val other = TestItems.make(TransferState.arrived, project = RelayProject(deviceId = "d2", key = "k2", name = "现场 B"))
        val all = listOf(mine, orphan, other)

        assertEquals(listOf(mine.id), LibraryGrouping.itemsIn(all, a.id).map { it.id })
        assertEquals(listOf(orphan.id), LibraryGrouping.itemsIn(all, "unknown").map { it.id })
    }

    @Test fun itemsInWithNoProjectSelectedShowsNothing() {
        val all = listOf(TestItems.make(TransferState.arrived, project = null))
        assertTrue(LibraryGrouping.itemsIn(all, null).isEmpty())
    }

    @Test fun deleteWarningLevelWorstBucketWins() {
        val (level, n) = LibraryGrouping.deleteWarningLevel(
            listOf(TransferState.arrived, TransferState.uploaded, TransferState.waiting))
        assertEquals("unsent", level)
        assertEquals(1, n)
    }
}
