package com.aiworkdeck.mobile.features.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import com.aiworkdeck.mobile.features.auth.ProjectPickerScreen
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.GlassBar
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.RowItem
import com.aiworkdeck.mobile.design.StatusDot
import com.aiworkdeck.mobile.design.TallyRow
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.DaySection
import com.aiworkdeck.mobile.model.LibraryGrouping
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.model.TransferTally
import com.aiworkdeck.mobile.services.ServiceLocator

/**
 * 图集 —— 方向 B「影像优先」：深色、影像铺满、玻璃条压在影像上。镜像 iOS `LibraryView`。
 *
 * 只看一个项目：默认当前项目，顶栏可切换**看**的对象（不改拍摄目标——已拍的件各自记着自己的
 * 项目，切这里不会把它们搬走）。项目内按自然日分段。列数、网格/列表、多选删除都在这一页。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(
    model: AppModel,
    onOpenViewer: (List<CaptureItem>, Int) -> Unit,
    onClose: () -> Unit,
) {
    val all by model.items.collectAsStateWithLifecycle()
    val current by model.selectedProject.collectAsStateWithLifecycle()
    val otherPending by model.otherPendingCount.collectAsStateWithLifecycle()

    // 「怎么看」落在 Prefs 里而不是只 rememberSaveable：后者跨不过进程被杀（见 Prefs.libraryColumns）
    val prefs = ServiceLocator.prefs
    var viewingId by rememberSaveable { mutableStateOf(prefs.libraryViewingProject) }
    var columns by rememberSaveable { mutableIntStateOf(prefs.libraryColumns) }
    var viewMode by rememberSaveable { mutableStateOf(prefs.libraryViewMode) }
    var audioOnly by rememberSaveable { mutableStateOf(false) }
    var selecting by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var confirming by remember { mutableStateOf(false) }
    var assigning by remember { mutableStateOf<Set<String>?>(null) }
    var assignError by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var barHeight by remember { mutableStateOf(0.dp) }

    val projects = LibraryGrouping.projectsIn(all, current)
    // 正在看的项目：优先用手动切过的那个；它若已经没有记录了（比如刚被删空）就退回第一项
    val viewing = projects.firstOrNull { it.id == viewingId } ?: projects.firstOrNull()
    val items = LibraryGrouping.itemsIn(all, viewing?.id, current).filter { !audioOnly || it.kind == MediaKind.audio }
    val days = LibraryGrouping.groupByDay(items)
    val selectedItems = items.filter { selected.contains(it.id) }
    val isGrid = viewMode == VIEW_GRID
    val density = LocalDensity.current

    WorkdeckTheme(dark = true) {
        Box(Modifier.fillMaxSize().background(Tk.D.bg).safeDrawingPadding()) {
            if (items.isEmpty()) {
                Column(
                    Modifier.fillMaxSize().padding(horizontal = Tk.Sp.gutter)
                        .padding(top = barHeight + Tk.Sp.s10),
                    verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
                ) {
                    Text(tr("library.empty"), style = Fonts.body(), color = Tk.D.fg)
                    if (otherPending > 0) OtherPending(otherPending)
                }
            } else if (isGrid) {
                // 顶栏的高度用 padding 让开而不是 contentPadding：粘性段头钉的是**视口**上沿，
                // 用 contentPadding 的话段头会钉到顶栏底下去，看不见。
                LazyVerticalGrid(
                    columns = GridCells.Fixed(columns),
                    modifier = Modifier.fillMaxSize().padding(top = barHeight),
                    contentPadding = PaddingValues(
                        bottom = if (selecting) Tk.Sp.s16 + Tk.touchMin else Tk.Sp.s8,
                    ),
                    verticalArrangement = Arrangement.spacedBy(1.5.dp),
                    horizontalArrangement = Arrangement.spacedBy(1.5.dp),
                ) {
                    for (day in days) {
                        stickyHeader(key = "h-${day.day}") { DayHeader(day) }
                        items(day.items, key = { it.id }) { item ->
                            Cell(
                                item = item,
                                selecting = selecting,
                                checked = selected.contains(item.id),
                                onAssign = { if (item.project == null && item.state == TransferState.waiting) assigning = setOf(item.id) },
                                onTap = {
                                    if (selecting) {
                                        selected = if (selected.contains(item.id)) selected - item.id else selected + item.id
                                    } else {
                                        onOpenViewer(day.items, day.items.indexOfFirst { it.id == item.id })
                                    }
                                },
                            )
                        }
                    }
                    if (otherPending > 0) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            Box(Modifier.padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s4)) {
                                OtherPending(otherPending)
                            }
                        }
                    }
                }
            } else {
                // 列表：同样的分段与段头，一行一件——格子看画面，列表看核对信息
                LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(top = barHeight),
                    contentPadding = PaddingValues(
                        bottom = if (selecting) Tk.Sp.s16 + Tk.touchMin else Tk.Sp.s8,
                    ),
                ) {
                    for (day in days) {
                        stickyHeader(key = "h-${day.day}") { DayHeader(day) }
                        items(day.items, key = { it.id }) { item ->
                            ListRow(
                                item = item,
                                selecting = selecting,
                                checked = selected.contains(item.id),
                                onAssign = { if (item.project == null && item.state == TransferState.waiting) assigning = setOf(item.id) },
                                onTap = {
                                    if (selecting) {
                                        selected = if (selected.contains(item.id)) selected - item.id else selected + item.id
                                    } else {
                                        onOpenViewer(day.items, day.items.indexOfFirst { it.id == item.id })
                                    }
                                },
                            )
                            Hairline(color = Tk.D.rule)
                        }
                    }
                    if (otherPending > 0) {
                        item {
                            Box(Modifier.padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s4)) {
                                OtherPending(otherPending)
                            }
                        }
                    }
                }
            }

            GlassBar(Modifier.align(Alignment.TopCenter).fillMaxWidth().onSizeChanged {
                barHeight = with(density) { it.height.toDp() }
            }) {
                Column {
                    Row {
                        TextButton(onClick = { audioOnly = false; selected = emptySet() }) {
                            Text(tr("library.all"), color = if (!audioOnly) Color.White else Tk.D.fgMuted)
                        }
                        TextButton(onClick = { audioOnly = true; selected = emptySet() }) {
                            Text(tr("library.audio"), color = if (audioOnly) Color.White else Tk.D.fgMuted)
                        }
                    }
                    TopBar(
                        viewingName = viewing?.name.orEmpty(),
                        projects = projects.map { it.id to it.name },
                        tally = TransferTally.of(items),
                        columns = columns,
                        isGrid = isGrid,
                        selecting = selecting,
                        canSelect = items.isNotEmpty(),
                        onPick = { id -> viewingId = id; prefs.libraryViewingProject = id; selected = emptySet() },
                        onColumns = {
                            columns = if (columns >= 4) 2 else columns + 1
                            prefs.libraryColumns = columns
                        },
                        onToggleView = {
                            viewMode = if (isGrid) VIEW_LIST else VIEW_GRID
                            prefs.libraryViewMode = viewMode
                        },
                        onToggleSelect = { selecting = !selecting; selected = emptySet() },
                        onClose = onClose,
                    )
                }
            }

            if (selecting) {
                DeleteDock(
                    count = selected.size,
                    modifier = Modifier.align(Alignment.BottomCenter),
                    onDelete = { confirming = true },
                )
            }
        }

        assigning?.let { ids ->
            ProjectPickerScreen(model, onClose = { assigning = null }, onSelect = { target ->
                scope.launch {
                    try { model.assignCaptures(ids, target); assigning = null }
                    catch (e: kotlinx.coroutines.CancellationException) { throw e }
                    catch (_: Exception) { assignError = true }
                }
            })
        }
        if (assignError) AlertDialog(onDismissRequest = { assignError = false },
            text = { Text(tr("library.assignFailed")) }, confirmButton = { TextButton(onClick = { assignError = false }) { Text(tr("common.close")) } })
        if (confirming) {
            AlertDialog(
                onDismissRequest = { confirming = false },
                title = { Text(tr("delete.title", mapOf("n" to selected.size))) },
                text = { Text(LibraryGrouping.deleteWarning(selectedItems)) },
                confirmButton = {
                    TextButton(onClick = {
                        model.delete(selected)
                        selected = emptySet()
                        selecting = false
                        confirming = false
                    }) { Text(tr("library.delete"), color = Tk.S.failed) }
                },
                dismissButton = {
                    TextButton(onClick = { confirming = false }) { Text(tr("common.cancel")) }
                },
            )
        }
    }
}

// MARK: - 顶栏

@Composable
private fun TopBar(
    viewingName: String,
    projects: List<Pair<String, String>>,
    tally: TransferTally,
    columns: Int,
    isGrid: Boolean,
    selecting: Boolean,
    canSelect: Boolean,
    onPick: (String) -> Unit,
    onColumns: () -> Unit,
    onToggleView: () -> Unit,
    onToggleSelect: () -> Unit,
    onClose: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Column {
        Row(
            Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.s3, bottom = Tk.Sp.s2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
        ) {
            Box(
                Modifier.size(Tk.touchMin).clickable(onClick = onClose)
                    .semantics { contentDescription = tr("common.close") },
                contentAlignment = Alignment.Center,
            ) { Text("✕", style = Fonts.body(), color = Tk.D.fg) }

            Box(Modifier.weight(1f)) {
                Row(
                    Modifier.heightIn(min = 28.dp).clickable { menuOpen = true },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        viewingName, style = Fonts.heading(), color = Tk.D.fg,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Text("▾", style = Fonts.small(), color = Tk.D.fgMuted)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    for ((id, name) in projects) {
                        DropdownMenuItem(
                            text = { Text(name, style = Fonts.body()) },
                            onClick = { onPick(id); menuOpen = false },
                        )
                    }
                }
            }

            // 列数只在网格下有意义；列表下只留视图切换
            if (!selecting && isGrid) {
                Box(
                    Modifier.heightIn(min = Tk.touchMin).clickable(onClick = onColumns)
                        .padding(horizontal = Tk.Sp.s1).wrapContentHeight(),
                ) {
                    Text(tr("library.columns", mapOf("n" to columns)), style = Fonts.mono(Tk.Ty.small), color = Tk.D.fg)
                }
            }
            if (!selecting) {
                // 按钮写的是**切过去**的那一档，和列数按钮写当前档不同：这个是二选一的开关
                Box(
                    Modifier.heightIn(min = Tk.touchMin).clickable(onClick = onToggleView)
                        .padding(horizontal = Tk.Sp.s1).wrapContentHeight(),
                ) {
                    Text(
                        if (isGrid) tr("library.viewList") else tr("library.viewGrid"),
                        style = Fonts.small(), color = Tk.D.fg,
                    )
                }
            }
            Box(
                Modifier.heightIn(min = Tk.touchMin).clickable(enabled = canSelect, onClick = onToggleSelect)
                    .padding(horizontal = Tk.Sp.s1).wrapContentHeight(),
            ) {
                Text(
                    if (selecting) tr("common.cancel") else tr("library.select"),
                    style = Fonts.small(),
                    color = if (canSelect) Tk.D.fg else Tk.D.fgMuted,
                )
            }
        }
        // 计数单独一行：它会因为「含 N 失败」后缀变长，和右侧工具挤在一行会把顶栏撑成三行
        TallyRow(tally, onDark = true, modifier = Modifier.padding(start = Tk.Sp.gutter, bottom = Tk.Sp.s2))
        Hairline(color = Tk.D.rule)
    }
}

// MARK: - 段头与格子

@Composable
private fun DayHeader(day: DaySection) {
    Box(
        Modifier.fillMaxWidth().background(Tk.D.bg)
            .padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
    ) {
        Text(day.title.uppercase(), style = Fonts.nano(), color = Color.White.copy(alpha = 0.6f))
    }
}

/**
 * 一格。缩略图 + 状态点 + 时刻；上传中的把进度直接画在图底边——单开一栏进度条会把注意力
 * 从影像上拉走。录音没有画面，用音符占位。
 */
