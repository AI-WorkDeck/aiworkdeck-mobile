package com.aiworkdeck.mobile.features.queue

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.R
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.PrimaryButton
import com.aiworkdeck.mobile.design.StatusDot
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.auth.Eyebrow
import com.aiworkdeck.mobile.features.auth.ProjectPickerScreen
import com.aiworkdeck.mobile.features.library.EvidenceThumb
import com.aiworkdeck.mobile.features.library.LibraryTime
import com.aiworkdeck.mobile.model.ArchiveMoveStatus
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.IsoTime
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.services.CaptureOrganization
import com.aiworkdeck.mobile.services.userFacingMessage
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * 上传队列。存在的理由只有一个：**出事的时候能看懂、能自救。**
 * 只给一个红点，用户既不知道该重试还是该找人，也不知道是自己网络的问题还是我们的问题。
 *
 * 汇总全部项目和未归类资料；切换采集目标不改变这里的范围。点一行看详情（缩略图、状态、
 * 项目、时刻、进度、整理结果、到期日、文件指纹），长按或在详情里移动 / 复制到别的项目。
 * 镜像 iOS `QueueView`；宽屏横放时列表与详情并排。
 */
@Composable
fun QueueScreen(model: AppModel, onClose: () -> Unit) {
    val all by model.items.collectAsStateWithLifecycle()
    val expiry by model.cloudExpiry.collectAsStateWithLifecycle()
    val progress by model.uploadProgress.collectAsStateWithLifecycle()
    val organizations by model.organizations.collectAsStateWithLifecycle()

    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    // 正在为哪件选目标项目：id 与「复制还是移动」
    var actionId by rememberSaveable { mutableStateOf<String?>(null) }
    var actionCopy by rememberSaveable { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // 开着队列页时每 20 秒问一次投递回执——「已暂存」翻成「已落盘」的那一下应该发生在
    // 用户眼前，而不是下次冷启动。
    LaunchedEffect(Unit) {
        while (isActive) {
            model.checkDelivered()
            delay(20_000)
        }
    }

    val sections = QueueSections.of(all)
    val selected = all.firstOrNull { it.id == selectedId }
    val actionItem = all.firstOrNull { it.id == actionId }
    fun startAction(item: CaptureItem, copy: Boolean) { actionId = item.id; actionCopy = copy }
    val retry: (CaptureItem) -> Unit = { item -> model.retry(item.id) { error = it } }

    LightStatusBar()
    WorkdeckTheme(dark = false) {
        BoxWithConstraints(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
            val wide = maxWidth >= 700.dp && maxWidth > maxHeight
            val list: @Composable (Modifier) -> Unit = { modifier ->
                Column(modifier) {
                    TopBar(
                        canRetryAll = sections.failed.any { it.archiveMove == null },
                        onRetryAll = { model.retryFailedUploads() },
                        onClose = onClose,
                    )
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
                    ) {
                        val rows = RowCallbacks(
                            selectedId = selectedId, expiry = expiry, progress = progress,
                            onSelect = { selectedId = it.id }, onRetry = retry, onAction = ::startAction,
                        )
                        section(tr("queue.section.failed"), sections.failed, Tk.S.failed, rows)
                        section(tr("library.unknownProject"), sections.unassigned, Tk.L.fgMuted, rows)
                        section(tr("queue.section.uploading"), sections.active, Tk.S.waiting, rows)
                        section(tr("queue.section.staged"), sections.staged, Tk.S.moving, rows)
                        section(tr("queue.section.landed"), sections.landed, Tk.S.arrived, rows)
                        if (all.isEmpty()) item(key = "empty") { Empty() }
                    }
                }
            }
            val detail: @Composable (Modifier, Boolean) -> Unit = { modifier, showBack ->
                Column(modifier) {
                    DetailBar(showBack = showBack, onBack = { selectedId = null })
                    if (selected != null) {
                        Details(
                            item = selected,
                            progress = progress[selected.id] ?: selected.progress,
                            organization = organizations[selected.id],
                            expiresAt = expiry[selected.effectiveClientMediaId.lowercase()],
                            currentBinding = model.archiveMoveBinding(),
                            onRetry = { retry(selected) },
                            onAction = { copy -> startAction(selected, copy) },
                        )
                    } else {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text(tr("queue.chooseItem"), style = Fonts.body(), color = Tk.L.fgMuted)
                        }
                    }
                }
            }

            if (wide) {
                Row(Modifier.fillMaxSize()) {
                    list(Modifier.width(340.dp).fillMaxHeight())
                    Box(Modifier.width(1.dp).fillMaxHeight().background(Tk.L.rule))
                    detail(Modifier.weight(1f).fillMaxHeight(), false)
                }
            } else if (selected != null) {
                detail(Modifier.fillMaxSize(), true)
            } else {
                list(Modifier.fillMaxSize())
            }

            // 竖屏下详情是一层：返回键先回列表，不直接关掉队列
            BackHandler(enabled = !wide && selected != null && actionItem == null) { selectedId = null }
        }

        actionItem?.let { item ->
            BackHandler { actionId = null }
            ProjectPickerScreen(
                model, onClose = { actionId = null }, markCurrent = false, onNone = { actionId = null },
                titleKey = if (actionCopy) "queue.copy" else "library.move",
                hintKey = if (actionCopy) "queue.copyHint" else if (item.canMoveToProject) "library.moveHint" else "queue.moveHint",
                onSelect = { target ->
                    val copy = actionCopy
                    scope.launch {
                        try {
                            if (copy) selectedId = model.copy(item, target).id else model.move(item, target)
                            actionId = null
                        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                        catch (e: Exception) { actionId = null; error = userFacingMessage(e) }
                    }
                },
            )
        }
        error?.let { message ->
            AlertDialog(
                onDismissRequest = { error = null },
                text = { Text(message) },
                confirmButton = { TextButton(onClick = { error = null }) { Text(tr("common.ok")) } },
            )
        }
    }
}

