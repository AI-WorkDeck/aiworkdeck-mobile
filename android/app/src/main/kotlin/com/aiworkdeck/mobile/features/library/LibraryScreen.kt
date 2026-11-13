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
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import com.aiworkdeck.mobile.R
import com.aiworkdeck.mobile.services.userFacingMessage
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
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import com.aiworkdeck.mobile.model.ProjectChoice
import com.aiworkdeck.mobile.model.RelayProject
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
    /** 项目工作区「现场记录」页：只看这个项目，不能切换。 */
    fixedProject: RelayProject? = null,
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
    var movingId by rememberSaveable { mutableStateOf<String?>(null) }
    var moveError by remember { mutableStateOf<String?>(null) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    var barHeight by remember { mutableStateOf(0.dp) }

    val projects = fixedProject?.let { listOf(ProjectChoice(it.id, it.name)) } ?: LibraryGrouping.projectsIn(all, current)
    // 正在看的项目：优先用手动切过的那个；它若已经没有记录了（比如刚被删空）就退回第一项
    val viewing = projects.firstOrNull { it.id == viewingId } ?: projects.firstOrNull()
    val items = LibraryGrouping.itemsIn(all, viewing?.id, fixedProject ?: current).filter { !audioOnly || it.kind == MediaKind.audio }
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
                    Text(tr("library.emptyHint"), style = Fonts.micro(), color = Tk.D.fgMuted)
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
                                onMove = { movingId = item.id },
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
                                onMove = { movingId = item.id },
                                onAssign = { assigning = setOf(item.id) },
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
                    TopBar(
                        viewingName = viewing?.name.orEmpty(),
                        projects = projects.map { it.id to it.name },
                        tally = TransferTally.of(items),
                        columns = columns,
                        isGrid = isGrid,
                        selecting = selecting,
                        canSelect = items.isNotEmpty(),
                        onPick = { id -> if (fixedProject != null) return@TopBar; viewingId = id; prefs.libraryViewingProject = id; selected = emptySet() },
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
                        embedded = fixedProject != null,
                    )
                    FilterSegments(
                        audioOnly, onChange = { audioOnly = it; selected = emptySet() },
                        modifier = Modifier.padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
                    )
                    Hairline(color = Tk.D.rule)
                }
            }

            if (selecting) {
                DeleteDock(
                    count = selected.size,
                    modifier = Modifier.align(Alignment.BottomCenter),
                    // 移动中的件不能删：先说清楚，不弹一个注定失败的确认框
                    onDelete = { if (selectedItems.any { it.moveBlocksMutation }) deleteError = tr("queue.moveInProgress") else confirming = true },
                )
            }
        }

        assigning?.let { ids ->
            ProjectPickerScreen(model, onClose = { assigning = null }, markCurrent = false, onNone = { assigning = null }, onSelect = { target ->
                scope.launch {
                    try { model.assignCaptures(ids, target); assigning = null }
                    catch (e: kotlinx.coroutines.CancellationException) { throw e }
                    catch (_: Exception) { assignError = true }
                }
            })
        }
        all.firstOrNull { it.id == movingId }?.let { item ->
            BackHandler { movingId = null }
            ProjectPickerScreen(
                model, onClose = { movingId = null }, markCurrent = false, onNone = { movingId = null },
                titleKey = "library.move", hintKey = if (item.canMoveToProject) "library.moveHint" else "queue.moveHint",
                onSelect = { target ->
                    scope.launch {
                        try {
                            model.move(item, target)
                            movingId = null
                            selected = emptySet(); selecting = false
                            if (fixedProject == null) { viewingId = target.id; prefs.libraryViewingProject = target.id }
                        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                        catch (e: Exception) { movingId = null; moveError = userFacingMessage(e) }
                    }
                },
            )
        }
        (moveError ?: deleteError)?.let { message ->
            AlertDialog(
                onDismissRequest = { moveError = null; deleteError = null },
                title = if (deleteError != null) { { Text(tr("library.delete")) } } else null,
                text = { Text(message) },
                confirmButton = { TextButton(onClick = { moveError = null; deleteError = null }) { Text(tr("common.ok")) } },
            )
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
                        model.delete(selected) { deleteError = tr("queue.moveInProgress") }
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
    // 嵌在项目工作区「现场记录」里：项目已定，不给关闭和切项目
    embedded: Boolean = false,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Column {
        Row(
            Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.s3, bottom = Tk.Sp.s2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
        ) {
            if (!embedded) ToolIcon(R.drawable.ic_chevron_left, tr("common.back"), onClose)

            // 项目名就是切换入口。只切看的对象，不动拍摄目标。
            Box(Modifier.weight(1f)) {
                Row(
                    Modifier.heightIn(min = Tk.touchMin).clickable(enabled = !embedded) { menuOpen = true }
                        .semantics(mergeDescendants = true) {
                            contentDescription = if (embedded) viewingName else tr("library.viewing.a11y", mapOf("name" to viewingName))
                            if (!embedded) role = Role.Button
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        viewingName, style = Fonts.heading(), color = Tk.D.fg,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false).clearAndSetSemantics {},
                    )
                    if (!embedded) Icon(painterResource(R.drawable.ic_expand), contentDescription = null, tint = Tk.D.fgMuted, modifier = Modifier.size(16.dp))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    for ((id, name) in projects) {
                        val current = name == viewingName
                        DropdownMenuItem(
                            text = { Text(name, style = Fonts.body()) },
                            trailingIcon = if (current) {
                                { Icon(painterResource(R.drawable.ic_check), contentDescription = null, modifier = Modifier.size(18.dp)) }
                            } else null,
                            modifier = Modifier.semantics { selected = current },
                            onClick = { onPick(id); menuOpen = false },
                        )
                    }
                }
            }

            // 列数只在网格下有意义；列表下只留视图切换。图标按钮，读屏念契约里的 a11y 文案
            if (!selecting && isGrid) {
                ToolIcon(
                    if (columns == 2) R.drawable.ic_grid_view else R.drawable.ic_grid_on,
                    tr("library.columns.a11y", mapOf("n" to columns)), onColumns,
                )
            }
            if (!selecting) {
                // 图标画的是**切过去**的那一档：这个是二选一的开关
                ToolIcon(
                    if (isGrid) R.drawable.ic_list else R.drawable.ic_grid_view,
                    if (isGrid) tr("library.toList.a11y") else tr("library.toGrid.a11y"), onToggleView,
                )
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
        TallyRow(tally, onDark = true, modifier = Modifier.padding(start = Tk.Sp.gutter, bottom = Tk.Sp.s2), hideZero = true)
        Hairline(color = Tk.D.rule)
    }
}

@Composable
private fun ToolIcon(icon: Int, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(Tk.touchMin).clickable(onClick = onClick).semantics { contentDescription = label; role = Role.Button },
        contentAlignment = Alignment.Center,
    ) { Icon(painterResource(icon), contentDescription = null, tint = Tk.D.fg, modifier = Modifier.size(20.dp)) }
}

/** 全部 / 录音 两档（iOS 的分段选择器）。选中档垫一块 surface，读屏念「已选中」。 */
@Composable
private fun FilterSegments(audioOnly: Boolean, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(Tk.D.bg)
            .border(1.dp, Tk.D.rule, RoundedCornerShape(4.dp)),
    ) {
        for ((value, label) in listOf(false to tr("library.all"), true to tr("library.audio"))) {
            val on = value == audioOnly
            Box(
                Modifier.weight(1f).heightIn(min = 32.dp).background(if (on) Tk.D.surface else Color.Transparent)
                    .clickable { onChange(value) }.semantics { selected = on; role = Role.Tab },
                contentAlignment = Alignment.Center,
            ) { Text(label, style = Fonts.small(), color = if (on) Tk.D.fg else Tk.D.fgMuted) }
        }
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
private fun Cell(item: CaptureItem, selecting: Boolean, checked: Boolean, onMove: () -> Unit, onTap: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    Box(
        Modifier.aspectRatio(1f).background(Tk.D.surface)
            .combinedClickable(onClick = onTap, onLongClick = { if (!selecting && canMove(item)) menuOpen = true })
            .clearAndSetSemantics {
                contentDescription = cellLabel(item); role = Role.Button
                if (selecting) selected = checked
            },
    ) {
        MoveMenu(menuOpen, onDismiss = { menuOpen = false }, onMove = { menuOpen = false; onMove() })
        EvidenceThumb(item, onDark = true, modifier = Modifier.fillMaxSize(), iconSize = 28.dp)
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
private fun ListRow(item: CaptureItem, selecting: Boolean, checked: Boolean, onMove: () -> Unit, onAssign: () -> Unit, onTap: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    MoveMenu(menuOpen, onDismiss = { menuOpen = false }, onMove = { menuOpen = false; onMove() })
    RowItem(
        modifier = Modifier.combinedClickable(onClick = onTap, onLongClick = { if (!selecting && canMove(item)) menuOpen = true })
            .semantics { if (selecting) selected = checked },
        leading = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
            ) {
                if (selecting) SelectionTick(checked)
                EvidenceThumb(item, onDark = true, modifier = Modifier.size(72.dp))
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
            if (item.state == TransferState.failed) item.lastError?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = Fonts.nano(), color = Tk.S.failed)
            }
            if (item.project == null && item.state == TransferState.waiting) TextButton(onClick = onAssign) { Text(tr("library.assign")) }
        }
    }
}

/** 只在真能移动时给（规则同队列页：未上传的直接改目标，已发出的走远端移动）。 */
private fun canMove(item: CaptureItem) = item.canMoveToProject || item.canRequestArchiveMove

/** 读屏标签：类型、时刻、状态（同 iOS 的 accessibilityLabel 顺序）。 */
private fun cellLabel(item: CaptureItem) = listOf(kindLabel(item.kind), LibraryTime.clock(item.capturedAt), item.state.caption).joinToString(", ")

@Composable
private fun MoveMenu(expanded: Boolean, onDismiss: () -> Unit, onMove: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(tr("library.move"), style = Fonts.body()) },
            leadingIcon = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null) },
            onClick = onMove,
        )
    }
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