@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun Cell(item: CaptureItem, selecting: Boolean, checked: Boolean, onAssign: () -> Unit, onTap: () -> Unit) {
    Box(
        Modifier.aspectRatio(1f).background(Tk.D.surface).combinedClickable(onClick = onTap, onLongClick = onAssign)
            .semantics { contentDescription = "${item.state.caption} ${LibraryTime.clock(item.capturedAt)}" },
    ) {
        Thumb(item, Modifier.fillMaxSize())
        StatusDot(item.state, onDark = true, modifier = Modifier.align(Alignment.TopEnd).padding(6.dp))
        Text(
            LibraryTime.clock(item.capturedAt), style = Fonts.mono(Tk.Ty.nano),
            color = Color.White.copy(alpha = 0.55f),
            modifier = Modifier.align(Alignment.BottomStart).padding(6.dp),
        )
        if (item.state == TransferState.uploading) {
            Box(
                Modifier.align(Alignment.BottomStart).fillMaxWidth(item.progress.toFloat().coerceIn(0f, 1f))
                    .height(2.dp).background(Tk.S.movingOnDark),
            )
        }
        if (selecting) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = if (checked) 0.35f else 0f))) {
                SelectionTick(checked, Modifier.align(Alignment.TopStart).padding(6.dp))
            }
        }
    }
}

