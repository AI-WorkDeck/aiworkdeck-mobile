package com.aiworkdeck.mobile.features.queue

import com.aiworkdeck.mobile.services.ServiceLocator

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.StatusDot
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.auth.Eyebrow
import com.aiworkdeck.mobile.features.library.LibraryTime
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.TransferState
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.time.Instant

/**
 * 上传队列。存在的理由只有一个：**出事的时候能看懂、能自救。**
 * 只给一个红点，用户既不知道该重试还是该找人，也不知道是自己网络的问题还是我们的问题。
 *
 * 只列当前项目——进度跟着项目走。别的项目的未落盘件在末尾提一句，不完全藏起来。
 * 镜像 iOS `QueueView`。
 */
@Composable
fun QueueScreen(model: AppModel, onClose: () -> Unit) {
    val scoped by model.currentItems.collectAsStateWithLifecycle()
    val project by model.selectedProject.collectAsStateWithLifecycle()
    val otherPending by model.otherPendingCount.collectAsStateWithLifecycle()
    val expiry by model.cloudExpiry.collectAsStateWithLifecycle()
    val progress by model.uploadProgress.collectAsStateWithLifecycle()

    // 开着队列页时每 20 秒问一次投递回执——「已暂存」翻成「已落盘」的那一下应该发生在
    // 用户眼前，而不是下次冷启动。
    LaunchedEffect(Unit) {
        while (isActive) {
            model.checkDelivered()
            delay(20_000)
        }
    }

    val failed = scoped.filter { it.state == TransferState.failed }
    val active = scoped.filter { it.state == TransferState.waiting || it.state == TransferState.uploading }
    val staged = scoped.filter { it.state == TransferState.uploaded }
    val landed = scoped.filter { it.state == TransferState.arrived }

    WorkdeckTheme(dark = false) {
        Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
            TopBar(
                projectName = project?.name.orEmpty(),
                canRetryAll = failed.isNotEmpty(),
                onRetryAll = { model.retryFailedUploads() },
                onClose = onClose,
            )

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
            ) {
                section(tr("queue.section.failed"), failed, Tk.S.failed, expiry, progress, model::retry)
                section(tr("queue.section.uploading"), active, Tk.S.waiting, expiry, progress, model::retry)
                section(tr("queue.section.staged"), staged, Tk.S.moving, expiry, progress, model::retry)
                section(tr("queue.section.landed"), landed, Tk.S.arrived, expiry, progress, model::retry)

                if (scoped.isEmpty()) {
                    item {
                        Text(
                            tr("library.empty"), style = Fonts.body(), color = Tk.L.fg,
                            modifier = Modifier.padding(top = Tk.Sp.s16),
                        )
                    }
                }
                // 队列只看当前项目，但别的项目的未落盘件不能完全藏起来——至少说一声有多少
                if (otherPending > 0) {
                    item {
                        Text(
                            tr("library.otherPending", mapOf("n" to otherPending)),
                            style = Fonts.nano(), color = Tk.L.fgFaint,
                            modifier = Modifier.padding(top = Tk.Sp.s6, bottom = Tk.Sp.s4),
                        )
                    }
                }
            }
        }
    }
}

/** 一段。空段不占位——四段全画会让「失败」段在最需要被看见的时候排在一堆空标题里。 */
private fun LazyListScope.section(
    title: String,
    items: List<CaptureItem>,
    tint: Color,
    expiry: Map<String, String>,
    progress: Map<String, Double>,
    onRetry: (String) -> Unit,
) {
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
            progress = progress[item.id] ?: item.progress,
            expiresAt = expiry[item.manifest.clientMediaId.lowercase()],
            onRetry = { onRetry(item.id) },
        )
        Hairline(color = Tk.L.rule)
    }
}

