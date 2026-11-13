package com.aiworkdeck.mobile.features.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.BuildConfig
import com.aiworkdeck.mobile.Overlay
import com.aiworkdeck.mobile.R
import com.aiworkdeck.mobile.ScreenshotMode
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.RowItem
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.library.LibraryScreen
import com.aiworkdeck.mobile.features.library.ViewerScreen
import com.aiworkdeck.mobile.features.queue.QueueScreen
import com.aiworkdeck.mobile.features.queue.noRipple
import com.aiworkdeck.mobile.features.settings.SettingsScreen
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.RecordingState
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.Unauthorized
import com.aiworkdeck.mobile.services.userFacingMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

private enum class Route { Library, Queue, Settings }

/**
 * 项目工作区，镜像 iOS `WorkspaceView`：项目列表 → 项目（项目文件 / 现场记录）。
 * 浏览不改采集目标；只有点「采集」才把这个项目设为拍摄目标。
 *
 * [browse] 为 false 时只看 [initialProject] 一个项目（日程里点项目进来），返回即关闭。
 */
@Composable
fun WorkspaceScreen(model: AppModel, initialProject: RelayProject?, browse: Boolean = true,
                    onClose: () -> Unit, onOpen: (Overlay) -> Unit) {
    val context = LocalContext.current
    val current by model.selectedProject.collectAsStateWithLifecycle()
    val service = remember { runCatching { ServiceLocator.backend.projectFiles(File(context.filesDir, "project-previews")) }.getOrNull() }
    DisposableEffect(service) { onDispose { service?.close() } }
    val scope = rememberCoroutineScope()
    var projects by remember { mutableStateOf(emptyList<RelayProject>()) }
    var selected by remember { mutableStateOf(initialProject) }
    var search by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var route by remember { mutableStateOf<Route?>(null) }
    var viewer by remember { mutableStateOf<Pair<List<CaptureItem>, Int>?>(null) }
    var readingBusy by remember { mutableStateOf(false) }
    var chromeHidden by remember { mutableStateOf(false) }

    suspend fun load() {
        loading = true; error = null
        try {
            // A restored capture destination stays usable even when the catalogue no longer lists it.
            val loaded = if (ScreenshotMode.enabled) ScreenshotMode.projects else ServiceLocator.backend.myProjects()
            projects = loaded + listOfNotNull(current?.takeIf { c -> loaded.none { it.matches(c) } })
        } catch (e: CancellationException) { throw e }
        catch (_: Unauthorized) { model.signOut() }
        catch (e: Exception) {
            error = userFacingMessage(e)
            if (projects.isEmpty()) current?.let { projects = listOf(it) }
        } finally { loading = false }
    }
    if (browse) LaunchedEffect(Unit) { load() }

    fun capture(project: RelayProject) {
        // A running recording keeps its destination; the button then only returns to it.
        if (!RecordingState.isRecording) model.selectProject(project)
        onClose()
    }

    BackHandler {
        when {
            viewer != null -> viewer = null
            route != null -> route = null
            readingBusy -> Unit
            selected != null && browse -> { selected = null; chromeHidden = false }
            else -> onClose()
        }
    }

    WorkdeckTheme(dark = false) {
        Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
            val project = selected
            if (service == null) {
                Column(Modifier.padding(Tk.Sp.gutter), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
                    Text(tr("files.error.closed"), style = Fonts.body(), color = Tk.L.fg)
                    TextAction(tr("common.close"), onClick = onClose)
                }
            } else if (project == null) {
                ProjectList(projects, search, { search = it }, loading, error,
                    showsDueDiligence = BuildConfig.FLAVOR == "cn" && ServiceLocator.prefs.accountRegion == AccountRegion.cn,
                    onRefresh = { scope.launch { load() } }, onClose = onClose,
                    onSettings = { route = Route.Settings }, onSelect = { selected = it },
                    onQuickCapture = { if (!RecordingState.isRecording) model.captureWithoutProject(); onClose() },
                    onLibrary = { route = Route.Library })
            } else {
                if (!chromeHidden) Row(
                    Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.s2),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconAction(R.drawable.ic_back, tr("common.back"), enabled = !readingBusy) {
                        if (browse) selected = null else onClose()
                    }
                    Text(project.name, style = Fonts.heading(), color = Tk.L.fg, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    IconAction(R.drawable.ic_tab_capture, tr(if (RecordingState.isRecording) "workspace.resumeRecording" else "workspace.capture"),
                        enabled = !readingBusy) { capture(project) }
                    IconAction(R.drawable.ic_queue, tr("queue.title"), enabled = true) { route = Route.Queue }
                }
                ProjectContents(model, project, service, onBusyChanged = { readingBusy = it },
                    onChromeHidden = { chromeHidden = it }, onOpenViewer = { items, index -> viewer = items to index })
            }
        }
        when (route) {
            Route.Library -> LibraryScreen(model, onOpenViewer = { items, index -> viewer = items to index }, onClose = { route = null })
            Route.Queue -> QueueScreen(model, onClose = { route = null })
            Route.Settings -> SettingsScreen(model, onClose = { route = null }, onOpen = onOpen)
            null -> Unit
        }
        viewer?.let { (items, index) -> ViewerScreen(items = items, start = index, onClose = { viewer = null }) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProjectList(
    projects: List<RelayProject>, search: String, onSearch: (String) -> Unit, loading: Boolean, error: String?,
    showsDueDiligence: Boolean, onRefresh: () -> Unit, onClose: () -> Unit, onSettings: () -> Unit,
    onSelect: (RelayProject) -> Unit, onQuickCapture: () -> Unit, onLibrary: () -> Unit,
) {
    val context = LocalContext.current
    val q = search.trim()
    val matches = if (q.isEmpty()) projects else projects.filter { it.name.contains(q, ignoreCase = true) }
    // 电脑名只在项目分布在多台电脑上时才帮得上忙；内部 id 不给用户看。
    val showsDevice = projects.mapNotNull { it.deviceName?.takeIf(String::isNotEmpty) }.toSet().size > 1
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = Tk.Sp.gutter, end = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically) {
            TextAction(tr("common.close"), onClick = onClose)
            Text(tr("workspace.title"), style = Fonts.heading(), color = Tk.L.fg, maxLines = 1,
                modifier = Modifier.weight(1f).padding(horizontal = Tk.Sp.s3))
            IconAction(R.drawable.ic_account, tr("home.settings"), enabled = true, onClick = onSettings)
        }
        SearchField(search, onSearch, tr("workspace.searchProjects"), Modifier.padding(horizontal = Tk.Sp.gutter))
        PullToRefreshBox(isRefreshing = loading, onRefresh = onRefresh, modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize()) {
                if (loading && projects.isEmpty()) item(key = "loading") {
                    LinearProgressIndicator(Modifier.fillMaxWidth().padding(Tk.Sp.gutter), color = Tk.L.accent, trackColor = Tk.L.rule)
                }
                error?.let { message -> item(key = "error") {
                    Column(Modifier.padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2)) {
                        Text(message, style = Fonts.small(), color = Tk.S.failed)
                        TextAction(tr("project.retry"), onClick = onRefresh)
                    }
                } }
                if (showsDueDiligence) item(key = "dd") {
                    RowItem(onClick = {
                        // 受邀尽调在独立的浏览器页里打开，不碰本机会话与采集目标（与 iOS 同）。
                        androidx.browser.customtabs.CustomTabsIntent.Builder().setShowTitle(true).build()
                            .launchUrl(context, android.net.Uri.parse(ContractCapabilities.ddClientPortalUrl))
                    }, leading = { Icon(painterResource(R.drawable.ic_checklist), null, tint = Tk.L.accent, modifier = Modifier.size(20.dp)) }) {
                        Text(tr("dd.title"), style = Fonts.body(), color = Tk.L.accent)
                    }
                    Hairline(color = Tk.L.rule)
                }
                items(matches, key = { it.id }) { p ->
                    RowItem(onClick = { onSelect(p) },
                        trailing = { Icon(painterResource(R.drawable.ic_chevron_right), null, tint = Tk.L.fgFaint, modifier = Modifier.size(20.dp)) }) {
                        Column {
                            Text(p.name, style = Fonts.body(), color = Tk.L.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            if (showsDevice) p.deviceName?.takeIf(String::isNotEmpty)?.let {
                                Text(it, style = Fonts.micro(), color = Tk.L.fgFaint, maxLines = 1)
                            }
                        }
                    }
                    Hairline(color = Tk.L.rule)
                }
                if (!loading && error == null && projects.isEmpty()) item(key = "empty") {
                    Text(tr("project.emptyHint"), style = Fonts.small(), color = Tk.L.fgMuted, modifier = Modifier.padding(Tk.Sp.gutter))
                } else if (projects.isNotEmpty() && matches.isEmpty()) item(key = "no-match") {
                    Text(tr("project.noMatch"), style = Fonts.small(), color = Tk.L.fgMuted, modifier = Modifier.padding(Tk.Sp.gutter))
                }
            }
        }
        Hairline(color = Tk.L.rule)
        Row(Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.s2, vertical = Tk.Sp.s1), verticalAlignment = Alignment.CenterVertically) {
            LabeledAction(R.drawable.ic_mic, tr("workspace.quickCapture"), onQuickCapture)
            Box(Modifier.weight(1f))
            LabeledAction(R.drawable.ic_photo, tr("library.open"), onLibrary)
        }
    }
}