/** 缩略图。录像由全局 ImageLoader 的 `VideoFrameDecoder` 取首帧；录音没有画面，用音符占位。 */
@Composable
private fun Thumb(item: CaptureItem, modifier: Modifier = Modifier) {
    Box(modifier.background(Tk.D.surface), contentAlignment = Alignment.Center) {
        if (item.kind == MediaKind.audio) {
            Text("♪", style = Fonts.heading(), color = Color.White.copy(alpha = 0.5f))
        } else {
            AsyncImage(
                model = item.localFile,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
private fun SelectionTick(checked: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier.size(18.dp).clip(CircleShape)
            .background(if (checked) Tk.S.movingOnDark else Color.Transparent)
            .border(1.5.dp, if (checked) Tk.S.movingOnDark else Color.White.copy(alpha = 0.8f), CircleShape),
    )
}

/**
 * 列表一行。格子上时刻只到分，这里到秒：切到列表就是为了核对，取证核对的是那一下。
 */
@Composable
private fun ListRow(item: CaptureItem, selecting: Boolean, checked: Boolean, onAssign: () -> Unit, onTap: () -> Unit) {
    RowItem(
        onClick = onTap,
        leading = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
            ) {
                if (selecting) SelectionTick(checked)
                Thumb(item, Modifier.size(72.dp))
            }
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
            ) {
                StatusDot(item.state, onDark = true)
                Text(item.state.caption, style = Fonts.small(), color = Tk.D.fg)
                Text(
                    LibraryTime.precise(item.capturedAt), style = Fonts.mono(Tk.Ty.small),
                    color = Tk.D.fgMuted,
                )
            }
            Text(kindLabel(item.kind), style = Fonts.nano(), color = Tk.D.fgMuted)
            if (item.project == null && item.state == TransferState.waiting) TextButton(onClick = onAssign) { Text(tr("library.assign")) }
        }
    }
}

