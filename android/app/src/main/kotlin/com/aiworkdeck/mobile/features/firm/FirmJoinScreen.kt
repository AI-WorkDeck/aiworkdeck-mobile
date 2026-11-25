// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.firm

import com.aiworkdeck.mobile.design.readableWidth
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.aiworkdeck.mobile.design.*
import com.aiworkdeck.mobile.features.auth.Eyebrow
import com.aiworkdeck.mobile.services.firm.FirmAccess
import com.aiworkdeck.mobile.services.firm.FirmLink
import com.aiworkdeck.mobile.services.firm.FirmPortal
import com.aiworkdeck.mobile.services.firm.FirmPortalLink
import com.aiworkdeck.mobile.services.firm.FirmStatus
import kotlinx.coroutines.launch

/** Join a firm's portal and manage linked portals (iOS FirmJoinView). The Reviews tab appears once a firm approves. */
@Composable
fun FirmJoinScreen(portal: FirmPortal, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val links by portal.links.collectAsState()
    var link by remember { mutableStateOf("") }
    var trial by remember { mutableStateOf("") }
    var showTrial by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    fun join() = scope.launch {
        error = null
        val id = FirmPortalLink.portal(link) ?: run { error = tr("firm.join.badHost"); return@launch }
        working = true
        try {
            if (portal.scope == null) portal.restore()
            val key = portal.connect(id, if (showTrial) trial else null)
            error = key?.let { tr(it) }
            if (key == null) { link = ""; trial = ""; showTrial = false }
        } finally { working = false }
    }
    BackHandler(enabled = !working, onBack = onClose)
    LightStatusBar()
    WorkdeckTheme(dark = false) {
        Column(
            Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().readableWidth().imePadding().verticalScroll(rememberScrollState()).padding(Tk.Sp.gutter),
            verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
        ) {
            Text(tr("firm.settings.title"), style = Fonts.title(), color = Tk.L.fg)
            // Every linked portal stays visible, including one that can't be reached now, so it can be retried or removed.
            for (l in links) LinkRow(l, onCheck = { scope.launch { l.check() } }, onLeave = { portal.disconnect(l.portalID) })
            if (links.isNotEmpty()) Eyebrow(tr("firm.join.title"), Modifier.padding(top = Tk.Sp.s4))
            Text(tr("firm.join.body"), style = Fonts.small(), color = Tk.L.fgMuted)
            OutlinedTextField(
                link, { link = it }, Modifier.fillMaxWidth().testTag("firm.join.link"), enabled = !working, singleLine = true,
                placeholder = { Text(tr("firm.join.link")) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
            if (showTrial) OutlinedTextField(
                trial, { trial = it }, Modifier.fillMaxWidth().testTag("firm.join.trial"), enabled = !working, singleLine = true,
                placeholder = { Text(tr("firm.trial.code")) }, visualTransformation = PasswordVisualTransformation(),
            ) else TextButton(onClick = { showTrial = true }, enabled = !working) { Text(tr("firm.trial.use"), color = Tk.L.accent) }
            error?.let { Text(it, style = Fonts.small(), color = Tk.S.failedText, modifier = Modifier.testTag("firm.join.error")) }
            PrimaryButton(tr("firm.join.connect"), onClick = { join() }, modifier = Modifier.fillMaxWidth().testTag("firm.join.connect"),
                enabled = !working && link.isNotBlank())
            if (working) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.rule)
            TextButton(onClick = onClose, enabled = !working) { Text(tr("common.close"), color = Tk.L.accent) }
        }
    }
}

@Composable
private fun LinkRow(l: FirmLink, onCheck: () -> Unit, onLeave: () -> Unit) {
    val state by l.state.collectAsState()
    if (state.access == FirmAccess.none) return
    Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
        val status = FirmStatus.link(state.access, l.firmName)
        Text(status?.let { tr(it.first, it.second) } ?: l.firmName, style = Fonts.body(), color = Tk.L.fg, modifier = Modifier.testTag("firm.join.status"))
        if (state.access == FirmAccess.failed) Text(tr("firm.error.network"), style = Fonts.small(), color = Tk.S.failedText)
        state.me?.trialUntil?.let { Text(tr("firm.trial.until", mapOf("date" to it.take(10))), style = Fonts.small(), color = Tk.L.fgMuted) }
        Row(horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
            if (state.access in setOf(FirmAccess.pending, FirmAccess.checking, FirmAccess.failed)) TextButton(onClick = onCheck) { Text(tr("firm.status.check"), color = Tk.L.accent) }
            TextButton(onClick = onLeave, modifier = Modifier.testTag("firm.leave")) { Text(tr("firm.leave"), color = Tk.S.failedText) }
        }
        Hairline()
    }
}