@Composable
internal fun SearchField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    OutlinedTextField(
        value = value, onValueChange = onChange, singleLine = true,
        placeholder = { Text(placeholder) },
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { focus.clearFocus() }),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Tk.L.accent, unfocusedBorderColor = Tk.L.rule, cursorColor = Tk.L.accent),
        modifier = modifier.fillMaxWidth().padding(bottom = Tk.Sp.s2),
    )
}

@Composable
internal fun IconAction(icon: Int, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(Tk.touchMin).clip(CircleShape).clickable(enabled = enabled, role = Role.Button, onClickLabel = label, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Icon(painterResource(icon), contentDescription = null, tint = if (enabled) Tk.L.accent else Tk.L.fgFaint, modifier = Modifier.size(22.dp)) }
}

@Composable
private fun LabeledAction(icon: Int, label: String, onClick: () -> Unit) {
    Row(
        Modifier.heightIn(min = Tk.touchMin).clip(CircleShape).clickable(role = Role.Button, onClick = onClick).padding(horizontal = Tk.Sp.s2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = Tk.L.accent, modifier = Modifier.size(20.dp))
        Text(label, style = Fonts.small(), color = Tk.L.accent)
    }
}

/** 次级动作：一段可点的强调色文字（与选项目页同一做法）。 */
@Composable
internal fun TextAction(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, color: Color = Tk.L.accent, onClick: () -> Unit) {
    Box(modifier.heightIn(min = Tk.touchMin).then(if (enabled) Modifier.noRipple(onClick) else Modifier), contentAlignment = Alignment.CenterStart) {
        Text(text, style = Fonts.small(), color = if (enabled) color else Tk.L.fgFaint)
    }
}
