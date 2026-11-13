package com.aiworkdeck.mobile

import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.workspace.PreviewKind
import com.aiworkdeck.mobile.features.workspace.ReaderState
import com.aiworkdeck.mobile.features.workspace.WorkspaceLogic
import com.aiworkdeck.mobile.model.ProjectLocation
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.ProjectFile
import com.aiworkdeck.mobile.services.quoteText
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class WorkspaceLogicTest {
    private val files = listOf(
        ProjectFile("1", "Brief.pdf", "Brief.pdf", 1),
        ProjectFile("2", "contract.docx", "Deals/Alpha/contract.docx", 1),
        ProjectFile("3", "photo.jpg", "Deals/photo.jpg", 1),
        ProjectFile("4", "Empty", "Archive", 0, isFolder = true),
        ProjectFile("5", "brief-notes.txt", "Deals/Alpha/brief-notes.txt", 1),
    )

    @Test fun browsingListsFoldersFirstThenFilesOfThatFolderOnly() {
        assertEquals(listOf("Archive", "Deals", "Brief.pdf"), WorkspaceLogic.visibleEntries(files, "", "").map { it.name })
        assertEquals(listOf("Alpha", "photo.jpg"), WorkspaceLogic.visibleEntries(files, "Deals", "").map { it.name })
        assertEquals(listOf("brief-notes.txt", "contract.docx"), WorkspaceLogic.visibleEntries(files, "Deals/Alpha", "").map { it.name })
        assertTrue(WorkspaceLogic.visibleEntries(files, "Archive", "").isEmpty())
    }

    @Test fun searchSpansAllFoldersMatchesNameOrPathAndSkipsFolders() {
        val byName = WorkspaceLogic.visibleEntries(files, "Deals", "BRIEF")
        assertEquals(listOf("brief-notes.txt", "Brief.pdf"), byName.map { it.name })
        assertTrue(byName.all { it.file != null })
        assertEquals(listOf("brief-notes.txt", "contract.docx"), WorkspaceLogic.visibleEntries(files, "", "alpha/").map { it.name })
        assertTrue(WorkspaceLogic.visibleEntries(files, "", "archive").isEmpty())
        // Whitespace-only search keeps folder browsing.
        assertEquals(WorkspaceLogic.visibleEntries(files, "Deals", ""), WorkspaceLogic.visibleEntries(files, "Deals", "  "))
    }

    @Test fun folderUpStopsAtRoot() {
        assertEquals("Deals", WorkspaceLogic.parentFolder("Deals/Alpha"))
        assertEquals("", WorkspaceLogic.parentFolder("Deals"))
        assertEquals("", WorkspaceLogic.parentFolder(""))
    }

    private val desktop = ProjectLocation("desktop", "pc-1", "k1", deviceName = "PC", online = true)
    private val offline = ProjectLocation("desktop", "pc-2", "k2", deviceName = "Laptop", online = false)
    private val cloud = ProjectLocation("cloud", "cloud", "c1")
    private val project = RelayProject("cloud", key = "c1", name = "Case", projectUid = "uid", locations = listOf(cloud, desktop, offline))

    @Test fun storageDefaultsToOnlineDesktopAndCarriesOnlyTheChosenLocation() {
        val preferred = WorkspaceLogic.storageProject(project, null)
        assertEquals("pc-1" to "k1", preferred.deviceId to preferred.key)
        assertEquals(listOf(desktop), preferred.locations)
        assertEquals("uid", preferred.projectUid)
        val chosen = WorkspaceLogic.storageProject(project, "cloud:c1")
        assertEquals("cloud", chosen.deviceId); assertEquals(listOf(cloud), chosen.locations)
        assertEquals(project, WorkspaceLogic.storageProject(project, "gone:x"))
        val noDesktop = project.copy(locations = listOf(cloud, offline))
        assertEquals("cloud", WorkspaceLogic.storageProject(noDesktop, null).deviceId)
    }

    @Test fun singleOrLegacyLocationIsNotSwitchableAndUnfiltered() {
        val legacy = RelayProject("pc-1", key = "k1", name = "Old")
        assertSame(legacy, WorkspaceLogic.storageProject(legacy, "cloud:c1"))
        val single = legacy.copy(locations = listOf(desktop))
        assertTrue(WorkspaceLogic.switchableLocations(single).isEmpty())
        val rows = listOf(ProjectFile("x", "a.pdf", "a.pdf", 1, source = "desktop", deviceId = "other", projectKey = "z"))
        assertEquals(rows, WorkspaceLogic.filesForLocation(rows, single, single))
    }

    @Test fun locationFilterKeepsCloudRowsAndOnlyTheChosenDesktopsRows() {
        val rows = listOf(
            ProjectFile("a", "a.pdf", "a.pdf", 1, source = "cloud"),
            ProjectFile("b", "b.pdf", "b.pdf", 1, source = "desktop", deviceId = "pc-1", projectKey = "k1"),
            ProjectFile("c", "c.pdf", "c.pdf", 1, source = "backup", deviceId = "pc-2", projectKey = "k2"),
            ProjectFile("d", "d.pdf", "d.pdf", 1),
        )
        val onDesktop = WorkspaceLogic.storageProject(project, null)
        assertEquals(listOf("a", "b"), WorkspaceLogic.filesForLocation(rows, project, onDesktop).map { it.id })
        val onCloud = WorkspaceLogic.storageProject(project, "cloud:c1")
        assertEquals(listOf("a", "d"), WorkspaceLogic.filesForLocation(rows, project, onCloud).map { it.id })
        val onLaptop = WorkspaceLogic.storageProject(project, "pc-2:k2")
        assertEquals(listOf("a", "c"), WorkspaceLogic.filesForLocation(rows, project, onLaptop).map { it.id })
    }

    @Test fun previewRoutingCoversEveryAndroidPreviewExtension() {
        assertEquals(PreviewKind.Image, PreviewKind.of("JPG"))
        assertEquals(PreviewKind.Image, PreviewKind.of("heic"))
        assertEquals(PreviewKind.Pdf, PreviewKind.of("pdf"))
        assertEquals(PreviewKind.Audio, PreviewKind.of("m4a"))
        assertEquals(PreviewKind.Video, PreviewKind.of("mov"))
        for (ext in listOf("docx", "pptx", "xlsx", "tif", "tiff", "caf")) assertEquals(ext, PreviewKind.External, PreviewKind.of(ext))
        val inApp = ContractCapabilities.previewExtensions.filter { PreviewKind.of(it) != PreviewKind.External }
        assertEquals(18, inApp.size)
    }

    @Test fun quoteThenConsentThenDownload() {
        val quoted = ReaderState.quoted("q")
        assertTrue(quoted.canConfirm); assertFalse(quoted.canRetrySame)
        val running = quoted.confirmed()
        assertTrue(running.busy && running.approved); assertFalse(running.canConfirm)
        val done = running.downloaded(File("x.pdf"))
        assertFalse(done.busy); assertFalse(done.canConfirm || done.canRetrySame || done.canRequote)
    }

    @Test fun cloudFailureAlwaysNeedsNewQuoteAndConsent() {
        val failed = ReaderState.quoted("q").confirmed().failed("boom", cloud = true, requestRetained = false)
        assertNull(failed.quote); assertFalse(failed.approved)
        assertTrue(failed.canRequote); assertFalse(failed.canRetrySame || failed.canConfirm)
        // Even if a ledger entry existed, a cloud attempt is never retried automatically.
        assertTrue(ReaderState.quoted("q").confirmed().failed("boom", cloud = true, requestRetained = true).canRequote)
    }

    @Test fun desktopFailureRetriesTheSameRequestOnlyWhileTheServiceKeepsIt() {
        val retained = ReaderState.quoted("q").confirmed().failed("net", cloud = false, requestRetained = true)
        assertTrue(retained.canRetrySame); assertEquals("net", retained.error); assertFalse(retained.canRequote)
        val terminal = ReaderState.quoted("q").confirmed().failed("gone", cloud = false, requestRetained = false)
        assertTrue(terminal.canRequote); assertFalse(terminal.canRetrySame)
        val pending = ReaderState.pending()
        assertTrue(pending.canRetrySame); assertNull(pending.quote); assertFalse(pending.canConfirm)
    }

    @Test fun monetaryQuoteWinsAndCarriesPartialChargeNotice() {
        val money = quoteText("a.pdf", 3, 125, "CNY")!!
        val (estimate, notice) = money.lines()
        assertTrue(estimate, estimate.contains("1.25") || estimate.contains("1,25"))
        assertEquals(tr("postpaid.partialCharge"), notice)
        assertEquals(tr("workspace.quote", mapOf("name" to "a.pdf", "credits" to 3)), quoteText("a.pdf", 3, null, null))
        assertEquals(tr("workspace.quote", mapOf("name" to "a.pdf", "credits" to 3)), quoteText("a.pdf", 3, 5, "EUR"))
        assertNull(quoteText("a.pdf", null, -1, "CNY"))
    }
}