private class RowCallbacks(
    val selectedId: String?,
    val expiry: Map<String, String>,
    val progress: Map<String, Double>,
    val onSelect: (CaptureItem) -> Unit,
    val onRetry: (CaptureItem) -> Unit,
    val onAction: (CaptureItem, Boolean) -> Unit,
)

/** 一段。空段不占位——五段全画会让「失败」段在最需要被看见的时候排在一堆空标题里。 */
private fun LazyListScope.section(title: String, items: List<CaptureItem>, tint: Color, rows: RowCallbacks) {
    if (items.isEmpty()) return
    item(key = "h-$title") {
        Row(
            Modifier.fillMaxWidth().padding(top = Tk.Sp.s6, bottom = Tk.Sp.s2),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Eyebrow(title, Modifier.weight(1f))
            Text(items.size.toString(), style = Fonts.mono(Tk.Ty.small), color = tint)
        }
    }
    items(items, key = { it.id }) { item ->
        QueueRow(
            item = item,
            selected = rows.selectedId == item.id,
            progress = rows.progress[item.id] ?: item.progress,
            expiresAt = rows.expiry[item.effectiveClientMediaId.lowercase()],
            onSelect = { rows.onSelect(item) },
            onRetry = { rows.onRetry(item) },
            onAction = { copy -> rows.onAction(item, copy) },
        )
        Hairline(color = Tk.L.rule)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun QueueRow(
    item: CaptureItem, selected: Boolean, progress: Double, expiresAt: String?,
    onSelect: () -> Unit, onRetry: () -> Unit, onAction: (Boolean) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().background(if (selected) Tk.L.accent.copy(alpha = 0.08f) else Color.Transparent),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
    ) {
        Box(Modifier.weight(1f)) {
            Row(
                Modifier.fillMaxWidth()
                    .combinedClickable(onClick = onSelect, onLongClick = { menuOpen = true })
                    .semantics { this.selected = selected }
                    .padding(vertical = Tk.Sp.s3),
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
            ) {
                EvidenceThumb(item, onDark = false, modifier = Modifier.size(44.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
                    ) {
                        StatusDot(item.queueState, onDark = false)
                        Text(item.queueCaption, style = Fonts.small(), color = Tk.L.fg)
                        Text(LibraryTime.clock(item.capturedAt), style = Fonts.mono(Tk.Ty.small), color = Tk.L.fgFaint)
                    }
                    Text(
                        item.project?.name ?: tr("library.unknownProject"), style = Fonts.nano(), color = Tk.L.fgMuted,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    if (item.state == TransferState.uploading) ProgressLine(progress)
                    // 失败原因照实显示。区分「你的网络」与「我们这边」，用户才知道是该换个地方
                    // 重试还是该找人。
                    item.queueError?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = Fonts.nano(), color = Tk.S.failed)
                    }
                    // 中转区不是网盘：到期未被桌面端取走就会被清理。只在还剩不到 3 天时说话。
                    if (item.state == TransferState.uploaded && expiresSoon(expiresAt, Instant.now())) {
                        expiryDate(expiresAt)?.let {
                            Text(tr("queue.expiresOn", mapOf("date" to it)), style = Fonts.nano(), color = Tk.S.waiting)
                        }
                    }
                }
                Icon(
                    painterResource(R.drawable.ic_chevron_right), contentDescription = null, tint = Tk.L.fgFaint,
                    modifier = Modifier.size(16.dp).align(Alignment.CenterVertically),
                )
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                ProjectMenuItems(item) { copy -> menuOpen = false; onAction(copy) }
            }
        }
        if (item.state == TransferState.failed && item.archiveMove == null) {
            TextAction(tr("project.retry"), color = Tk.L.accent, onClick = onRetry)
        }
    }
}

