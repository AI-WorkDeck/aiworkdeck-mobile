package com.aiworkdeck.mobile.features.workspace

import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.model.ProjectLocation
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.FileEntry
import com.aiworkdeck.mobile.services.ProjectFile
import com.aiworkdeck.mobile.services.folderEntries
import java.io.File

/**
 * Pure rules behind the workspace screen (JVM-tested). Mirrors iOS `ProjectContentsView`,
 * `ProjectFileDirectory` and `FileDownloadView`.
 */
object WorkspaceLogic {
    /** Folder browsing uses metadata only; a search spans every folder and lists files only. */
    fun visibleEntries(files: List<ProjectFile>, folder: String, query: String): List<FileEntry> {
        val q = query.trim()
        if (q.isEmpty()) return folderEntries(files, folder)
        return files.filter { !it.isFolder && (it.name.contains(q, true) || it.path.contains(q, true)) }
            .sortedBy { it.name.lowercase() }
            .map { FileEntry(it.rowID, it.name, it.path, it) }
    }

    fun parentFolder(folder: String): String = folder.substringBeforeLast('/', "")

    fun alias(location: ProjectLocation) = location.deviceId + ":" + location.key

    /** Locations worth offering as a switch: only when the project lives in more than one place. */
    fun switchableLocations(project: RelayProject): List<ProjectLocation> =
        project.locations.orEmpty().takeIf { it.size > 1 }.orEmpty()

    /**
     * The project the file list reads from. Defaults to an online desktop (live listing), else the
     * catalogue's own source. The result carries only the chosen location, so the service cannot
     * silently list a different desktop than the one shown as selected.
     */
    fun storageProject(project: RelayProject, chosenAlias: String?): RelayProject {
        val locations = switchableLocations(project)
        if (locations.isEmpty()) return project
        val preferred = locations.firstOrNull { it.kind == "desktop" && it.online == true }?.let(::alias) ?: (project.deviceId + ":" + project.key)
        val location = locations.firstOrNull { alias(it) == (chosenAlias ?: preferred) } ?: return project
        return RelayProject(location.deviceId, location.deviceName, location.key, project.name, project.projectUid,
            listOf(location), project.isDefault, project.projectType)
    }

    /** iOS `catalogFiles` filter: with a location switch, a desktop/backup row belongs to its own desktop only. */
    fun filesForLocation(files: List<ProjectFile>, project: RelayProject, storage: RelayProject): List<ProjectFile> {
        if (switchableLocations(project).isEmpty()) return files
        val cloud = storage.deviceId == "cloud" || storage.deviceId.startsWith("cloud:")
        return files.filter {
            it.source == "cloud" || (cloud && it.source == null) ||
                ((it.source == "backup" || it.source == "desktop") && it.deviceId == storage.deviceId && it.projectKey == storage.key)
        }
    }

    fun supportsPreview(file: ProjectFile) = !file.isFolder && file.extension in ContractCapabilities.previewExtensions
}

/** Where a downloaded file is shown. Anything not rendered in-app goes to the system chooser. */
enum class PreviewKind { Image, Pdf, Audio, Video, External;
    companion object {
        // TIFF has no platform decoder and CAF has no Media3 extractor: hand both to another app.
        private val images = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp")
        private val audio = setOf("m4a", "mp3", "wav", "aac", "aif", "aiff")
        private val video = setOf("mp4", "mov", "m4v")
        fun of(extension: String): PreviewKind = when (extension.lowercase()) {
            in images -> Image
            "pdf" -> Pdf
            in audio -> Audio
            in video -> Video
            else -> External
        }
    }
}

/**
 * Reading-pane state for one selected file. Rules (contract/README.md "Cloud file downloads..."):
 * a cloud quote arms exactly one attempt, so any cloud failure needs a new quote and confirmation;
 * a desktop PULL keeps its request UUID while the service still holds it, so retry reuses it.
 */
data class ReaderState(
    val quote: String? = null,
    val approved: Boolean = false,
    val busy: Boolean = false,
    val error: String? = null,
    val local: File? = null,
) {
    val canConfirm: Boolean get() = quote != null && !approved && !busy && local == null
    val canRetrySame: Boolean get() = approved && !busy && local == null
    val canRequote: Boolean get() = !approved && quote == null && !busy && error != null && local == null

    companion object {
        fun loadingQuote() = ReaderState(busy = true)
        fun quoted(text: String) = ReaderState(quote = text)
        /** A retained desktop request is not charged again: offer retry of the same request, no quote. */
        fun pending() = ReaderState(approved = true)
        fun failedBeforeQuote(message: String) = ReaderState(error = message)
    }

    fun confirmed() = copy(approved = true, busy = true, error = null)
    fun downloaded(file: File) = copy(busy = false, error = null, local = file)
    fun failed(message: String, cloud: Boolean, requestRetained: Boolean): ReaderState =
        if (!cloud && requestRetained) copy(busy = false, error = message) else ReaderState(error = message)
}
