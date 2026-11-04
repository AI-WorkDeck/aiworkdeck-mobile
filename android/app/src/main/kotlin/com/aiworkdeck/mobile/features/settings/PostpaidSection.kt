// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency

@Composable
fun PostpaidSection(canRepay: Boolean, repay: () -> Unit) {
    val backend = remember { ServiceLocator.backend.accountSnapshot() }
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf<PostpaidState?>(null) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    var confirmResume by remember { mutableStateOf(false) }
    fun amount(cents: Long, currency: String): String = NumberFormat.getCurrencyInstance().apply { this.currency = Currency.getInstance(currency) }.format(BigDecimal.valueOf(cents, 2))
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
    Column {
        Text(tr("postpaid.title"))
        state?.let { current ->
            val b = current.billing
            Text(tr("postpaid.limit") + ": " + amount(b.creditLimitCents, b.cashCurrency))
            Text(tr("postpaid.available") + ": " + amount(b.availableCreditCents, b.cashCurrency))
            Text(tr("postpaid.debt") + ": " + amount(b.debtCents, b.cashCurrency))
            b.remindAt?.let { Text(tr("postpaid.remind") + ": " + it) }
            b.cleanupAt?.let { Text(tr("postpaid.cleanup") + ": " + it) }
            Text(tr("postpaid.storageRate", mapOf("amount" to amount(b.storagePrice.cashCentsPerGiBMonth, b.storagePrice.cashCurrency))))
            b.egressPrice?.let { Text(tr("postpaid.egressRate", mapOf("amount" to amount(it.cashCentsPerGiB, it.cashCurrency)))) }
            Text(tr("postpaid.notice"))
            if (!canRepay) Text(tr("postpaid.channelUnavailable"))
            if (current.cloudAccess.cleanupState == "complete") Text(tr("postpaid.cleared"))
            else if (!current.cloudAccess.canUse) Text(tr("postpaid.restricted"))
            if (canRepay && !b.accepted && b.acceptEnabled && b.egressPrice != null) TextButton(onClick = { confirm = true }, enabled = !busy) { Text(tr("postpaid.accept")) }
            if (b.accepted && (current.cloudAccess.frozen != true || b.debtCents == 0L)) TextButton(onClick = { confirmResume = true }, enabled = !busy) { Text(tr("postpaid.resume")) }
            if (canRepay && b.debtCents > 0) TextButton(onClick = repay, enabled = !busy) { Text(tr("postpaid.repay")) }
        }
        if (busy) LinearProgressIndicator()
        if (failed) Text(tr("balance.unavailable"))
        TextButton(onClick = { scope.launch { load() } }, enabled = !busy) { Text(tr("project.retry")) }
    }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text(tr("postpaid.accept")) }, text = { Text(tr("postpaid.notice")) },
        confirmButton = { TextButton(onClick = { confirm = false; scope.launch { load(true) } }) { Text(tr("postpaid.accept")) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(tr("common.cancel")) } })
    if (confirmResume) AlertDialog(onDismissRequest = { confirmResume = false }, title = { Text(tr("postpaid.resume")) }, text = { Text(tr("postpaid.resumeNotice")) },
        confirmButton = { TextButton(onClick = { confirmResume = false; scope.launch { load(resume = true) } }) { Text(tr("postpaid.resume")) } },
        dismissButton = { TextButton(onClick = { confirmResume = false }) { Text(tr("common.cancel")) } })

}