/** 长按菜单：只在真能移动时给「移动」（规则同 iOS projectActions）；移动进行中不能复制。 */
@Composable
private fun ProjectMenuItems(item: CaptureItem, onAction: (Boolean) -> Unit) {
    if (item.canMoveToProject || item.canRequestArchiveMove) {
        DropdownMenuItem(
            text = { Text(tr("library.move"), style = Fonts.body()) },
            leadingIcon = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null) },
            onClick = { onAction(false) },
        )
    }
    DropdownMenuItem(
        text = { Text(tr("queue.copy"), style = Fonts.body()) },
        leadingIcon = { Icon(painterResource(R.drawable.ic_content_copy), contentDescription = null) },
        enabled = !item.moveBlocksMutation,
        onClick = { onAction(true) },
    )
}

@Composable
private fun ProgressLine(progress: Double) {
    // 进度条永远给一点起始宽度：0% 的条看起来像卡死了，实际是刚开始
    Box(Modifier.fillMaxWidth().padding(top = 2.dp).height(2.dp).background(Tk.L.sunken)) {
        Box(Modifier.fillMaxWidth(progress.toFloat().coerceIn(0.05f, 1f)).height(2.dp).background(Tk.S.moving))
    }
}

@Composable
private fun Empty() {
    Column(Modifier.padding(top = Tk.Sp.s16), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
        Text(tr("library.empty"), style = Fonts.body(), color = Tk.L.fg)
        Text(tr("queue.emptyHint"), style = Fonts.micro(), color = Tk.L.fgFaint)
    }
}

/** 一件的详情。镜像 iOS `QueueView.details`。 */
@Composable
private fun Details(
    item: CaptureItem,
    progress: Double,
    organization: CaptureOrganization?,
    expiresAt: String?,
    currentBinding: String?,
    onRetry: () -> Unit,
    onAction: (Boolean) -> Unit,
) {
    val move = item.archiveMove?.takeIf { it.status != ArchiveMoveStatus.done }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Tk.Sp.gutter),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4),
    ) {
        Column(Modifier.widthIn(max = 640.dp), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
            EvidenceThumb(item, onDark = false, modifier = Modifier.fillMaxWidth().height(180.dp), iconSize = 40.dp)
            Text(if (move != null) item.queueCaption else item.state.detail, style = Fonts.heading(), color = Tk.L.fg)
            Text(if (item.project == null) tr("queue.unassigned") else item.state.whereItIs, style = Fonts.small(), color = Tk.L.fgMuted)
            Text(item.project?.name ?: tr("library.unknownProject"), style = Fonts.body(), color = Tk.L.fg)

            Row(horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
                if (item.canMoveToProject || item.canRequestArchiveMove) {
                    IconAction(R.drawable.ic_folder, tr("library.move")) { onAction(false) }
                }
                IconAction(R.drawable.ic_content_copy, tr("queue.copy"), enabled = !item.moveBlocksMutation) { onAction(true) }
            }
            if (item.moveBlocksMutation) Text(tr("queue.moveHint"), style = Fonts.micro(), color = Tk.L.fgMuted)

            if (move != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                    Icon(painterResource(R.drawable.ic_arrow_forward), contentDescription = null, tint = Tk.L.fgMuted, modifier = Modifier.size(16.dp))
                    Text(move.target.name, style = Fonts.body(), color = Tk.L.fg)
                }
                val accountChanged = move.accountBinding != currentBinding
                if (accountChanged) Text(tr("queue.moveAccountChanged"), style = Fonts.small(), color = Tk.S.failed)
                move.lastError?.let { Text(it, style = Fonts.small(), color = Tk.S.failed) }
                // 等目标的事务可能熬过中转有效期：显式重试同一个请求
                IconAction(null, tr("queue.moveRetry"), enabled = !accountChanged, onClick = onRetry)
            }

            Text(LibraryTime.full(item.capturedAt), style = Fonts.small(), color = Tk.L.fg)
            if (item.state == TransferState.uploading) {
                ProgressLine(progress)
                Text(tr("organize.uploading"), style = Fonts.small(), color = Tk.L.fgMuted)
            }
            organization?.let { result ->
                Text(result.caption, style = Fonts.small(), color = Tk.L.fg)
                if (result.state == "ready") (result.archiveName ?: result.fileName)?.let {
                    SelectionContainer { Text(it, style = Fonts.small(), color = Tk.L.fg) }
                }
                if (result.tags.isNotEmpty()) Text(result.tags.joinToString(" · "), style = Fonts.small(), color = Tk.L.fgMuted)
            }
            if (item.state == TransferState.failed && item.archiveMove == null) {
                item.lastError?.takeIf { it.isNotEmpty() }?.let { Text(it, style = Fonts.small(), color = Tk.S.failed) }
                PrimaryButton(tr("project.retry"), onClick = onRetry)
            }
            if (item.state == TransferState.uploaded) {
                expiryDate(expiresAt)?.let { Text(tr("queue.expiresOn", mapOf("date" to it)), style = Fonts.small(), color = Tk.L.fg) }
            }
            // 文件指纹只在详情里出现，并说明用途；等宽、可选中、RTL 下也不翻转
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(tr("details.fingerprint").uppercase(), style = Fonts.nano(), color = Tk.L.fgFaint)
                CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                    SelectionContainer { Text(item.manifest.sha256, style = Fonts.mono(Tk.Ty.micro), color = Tk.L.fg) }
                }
            }
        }
    }
}

