// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.firm

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.repeatOnLifecycle
import com.aiworkdeck.mobile.design.*
import com.aiworkdeck.mobile.features.auth.Eyebrow
import com.aiworkdeck.mobile.services.firm.FirmInbox
import com.aiworkdeck.mobile.services.firm.FirmMatterSummary
import com.aiworkdeck.mobile.services.firm.FirmPortal
import com.aiworkdeck.mobile.services.firm.FirmTabs
import com.aiworkdeck.mobile.services.firm.FirmText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Reviews tab: what needs the lawyer first, then waiting, in progress, and done (iOS FirmInboxView). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FirmInboxScreen(portal: FirmPortal, onOpenSettings: () -> Unit, onOpenMatter: (FirmMatterSummary) -> Unit) {
    val scope = rememberCoroutineScope()
    val overview by portal.overview.collectAsState(initial = emptyList())
    var refreshing by remember { mutableStateOf(false) }
    // Polls while the tab is on screen; instant delivery needs a server push (see the spec).
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { while (true) { portal.refresh(); delay(30_000) } }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { scope.launch { portal.retry(); portal.refresh() } }
    val approved = overview.filter { it.second.access == com.aiworkdeck.mobile.services.firm.FirmAccess.approved }
    val matters = approved.flatMap { it.second.matters }
    val error = approved.firstNotNullOfOrNull { it.second.loadErrorKey }
    val names = approved.associate { (l, s) -> l.portalID to (s.me?.firm?.text?.takeIf { it.isNotEmpty() } ?: l.portalID) }
    LightStatusBar()
    Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().padding(horizontal = Tk.Sp.gutter)) {
        Row(Modifier.fillMaxWidth().heightIn(min = Tk.touchMin), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text(tr("firm.tab"), style = Fonts.title(), color = Tk.L.fg)
            TextButton(onClick = onOpenSettings) { Text(tr("home.settings"), style = Fonts.body()) }
        }
        PullToRefreshBox(isRefreshing = refreshing, onRefresh = { scope.launch { refreshing = true; portal.refresh(); refreshing = false } }, modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize().testTag("firm.inbox"), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2), contentPadding = PaddingValues(vertical = Tk.Sp.s4)) {
                when (FirmInbox.placeholder(matters.isNotEmpty(), listed = approved.all { it.second.listed }, failed = error != null)) {
                    FirmInbox.Placeholder.loading -> item { Box(Modifier.fillMaxWidth().padding(vertical = Tk.Sp.s10).testTag("firm.inbox.loading"), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Tk.L.accent) } }
                    FirmInbox.Placeholder.empty -> item { Text(tr("firm.inbox.empty"), style = Fonts.body(), color = Tk.L.fgMuted, modifier = Modifier.fillMaxWidth().padding(vertical = Tk.Sp.s10).testTag("firm.inbox.empty")) }
                    null -> {}
                }
                for ((group, items) in FirmInbox.grouped(matters)) {
                    item(key = "h-" + group.name) { Eyebrow(tr(FirmInbox.titleKey(group)), Modifier.padding(top = Tk.Sp.s4)) }
                    items(items, key = { it.uid }) { m -> MatterRow(m, if (approved.size > 1) names[m.linkID] else null) { onOpenMatter(m) } }
                }
                error?.let { item { Text(tr(it), style = Fonts.small(), color = Tk.S.failed) } }
            }
        }
    }
}

@Composable
private fun MatterRow(matter: FirmMatterSummary, firm: String?, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Tk.Sp.s3)).background(Tk.L.sunken).clickable(onClick = onClick)
            .padding(Tk.Sp.s4).testTag("firm.row." + matter.id),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
    ) {
        firm?.let { Text(it, style = Fonts.nano(), color = Tk.L.fgMuted, maxLines = 1) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(FirmText.who(matter.client, matter.company), style = Fonts.heading(), color = Tk.L.fg, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            FirmText.instant(matter.updatedAt)?.let { FirmTabs.agoKey(it) }?.let { (key, n) ->
                Text(tr(key, mapOf("n" to n)), style = Fonts.nano(), color = Tk.L.fgFaint)
            }
        }
        matter.template?.text?.takeIf { it.isNotEmpty() }?.let { Text(it, style = Fonts.small(), color = Tk.L.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        Row(horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
            FirmInbox.reason(matter)?.let { Chip(tr(FirmInbox.reasonKey(it)), if (it == "call_requested") Tk.S.failed else Tk.S.waiting) }
            matter.forLawyerCount?.takeIf { it > 0 }?.let { Chip(tr("firm.forLawyerCount", mapOf("count" to it)), Tk.L.accent) }
        }
    }
}

@Composable
private fun Chip(text: String, color: Color) {
    Text(text, style = Fonts.nano(), color = color, modifier = Modifier.clip(RoundedCornerShape(50)).background(color.copy(alpha = 0.12f)).padding(horizontal = Tk.Sp.s2, vertical = 2.dp))
}
