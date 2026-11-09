// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.aiworkdeck.mobile.design.*
import com.aiworkdeck.mobile.features.queue.noRipple
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency

private fun amount(cents: Long, currency: String): String = NumberFormat.getCurrencyInstance().apply { this.currency = Currency.getInstance(currency) }.format(BigDecimal.valueOf(cents, 2))

/**
 * 设置页里的一行：名称 + 一个词的状态，点进去才是授信、费率与条款。
 * 大多数人从没开通过后付费，不该在设置首屏读一整段扣费条款。镜像 iOS `PostpaidSection`。
 */
@Composable
fun PostpaidSection(canRepay: Boolean, repay: () -> Unit) {
    val backend = remember { ServiceLocator.backend.accountSnapshot() }
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf<PostpaidState?>(null) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var open by remember { mutableStateOf(false) }
    suspend fun load(accept: Boolean = false, resume: Boolean = false) {
        if (busy) return
        busy = true; failed = false
        try {
            if (resume) { com.aiworkdeck.mobile.services.CloudEpoch.invalidate(); ServiceLocator.queue.pauseCloudUploads() }
            state = if (accept || (resume && state?.cloudAccess?.frozen == true)) backend.acceptPostpaid(requireNotNull(state).billing.policyVersion, resume) else backend.cloudBillingState()
            if (accept || resume) { backend.reconnectCloud() }
        }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { failed = true }
        finally { busy = false }
    }
    LaunchedEffect(Unit) { load() }

    val b = state?.billing
    val status: String? = when {
        failed -> "—"
        b == null -> null
        b.debtCents > 0 -> amount(b.debtCents, b.cashCurrency)
        !b.accepted -> tr("postpaid.status.off")
        state?.cloudAccess?.canUse == true -> tr("postpaid.status.on")
        else -> tr("postpaid.status.restricted")
    }
    val statusColor = if (b != null && (b.debtCents > 0 || (b.accepted && state?.cloudAccess?.canUse == false))) Tk.S.failed else Tk.L.fgMuted
    Row(
        Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).noRipple { open = true },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
    ) {
        Text(tr("postpaid.title"), style = Fonts.small(), color = Tk.L.fg, maxLines = 1)
        Text(
            status.orEmpty(), style = Fonts.small(), color = statusColor, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.End, modifier = Modifier.weight(1f),
        )
        Text("›", style = Fonts.body(), color = Tk.L.fgFaint)
    }

    if (open) {
        val close = { open = false; scope.launch { load() }; Unit }
        PostpaidDetail(
            state = state, busy = busy, failed = failed, canRepay = canRepay,
            repay = { close(); repay() }, onClose = close,
            reload = { accept, resume -> scope.launch { load(accept, resume) } },
        )
    }
}