/** 次级动作：图标 + 强调色文字，不做实心按钮（这套视觉里实心按钮只给主动作）。 */
@Composable
private fun IconAction(icon: Int?, text: String, enabled: Boolean = true, onClick: () -> Unit) {
    val color = if (enabled) Tk.L.accent else Tk.L.fgFaint
    Row(
        Modifier.heightIn(min = Tk.touchMin)
            .clickable(enabled = enabled, onClick = onClick, interactionSource = remember { MutableInteractionSource() }, indication = null)
            .semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
    ) {
        if (icon != null) Icon(painterResource(icon), contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        Text(text, style = Fonts.small(), color = color)
    }
}

/** 到期日写成「月 日」：中文出「9月12日」，英文出「Sep 12」，跟着界面语言走（同 iOS 的 MMMd 模板）。 */
private fun expiryDate(expiresAt: String?): String? {
    val at = expiresAt?.let { IsoTime.parse(it) } ?: return null
    val locale = Locale.forLanguageTag(L10n.locale)
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "MMMd")
    return DateTimeFormatter.ofPattern(pattern, locale).format(at.atZone(ZoneId.systemDefault()))
}

@Composable
private fun TopBar(canRetryAll: Boolean, onRetryAll: () -> Unit, onClose: () -> Unit) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.gutter, bottom = Tk.Sp.s2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
        ) {
            BarIcon(R.drawable.ic_close, tr("common.close"), onClose)
            Column(Modifier.weight(1f)) {
                Text(tr("queue.title"), style = Fonts.heading(), color = Tk.L.fg)
                Text(tr("queue.allProjects"), style = Fonts.nano(), color = Tk.L.fgFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (canRetryAll) TextAction(tr("queue.retryAll"), color = Tk.L.accent, onClick = onRetryAll)
        }
        Hairline(color = Tk.L.rule)
    }
}

@Composable
private fun DetailBar(showBack: Boolean, onBack: () -> Unit) {
    Column {
        Row(
            Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).padding(start = Tk.Sp.s2, end = Tk.Sp.gutter),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
        ) {
            if (showBack) BarIcon(R.drawable.ic_chevron_left, tr("common.back"), onBack)
            else Box(Modifier.width(Tk.Sp.s2))
            Text(tr("queue.details"), style = Fonts.heading(), color = Tk.L.fg)
        }
        Hairline(color = Tk.L.rule)
    }
}

@Composable
private fun BarIcon(icon: Int, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(Tk.touchMin).noRipple(onClick).semantics { contentDescription = label; role = Role.Button },
        contentAlignment = Alignment.Center,
    ) { Icon(painterResource(icon), contentDescription = null, tint = Tk.L.fg, modifier = Modifier.size(20.dp)) }
}

/** 文字动作。次级动作不做按钮，只做一段可点的强调色文字——且不带默认的方框水波纹。 */
@Composable
internal fun TextAction(text: String, color: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Text(
        text = text, style = Fonts.small(), color = color,
        modifier = modifier.heightIn(min = Tk.touchMin).noRipple(onClick).wrapContentHeight(),
    )
}

/**
 * 无涟漪、无焦点框的点击。默认 `clickable` 会在文字动作上留一块灰底方框（选项目页上
 * 「退出登录」那一块），在这套「文字即动作」的视觉里是脏的。
 */
@Composable
internal fun Modifier.noRipple(onClick: () -> Unit): Modifier {
    val interaction = remember { MutableInteractionSource() }
    return clickable(interactionSource = interaction, indication = null, onClick = onClick)
}
