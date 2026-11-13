package com.aiworkdeck.mobile.features.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.R
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.PrimaryButton
import com.aiworkdeck.mobile.design.RowItem
import com.aiworkdeck.mobile.design.Segmented
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.library.LibraryScreen
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.ProjectFile
import com.aiworkdeck.mobile.services.ProjectFilesService
import com.aiworkdeck.mobile.services.isCloudFile
import com.aiworkdeck.mobile.services.userFacingMessage
import com.aiworkdeck.mobile.services.validatePreview
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** The selected file and the storage snapshot it was chosen from (a later location switch closes it). */
private data class Selection(val file: ProjectFile, val project: RelayProject) {
    val cloud: Boolean get() = isCloudFile(project, file)
}

/** Not placed = not drawn or touchable, but still composed: hiding the list never restarts a paid pull or a player. */
private fun Modifier.hiddenIf(hidden: Boolean) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    if (hidden) layout(0, 0) {} else layout(placeable.width, placeable.height) { placeable.place(0, 0) }
}

/** iOS `ProjectContentsView`: Files / Records tabs; files list with a reading pane beside or over it. */
@Composable
internal fun ProjectContents(
    model: AppModel, project: RelayProject, service: ProjectFilesService,
    onBusyChanged: (Boolean) -> Unit, onChromeHidden: (Boolean) -> Unit,
    onOpenViewer: (List<CaptureItem>, Int) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var tab by remember(project.id) { mutableStateOf("files") }
    var locationAlias by remember(project.id) { mutableStateOf<String?>(null) }
    val storage = WorkspaceLogic.storageProject(project, locationAlias)
    val storageKey = project.id + ":" + storage.deviceId + ":" + storage.key
    var folder by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var files by remember { mutableStateOf<List<ProjectFile>>(emptyList()) }
    var truncated by remember { mutableStateOf(false) }
    var loadedKey by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var selection by remember { mutableStateOf<Selection?>(null) }
    var reader by remember { mutableStateOf(ReaderState()) }
    var readerJob by remember { mutableStateOf<Job?>(null) }
    var showList by remember { mutableStateOf(false) }
    var focus by remember { mutableStateOf(false) }

    fun setBusy(state: ReaderState) { reader = state; onBusyChanged(state.busy) }
    fun closeReading() {
        readerJob?.cancel(); readerJob = null
        selection = null; showList = false; focus = false; setBusy(ReaderState()); onChromeHidden(false)
    }

    suspend fun load() {
        val request = ++generation
        val target = storage; val key = storageKey
        loading = true; error = null
        if (loadedKey != key) { files = emptyList(); loadedKey = null }
        try {
            val listing = service.files(target)
            if (generation != request) return
            files = WorkspaceLogic.filesForLocation(listing.files, project, target); truncated = listing.truncated; loadedKey = key
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (generation == request) error = userFacingMessage(e) }
        finally { if (generation == request) loading = false }
    }

    suspend fun download(selected: Selection) {
        setBusy(reader.confirmed())
        try { setBusy(reader.downloaded(service.download(selected.project, selected.file))) }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            // Desktop transport failures keep the saved request (same UUID, no new charge);
            // a cloud attempt or a terminal desktop failure needs a fresh quote and consent.
            setBusy(reader.failed(userFacingMessage(e, tr("files.previewFailed")), selected.cloud,
                requestRetained = !selected.cloud && service.hasPending(selected.project, selected.file)))
        }
    }

    suspend fun prepare(selected: Selection) {
        val file = selected.file
        if (!WorkspaceLogic.supportsPreview(file)) { setBusy(ReaderState()); return }
        try {
            validatePreview(file)
            check(PreviewKind.of(file.extension) != PreviewKind.External || canOpenExternally(context, file.extension)) { tr("files.noPreviewApp") }
        } catch (e: Exception) { setBusy(ReaderState.failedBeforeQuote(userFacingMessage(e, tr("files.unsupported")))); return }
        if (!selected.cloud && service.hasPending(selected.project, file)) { setBusy(ReaderState.pending()); return }
        if (selected.cloud && service.hasCloudCache(selected.project, file)) { setBusy(ReaderState(approved = true)); download(selected); return }
        setBusy(ReaderState.loadingQuote())
        try {
            setBusy(ReaderState.quoted(if (selected.cloud) service.cloudQuote(selected.project, file) else service.desktopQuote(file)))
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { setBusy(ReaderState.failedBeforeQuote(userFacingMessage(e))) }
    }

    fun open(file: ProjectFile) {
        if (reader.busy) return
        readerJob?.cancel()
        val selected = Selection(file, storage)
        selection = selected; showList = false; reader = ReaderState()
        readerJob = scope.launch { prepare(selected) }
    }

    LaunchedEffect(storageKey) {
        query = ""; folder = ""; closeReading()
        load()
    }
    BackHandler(enabled = selection != null || folder.isNotEmpty() || reader.busy) {
        when {
            reader.busy -> Unit
            selection != null -> closeReading()
            else -> folder = WorkspaceLogic.parentFolder(folder)
        }
    }

    Column(Modifier.fillMaxSize()) {
        if (!focus) Segmented(
            listOf("files" to tr("workspace.files"), "records" to tr("workspace.records")), tab,
            onSelect = { if (it != tab) { closeReading(); tab = it } },
            enabled = !reader.busy, modifier = Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
        )
        if (tab == "records") {
            Box(Modifier.weight(1f)) {
                LibraryScreen(model, onOpenViewer = onOpenViewer, onClose = { tab = "files" }, fixedProject = project)
            }
            return@Column
        }
        if (selection != null) Row(
            Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.gutter),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s4),
        ) {
            PaneToggle(R.drawable.ic_list, tr(if (showList) "workspace.returnReading" else "workspace.fileList")) { showList = !showList; focus = false; onChromeHidden(false) }
            Box(Modifier.weight(1f))
            PaneToggle(R.drawable.ic_fullscreen, tr("workspace.focusReading")) { focus = !focus; showList = false; onChromeHidden(focus) }
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val reading = selection
            // iOS FilePaneGeometry, minus fold handling: a wide landscape window reads beside the list.
            val split = reading != null && !focus && !showList && maxWidth >= 720.dp && maxWidth > maxHeight
            val listVisible = reading == null || showList || split
            val readerVisible = reading != null && !showList
            val listWidth = min(320.dp, maxWidth * 0.34f)
            Row(Modifier.fillMaxSize()) {
                Box(
                    (if (split) Modifier.width(listWidth) else if (listVisible) Modifier.weight(1f) else Modifier)
                        .fillMaxHeight().hiddenIf(!listVisible),
                ) {
                    FilesPane(project, storage, locationAlias = { locationAlias = it }, folder, { folder = it }, query, { query = it },
                        files = if (loadedKey == storageKey) files else emptyList(), truncated = truncated && loadedKey == storageKey,
                        loading = loading, error = error, busy = reader.busy, selectedRow = reading?.file?.rowID,
                        onRefresh = { scope.launch { load() } }, onOpen = ::open)
                }
                if (reading != null) Box(
                    (if (readerVisible) Modifier.weight(1f) else Modifier).fillMaxHeight().hiddenIf(!readerVisible),
                ) {
                    key(reading.project.id + ":" + reading.file.rowID) {
                        ReaderPane(reading.file, reading.cloud, reader, onClose = ::closeReading,
                            onConfirm = { readerJob = scope.launch { download(reading) } },
                            onRequote = { readerJob = scope.launch { prepare(reading) } })
                    }
                }
            }
        }
    }
}