private fun kindLabel(kind: MediaKind): String = when (kind) {
    MediaKind.photo -> tr("home.mode.photo")
    MediaKind.video -> tr("home.mode.video")
    MediaKind.audio -> tr("home.mode.audio")
}

// MARK: - 底座与末尾提示

/** 别的项目里还没落盘的件不能完全藏起来——「没显示」和「没有」是两回事。 */
@Composable
private fun OtherPending(n: Int) {
    Text(tr("library.otherPending", mapOf("n" to n)), style = Fonts.micro(), color = Tk.D.fgMuted)
}

@Composable
private fun DeleteDock(count: Int, modifier: Modifier = Modifier, onDelete: () -> Unit) {
    GlassBar(modifier.fillMaxWidth().wrapContentHeight()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            // 一件都没选时按钮是灰的：这行字说清楚为什么灰，别让人以为坏了
            Text(
                if (count == 0) tr("library.selectHint") else tr("library.selectedCount", mapOf("n" to count)),
                style = Fonts.small(), color = Tk.D.fgMuted,
            )
            Box(
                Modifier.heightIn(min = Tk.touchMin)
                    .background(if (count > 0) Tk.S.failed else Tk.S.failed.copy(alpha = 0.4f))
                    .clickable(enabled = count > 0, onClick = onDelete)
                    .padding(horizontal = Tk.Sp.s4),
                contentAlignment = Alignment.Center,
            ) {
                Text(tr("delete.title", mapOf("n" to count)), style = Fonts.small(), color = Color.White)
            }
        }
    }
}

private const val VIEW_GRID = "grid"
private const val VIEW_LIST = "list"