@Composable
private fun QueueRow(item: CaptureItem, progress: Double, expiresAt: String?, onRetry: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = Tk.Sp.s3),
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
    ) {
        Thumb(item, Modifier.size(44.dp))

        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
            ) {
                StatusDot(item.state, onDark = false)
                Text(item.state.caption, style = Fonts.small(), color = Tk.L.fg)
                Text(
                    LibraryTime.clock(item.capturedAt),
                    style = Fonts.mono(Tk.Ty.small), color = Tk.L.fgFaint,
                )
            }

            ServiceLocator.prefs.organizationResult(ServiceLocator.backend.personalAccountScope(), item.manifest.clientMediaId)?.let { organization ->
                Text(organization.caption, style = Fonts.nano(), color = Tk.L.fgFaint)
                if (organization.state == "ready") (organization.archiveName ?: organization.fileName)?.let { Text(it, style = Fonts.small(), color = Tk.L.fg) }
                if (organization.tags.isNotEmpty()) Text(organization.tags.joinToString(" · "), style = Fonts.nano(), color = Tk.L.fgFaint)
            }
            if (item.state == TransferState.uploading) {
                Text(tr("organize.uploading"), style = Fonts.nano(), color = Tk.L.fgFaint)
                // 进度条永远给一点起始宽度：0% 的条看起来像卡死了，实际是刚开始
                Box(Modifier.fillMaxWidth().height(2.dp).background(Tk.L.sunken)) {
                    Box(
                        Modifier.fillMaxWidth(progress.toFloat().coerceIn(0.05f, 1f))
                            .height(2.dp).background(Tk.S.moving),
                    )
                }
            }

            // 失败原因照实显示。区分「你的网络」与「我们这边」，用户才知道是该换个地方
            // 重试还是该找人。
            if (item.state == TransferState.failed) {
                item.lastError?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, style = Fonts.nano(), color = Tk.S.failed)
                }
            }

            // 中转区不是网盘：到期未被桌面端取走就会被清理。只在还剩不到 3 天时说话。
            if (item.state == TransferState.uploaded) {
                val days = expiryDaysLeft(expiresAt, Instant.now())
                if (days != null && days < EXPIRY_WARN_DAYS) {
                    Text(
                        tr("queue.expires", mapOf("days" to days)),
                        style = Fonts.nano(), color = Tk.S.waiting,
                    )
                }
            }

            // 哈希前 12 位。要核对时不用进详情页。
            Text(
                item.manifest.sha256.take(12),
                style = Fonts.mono(Tk.Ty.nano), color = Tk.L.fgFaint,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }

        if (item.state == TransferState.failed) {
            TextAction(tr("project.retry"), color = Tk.L.accent, onClick = onRetry)
        }
    }
}

/** 缩略图。录像由全局 ImageLoader 取首帧；录音没有画面，用音符占位。 */
@Composable
private fun Thumb(item: CaptureItem, modifier: Modifier = Modifier) {
    Box(modifier.background(Tk.L.sunken), contentAlignment = Alignment.Center) {
        if (item.kind == MediaKind.audio) {
            Text("♪", style = Fonts.body(), color = Tk.L.fgMuted)
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
private fun TopBar(projectName: String, canRetryAll: Boolean, onRetryAll: () -> Unit, onClose: () -> Unit) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.gutter, bottom = Tk.Sp.s2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
        ) {
            Box(
                Modifier.size(Tk.touchMin).noRipple(onClose)
                    .semantics { contentDescription = tr("common.close") },
                contentAlignment = Alignment.Center,
            ) { Text("✕", style = Fonts.body(), color = Tk.L.fg) }

            Column(Modifier.weight(1f)) {
                Text(tr("queue.title"), style = Fonts.heading(), color = Tk.L.fg)
                if (projectName.isNotEmpty()) {
                    Text(
                        projectName, style = Fonts.nano(), color = Tk.L.fgFaint,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            if (canRetryAll) TextAction(tr("queue.retryAll"), color = Tk.L.accent, onClick = onRetryAll)
        }
        Hairline(color = Tk.L.rule)
    }
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