/** 后付费详情：数字一行一项（名称左、值右），条款放最后当脚注，动作按钮只在能做时出现。 */
@Composable
private fun PostpaidDetail(
    state: PostpaidState?, busy: Boolean, failed: Boolean, canRepay: Boolean,
    repay: () -> Unit, onClose: () -> Unit, reload: (accept: Boolean, resume: Boolean) -> Unit,
) {
    var confirm by remember { mutableStateOf(false) }
    var confirmResume by remember { mutableStateOf(false) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        LightStatusBar()
        WorkdeckTheme(dark = false) {
            Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
                Column {
                    Row(
                        Modifier.fillMaxWidth().padding(start = Tk.Sp.s2, end = Tk.Sp.gutter, bottom = Tk.Sp.s2),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2),
                    ) {
                        Box(
                            Modifier.size(Tk.touchMin).noRipple(onClose).semantics { contentDescription = tr("common.close") },
                            contentAlignment = Alignment.Center,
                        ) { Text("✕", style = Fonts.body(), color = Tk.L.fg) }
                        Text(tr("postpaid.title"), style = Fonts.heading(), color = Tk.L.fg)
                    }
                    Hairline(color = Tk.L.rule)
                }
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = Tk.Sp.gutter).padding(bottom = Tk.Sp.s10),
                    verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
                ) {
                    if (state != null) {
                        val b = state.billing
                        if (state.cloudAccess.cleanupState == "complete") Notice(tr("postpaid.cleared"))
                        else if (b.accepted && !state.cloudAccess.canUse) Notice(tr("postpaid.restricted"))

                        Spacer(Modifier.height(Tk.Sp.s2))
                        DetailRow(tr("postpaid.limit"), amount(b.creditLimitCents, b.cashCurrency))
                        DetailRow(tr("postpaid.available"), amount(b.availableCreditCents, b.cashCurrency))
                        DetailRow(tr("postpaid.debt"), amount(b.debtCents, b.cashCurrency), alert = b.debtCents > 0)
                        val locale = java.util.Locale.forLanguageTag(L10n.locale)
                        b.remindAt?.let { DetailRow(tr("postpaid.remind"), formatDateTime(it, locale)) }
                        b.cleanupAt?.let { DetailRow(tr("postpaid.cleanup"), formatDateTime(it, locale)) }
                        Hairline(color = Tk.L.rule, modifier = Modifier.padding(vertical = Tk.Sp.s2))
                        Text(tr("postpaid.storageRate", mapOf("amount" to amount(b.storagePrice.cashCentsPerGiBMonth, b.storagePrice.cashCurrency))), style = Fonts.small(), color = Tk.L.fg)
                        b.egressPrice?.let { Text(tr("postpaid.egressRate", mapOf("amount" to amount(it.cashCentsPerGiB, it.cashCurrency))), style = Fonts.small(), color = Tk.L.fg) }
                        Text(tr("postpaid.notice"), style = Fonts.nano(), color = Tk.L.fgFaint, modifier = Modifier.padding(top = Tk.Sp.s2))
                        if (!canRepay) Text(tr("postpaid.channelUnavailable"), style = Fonts.nano(), color = Tk.L.fgFaint)

                        Column(Modifier.padding(top = Tk.Sp.s4), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
                            if (canRepay && b.debtCents > 0) PrimaryButton(tr("postpaid.repay"), onClick = repay, enabled = !busy)
                            if (canRepay && !b.accepted && b.acceptEnabled && b.egressPrice != null) PrimaryButton(tr("postpaid.accept"), onClick = { confirm = true }, enabled = !busy)
                            if (b.accepted && (state.cloudAccess.frozen != true || b.debtCents == 0L)) {
                                TextButton(onClick = { confirmResume = true }, enabled = !busy) { Text(tr("postpaid.resume"), style = Fonts.small(), color = Tk.L.accent) }
                            }
                        }
                    }
                    if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = Tk.Sp.s4), color = Tk.L.accent, trackColor = Tk.L.rule)
                    if (failed) {
                        Notice(tr("balance.unavailable"))
                        TextButton(onClick = { reload(false, false) }, enabled = !busy) { Text(tr("project.retry"), style = Fonts.small(), color = Tk.L.accent) }
                    }
                }
            }
            if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text(tr("postpaid.accept")) }, text = { Text(tr("postpaid.notice")) },
                confirmButton = { TextButton(onClick = { confirm = false; reload(true, false) }) { Text(tr("postpaid.accept")) } },
                dismissButton = { TextButton(onClick = { confirm = false }) { Text(tr("common.cancel")) } })
            if (confirmResume) AlertDialog(onDismissRequest = { confirmResume = false }, title = { Text(tr("postpaid.resume")) }, text = { Text(tr("postpaid.resumeNotice")) },
                confirmButton = { TextButton(onClick = { confirmResume = false; reload(false, true) }) { Text(tr("postpaid.resume")) } },
                dismissButton = { TextButton(onClick = { confirmResume = false }) { Text(tr("common.cancel")) } })
        }
    }
}

@Composable
private fun DetailRow(key: String, value: String, alert: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 32.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
    ) {
        Text(key, style = Fonts.small(), color = Tk.L.fg, maxLines = 1)
        Text(
            value, style = Fonts.small(), color = if (alert) Tk.S.failed else Tk.L.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.End, modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun Notice(text: String, color: Color = Tk.S.failed) {
    Text(text, style = Fonts.small(), color = color, modifier = Modifier.padding(top = Tk.Sp.s4))
}
