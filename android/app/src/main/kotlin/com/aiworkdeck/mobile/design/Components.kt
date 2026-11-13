package com.aiworkdeck.mobile.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.aiworkdeck.contract.ContractStates
import com.aiworkdeck.mobile.model.TransferPhase
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.model.TransferTally

/**
 * 状态点颜色解析。纯函数（不依赖 Compose 运行时），可在 JVM 单测里直接调用。
 * 按 [ContractStates.phaseDot] / [ContractStates.failedDot] 的令牌名解析——不写死状态到颜色的
 * 对应关系，令牌表改了这里的 `when` 分支会因为 `error()` 在测试里炸掉，而不是默默给错颜色。
 */
fun dotColor(state: TransferState, onDark: Boolean): Color {
    val token = if (state == TransferState.failed) ContractStates.failedDot else ContractStates.phaseDot.getValue(state.phase.raw)
    return when (token) {
        "S.waiting" -> if (onDark) Tk.S.waitingOnDark else Tk.S.waiting
        "S.moving" -> if (onDark) Tk.S.movingOnDark else Tk.S.moving
        "S.arrived" -> if (onDark) Tk.S.arrivedOnDark else Tk.S.arrived
        "S.failed" -> Tk.S.failed
        else -> error("未知状态点令牌: $token")
    }
}

/** 状态点。色只做点，不做块——三端一致的克制。 */
@Composable
fun StatusDot(state: TransferState, onDark: Boolean = LocalOnDark.current, size: Dp = 5.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).clip(CircleShape).background(dotColor(state, onDark)))
}

/** 发丝线。分区靠它，不靠卡片阴影。 */
@Composable
fun Hairline(modifier: Modifier = Modifier, color: Color = if (LocalOnDark.current) Tk.D.rule else Tk.L.rule) {
    Box(modifier.fillMaxWidth().height(1.dp).background(color))
}

/**
 * 计数小标签：点 + 等宽计数 + 小字标签。名字叫 Pill 但不做色块背景——状态色只许落在点上，
 * 这是这套视觉语言的底线（`docs/specs/2026-08-17-mobile-clients-design.md` §5）。
 */
@Composable
fun Pill(count: Int, label: String, color: Color, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
        Box(Modifier.size(5.dp).clip(CircleShape).background(color))
        Text(text = count.toString(), style = Fonts.mono(Tk.Ty.small))
        Text(text = label, style = Fonts.small(), color = if (LocalOnDark.current) Tk.D.fgMuted else Tk.L.fgMuted)
    }
}

/**
 * 三桶计数行：上传中 / 已暂存 / 已落盘，失败件不单列一桶而是追加在末尾的小字后缀
 * （`tally.failedSuffix`）——失败是「上传中」桶里的异常，不是并列的第四态。
 */
@Composable
fun TallyRow(tally: TransferTally, onDark: Boolean = LocalOnDark.current, modifier: Modifier = Modifier, hideZero: Boolean = false) {
    CompositionLocalProvider(LocalOnDark provides onDark) {
        Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
            // hideZero：图集顶栏只说有的，「0 上传中」是噪音；已落盘一桶始终在，作为总数的锚
            if (!hideZero || tally.uploading > 0) Pill(tally.uploading, TransferPhase.uploading.caption, dotColor(TransferState.uploading, onDark))
            if (!hideZero || tally.staged > 0) Pill(tally.staged, TransferPhase.staged.caption, dotColor(TransferState.uploaded, onDark))
            Pill(tally.landed, TransferPhase.landed.caption, dotColor(TransferState.arrived, onDark))
            if (tally.failed > 0) {
                Text(text = tr("tally.failedSuffix", mapOf("m" to tally.failed)), style = Fonts.small(), color = Tk.S.failed)
            }
        }
    }
}

/**
 * 玻璃条：压在影像上的半透明深色带（影像浏览的顶栏与底座）。
 *
 * 契约把 `glassBlur` 标为 `"runtime"`：Compose 没法「模糊它下面已经画好的内容」——那需要
 * 先把下层截成一张位图再滤镜，属于额外机制（`AndroidExternalSurface` / `graphicsLayer` 的
 * `RenderNode` 快照，成本与复杂度都不小）。所以这里**不做模糊**，只做半透明：
 * `graphicsLayer { renderEffect = BlurEffect(...) }` 糊的是这一层自己画的所有东西——
 * 连同条上的文字一起糊掉（实测顶栏字全花），而挪到文字背后又只是在糊一块纯色，等于白做。
 * 半透明 [Tk.D.surface] 已经能让下面的影像透出来，这就是这一条要的效果。
 */
@Composable
fun GlassBar(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(modifier = modifier.background(Tk.D.surface.copy(alpha = 0.72f)), content = content)
}

/**
 * 主按钮。单一强调色（`Tk.L.accent`）不分明暗——契约里 accent 只在浅色组给了值，深色屏
 * （取景器）上的按钮也用它，这是刻意的单一强调色决策而不是漏映射。
 */
@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Tk.touchMin)
            .clip(CircleShape)
            .background(if (enabled) Tk.L.accent else Tk.L.accent.copy(alpha = 0.4f))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = text, style = Fonts.body(), color = Tk.D.fg)
    }
}

/**
 * 通用列表行：前导内容（缩略图/状态点）+ 主体 + 尾随内容（按钮/箭头），高度不低于
 * [Tk.touchMin]。Queue/Library 的具体行样式在其上再组装。
 */
@Composable
fun RowItem(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Tk.touchMin)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
    ) {
        leading?.invoke()
        Box(Modifier.weight(1f)) { content() }
        trailing?.invoke(this)
    }
}

/**
 * 分段选择（iOS segmented picker 的对应物）：浅灰轨道里等宽几格，选中格垫一块白色圆角滑块。
 * 用于登录页的区域与登录方式。整条至少 [Tk.touchMin] 高，每格都是独立可点目标。
 */
@Composable
fun <T> Segmented(
    options: List<Pair<T, String>>,
    selected: T,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    a11yLabel: String? = null,
    onSelect: (T) -> Unit,
) {
    Row(
        modifier
            .heightIn(min = Tk.touchMin)
            .clip(CircleShape)
            .background(Tk.L.sunken)
            .padding(3.dp)
            .then(if (a11yLabel != null) Modifier.semantics { contentDescription = a11yLabel } else Modifier),
    ) {
        for ((value, label) in options) {
            val on = value == selected
            Box(
                Modifier.weight(1f)
                    .heightIn(min = Tk.touchMin - 6.dp)
                    .clip(CircleShape)
                    .background(if (on) Tk.L.bg else Color.Transparent)
                    .then(if (on) Modifier.border(0.5.dp, Tk.L.rule, CircleShape) else Modifier)
                    .selectable(selected = on, enabled = enabled, role = Role.Tab) { if (!on) onSelect(value) }
                    .padding(horizontal = Tk.Sp.s3),
                contentAlignment = Alignment.Center,
            ) {
                Text(label, style = Fonts.body().copy(fontWeight = if (on) FontWeight.Medium else FontWeight.Normal),
                    color = if (enabled) Tk.L.fg else Tk.L.fgMuted, maxLines = 1)
            }
        }
    }
}