@Composable
private fun PaneToggle(icon: Int, label: String, onClick: () -> Unit) {
    Row(Modifier.clickable(onClick = onClick).padding(vertical = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
        Icon(painterResource(icon), contentDescription = null, tint = Tk.L.accent, modifier = Modifier.size(20.dp))
        Text(label, style = Fonts.small(), color = Tk.L.accent)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FilesPane(
    project: RelayProject, storage: RelayProject, locationAlias: (String) -> Unit,
    folder: String, onFolder: (String) -> Unit, query: String, onQuery: (String) -> Unit,
    files: List<ProjectFile>, truncated: Boolean, loading: Boolean, error: String?, busy: Boolean, selectedRow: String?,
    onRefresh: () -> Unit, onOpen: (ProjectFile) -> Unit,
) {
    val context = LocalContext.current
    val entries = WorkspaceLogic.visibleEntries(files, folder, query)
    Column(Modifier.fillMaxSize()) {
        val locations = WorkspaceLogic.switchableLocations(project)
        if (locations.isNotEmpty()) {
            var menu by remember { mutableStateOf(false) }
            fun label(l: com.aiworkdeck.mobile.model.ProjectLocation) = if (l.kind == "cloud") tr("project.cloud") else (l.deviceName ?: l.deviceId)
            val chosen = locations.firstOrNull { it.deviceId == storage.deviceId && it.key == storage.key }
            Row(Modifier.padding(horizontal = Tk.Sp.gutter), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                Text(tr("workspace.storageLocation"), style = Fonts.small(), color = Tk.L.fgMuted)
                Box {
                    TextAction((chosen?.let(::label) ?: storage.name) + " ▾", enabled = !busy) { menu = true }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        for (l in locations) DropdownMenuItem(text = { Text(label(l), style = Fonts.body()) },
                            onClick = { menu = false; locationAlias(WorkspaceLogic.alias(l)) })
                    }
                }
            }
        }
        SearchField(query, onQuery, tr("workspace.searchFiles"), Modifier.padding(horizontal = Tk.Sp.gutter))
        if (query.isEmpty()) Row(Modifier.padding(start = Tk.Sp.gutter, end = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically) {
            TextAction(tr("workspace.folderRoot")) { onFolder("") }
            if (folder.isNotEmpty()) {
                Text("/ $folder", style = Fonts.micro(), color = Tk.L.fgMuted, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(horizontal = Tk.Sp.s2))
                IconAction(R.drawable.ic_folder_up, tr("workspace.folderUp"), enabled = true) { onFolder(WorkspaceLogic.parentFolder(folder)) }
            }
        }
        if (truncated) Text(tr("workspace.limit"), style = Fonts.micro(), color = Tk.L.fgMuted, modifier = Modifier.padding(horizontal = Tk.Sp.gutter))
        if (loading) Column(Modifier.padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2)) {
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.rule)
            Text(tr("workspace.loading"), style = Fonts.micro(), color = Tk.L.fgMuted)
        }
        error?.let {
            Column(Modifier.padding(horizontal = Tk.Sp.gutter)) {
                Text(it, style = Fonts.small(), color = Tk.S.failed)
                TextAction(tr("project.retry"), enabled = !loading, onClick = onRefresh)
            }
        }
        PullToRefreshBox(isRefreshing = loading, onRefresh = onRefresh, modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize()) {
                items(entries, key = { it.key }) { entry ->
                    val file = entry.file
                    if (file == null) {
                        RowItem(onClick = { onFolder(entry.path) },
                            leading = { Icon(painterResource(R.drawable.ic_folder), null, tint = Tk.L.fgMuted, modifier = Modifier.size(20.dp)) },
                            trailing = { Icon(painterResource(R.drawable.ic_chevron_right), null, tint = Tk.L.fgFaint, modifier = Modifier.size(20.dp)) }) {
                            Text(entry.name, style = Fonts.body(), color = Tk.L.fg, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    } else {
                        RowItem(
                            modifier = if (file.rowID == selectedRow) Modifier.background(Tk.L.accentWash) else Modifier,
                            onClick = if (busy) null else ({ onOpen(file) }),
                            leading = { Icon(painterResource(R.drawable.ic_file), null, tint = Tk.L.fgMuted, modifier = Modifier.size(20.dp)) },
                            trailing = { Text(android.text.format.Formatter.formatShortFileSize(context, file.size), style = Fonts.micro(), color = Tk.L.fgMuted) },
                        ) {
                            Column {
                                Text(file.name, style = Fonts.body(), color = Tk.L.fg, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                Text(file.path, style = Fonts.micro(), color = Tk.L.fgFaint, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                    Hairline(color = Tk.L.rule)
                }
                if (!loading && error == null && entries.isEmpty()) item(key = "empty") {
                    Column(Modifier.padding(Tk.Sp.gutter), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                        Text(tr(if (query.isEmpty()) "workspace.noFiles" else "workspace.noMatches"), style = Fonts.body(), color = Tk.L.fg)
                        val cloud = storage.deviceId == "cloud" || storage.deviceId.startsWith("cloud:")
                        Text(tr(if (cloud) "workspace.cloudHint" else "workspace.desktopHint"), style = Fonts.small(), color = Tk.L.fgMuted)
                    }
                }
            }
        }
    }
}

/** iOS `FileDownloadView`: quote → explicit consent → download → in-app preview (or the system chooser). */
@Composable
private fun ReaderPane(file: ProjectFile, cloud: Boolean, state: ReaderState, onClose: () -> Unit, onConfirm: () -> Unit, onRequote: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = Tk.Sp.gutter, end = Tk.Sp.gutter), verticalAlignment = Alignment.CenterVertically) {
            Text(file.name, style = Fonts.heading(), color = Tk.L.fg, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            TextAction(tr("common.close"), enabled = !state.busy, onClick = onClose)
        }
        Hairline(color = Tk.L.rule)
        val local = state.local
        if (local != null) {
            FilePreview(local, PreviewKind.of(file.extension), Modifier.weight(1f).fillMaxWidth())
            return@Column
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(Tk.Sp.gutter),
            verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4),
        ) {
            Text(file.path, style = Fonts.small(), color = Tk.L.fgMuted)
            if (!WorkspaceLogic.supportsPreview(file)) Text(tr("workspace.unsupportedPreview"), style = Fonts.body(), color = Tk.L.fg)
            if (state.busy) {
                LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.rule)
                Text(tr(if (cloud) "workspace.cloudDownload" else "workspace.downloading"), style = Fonts.small(), color = Tk.L.fgMuted)
            }
            state.error?.let { Text(it, style = Fonts.small(), color = Tk.S.failed) }
            when {
                state.canConfirm -> {
                    Text(state.quote.orEmpty(), style = Fonts.body(), color = Tk.L.fg)
                    PrimaryButton(tr(if (cloud) "workspace.cloudOpen" else "workspace.download"), onClick = onConfirm)
                }
                state.canRetrySame -> {
                    Text(tr("workspace.downloadRetryHint"), style = Fonts.small(), color = Tk.L.fgMuted)
                    PrimaryButton(tr("workspace.retryDownload"), onClick = onConfirm)
                }
                state.canRequote -> TextAction(tr("project.retry"), onClick = onRequote)
            }
        }
    }
}
