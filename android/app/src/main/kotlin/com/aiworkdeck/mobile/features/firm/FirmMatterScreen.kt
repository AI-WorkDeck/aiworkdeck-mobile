// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.firm

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.aiworkdeck.mobile.design.*
import com.aiworkdeck.mobile.features.workspace.FilePreview
import com.aiworkdeck.mobile.features.workspace.PreviewKind
import com.aiworkdeck.mobile.services.firm.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.security.MessageDigest

private enum class Layer { None, Reply, Edit, Signoff, Conversation, Pdf }

/**
 * One matter, in the order a partner reads it: the client's list for the lawyer, how red flags were settled,
 * what changed, the document; the conversation one tap away (iOS FirmMatterView). Its own action bar.
 */
@Composable
fun FirmMatterScreen(portal: FirmPortal, ref: FirmMatterSummary, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val link = portal.link(ref.linkID)
    var matter by remember { mutableStateOf<FirmMatter?>(null) }
    var edits by remember { mutableStateOf<List<FirmDiff.Change>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var layer by remember { mutableStateOf(Layer.None) }
    var pdfUrl by remember { mutableStateOf<String?>(null) }
    var toast by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var confirmSendBack by remember { mutableStateOf(false) }
    var moreOpen by remember { mutableStateOf(false) }

    suspend fun load() {
        val client = link?.client() ?: run { error = tr("firm.error.access"); return }
        try {
            val m = client.matter(ref.id)
            val v = m.latest; val p = m.previous
            edits = if (v != null && p != null) withContext(Dispatchers.Default) { FirmDiff.edits(p.markdown, v.markdown) } else emptyList()
            matter = m; error = null
        } catch (e: CancellationException) { throw e } catch (e: FirmPortalError) { error = tr(e.messageKey) }
    }
    fun show(text: String) = scope.launch { toast = text; delay(2500); toast = null }
    /** Runs one portal action, then reloads the matter and the inbox. */
    suspend fun act(work: suspend (FirmPortalClient) -> Unit): Boolean {
        val client = link?.client() ?: return false
        busy = true
        return try { work(client); load(); portal.refresh(); true }
        catch (e: CancellationException) { throw e }
        catch (e: FirmPortalError) { show(tr(e.messageKey)); load(); false }
        finally { busy = false }
    }
    LaunchedEffect(ref.uid) { load() }
    BackHandler(enabled = layer == Layer.None && !busy, onBack = onClose)
    val lawyer = link?.let { l -> l.state.value.me?.let { me -> if (me.kind == "lawyer") me.lawyerName?.text?.takeIf { it.isNotEmpty() } ?: me.name ?: "" else "" } } ?: ""

    LightStatusBar()
    Box(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding()) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onClose, enabled = !busy) { Text(tr("common.back"), color = Tk.L.accent) }
                Text(matter?.template?.text ?: "", style = Fonts.heading(), color = Tk.L.fg, maxLines = 1, modifier = Modifier.weight(1f))
            }
            Hairline()
            val m = matter
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s4),
                verticalArrangement = Arrangement.spacedBy(Tk.Sp.s6)) {
                // A failed reload keeps the last content and says so, with Retry; a first load that fails still shows
                // which matter this is, never a blank page.
                error?.let { msg ->
                    Column(Modifier.fillMaxWidth().testTag("firm.matter.error"), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
                        if (m == null) Text(FirmText.title(ref.client, ref.company, ref.template?.text), style = Fonts.title(), color = Tk.L.fg)
                        Text(msg, style = Fonts.body(), color = Tk.S.failedText)
                        TextButton(onClick = { scope.launch { busy = true; try { load() } finally { busy = false } } }, enabled = !busy,
                            modifier = Modifier.testTag("firm.matter.retry")) { Text(tr("project.retry"), color = Tk.L.accent) }
                    }
                }
                when {
                    m != null -> {
                        Header(m)
                        ForLawyer(m)
                        Flags(m)
                        Changes(m, edits)
                        Document(m) { pdfUrl = it; layer = Layer.Pdf }
                        val count = m.transcript.count { it.role != "event" }
                        Row(Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).clickable { layer = Layer.Conversation }.testTag("firm.conversation"), verticalAlignment = Alignment.CenterVertically) {
                            Text(tr("firm.matter.conversation", mapOf("count" to count)), style = Fonts.body(), color = Tk.L.accent, modifier = Modifier.weight(1f))
                        }
                    }
                    error != null -> {}
                    else -> Box(Modifier.fillMaxWidth().padding(Tk.Sp.s10), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Tk.L.accent) }
                }
            }
            if (m != null && m.status !in setOf("signed", "closed")) {
                Hairline()
                Row(Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s3), horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(onClick = { layer = Layer.Reply }, enabled = !busy, modifier = Modifier.weight(1f).heightIn(min = Tk.touchMin).testTag("firm.reply")) { Text(tr("firm.action.reply"), color = Tk.L.accent) }
                    Box {
                        OutlinedButton(onClick = { moreOpen = true }, enabled = !busy, modifier = Modifier.heightIn(min = Tk.touchMin).testTag("firm.more")) { Text("⋯", color = Tk.L.accent) }
                        DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                            if (m.consult?.status == "requested") DropdownMenuItem(text = { Text(tr("firm.call.confirm")) }, onClick = { moreOpen = false; scope.launch { act { it.consult(m.id, "scheduled") } } })
                            if (m.consult?.status == "scheduled") DropdownMenuItem(text = { Text(tr("firm.call.done")) }, onClick = { moreOpen = false; scope.launch { act { it.consult(m.id, "done") } } })
                            if (m.latest != null) DropdownMenuItem(text = { Text(tr("firm.edit.title")) }, onClick = { moreOpen = false; layer = Layer.Edit })
                            if (m.status != "awaiting_client") DropdownMenuItem(text = { Text(tr("firm.sendBack")) }, onClick = { moreOpen = false; confirmSendBack = true })
                        }
                    }
                    Button(onClick = { layer = Layer.Signoff }, enabled = !busy && m.latest != null, modifier = Modifier.weight(1f).heightIn(min = Tk.touchMin).testTag("firm.signoff"),
                        colors = ButtonDefaults.buttonColors(containerColor = Tk.L.accent)) { Text(tr("firm.action.signoff"), fontWeight = FontWeight.SemiBold) }
                }
            }
        }
        toast?.let { Text(it, style = Fonts.small(), color = Tk.L.fg, modifier = Modifier.align(Alignment.TopCenter).padding(top = Tk.Sp.s10)
            .clip(RoundedCornerShape(50)).background(Tk.L.sunken).padding(horizontal = Tk.Sp.s4, vertical = Tk.Sp.s2).testTag("firm.toast")) }
    }

    val m = matter
    if (m != null) when (layer) {
        Layer.Reply -> FirmReplyLayer(m, onCancel = { layer = Layer.None }) { text ->
            act { it.message(m.id, text, lawyer) }.also { if (it) { layer = Layer.None; show(tr("firm.reply.sent")) } }
        }
        Layer.Edit -> m.latest?.let { v -> FirmEditLayer(v, onCancel = { layer = Layer.None }) { md, note ->
            act { it.saveVersion(m.id, md, note, lawyer) }.also { if (it) layer = Layer.None }
        } }
        Layer.Signoff -> m.latest?.let { v -> link?.let { l -> FirmSignoffLayer(portal, l, m, v, onCancel = { layer = Layer.None },
            onSigned = { pdf -> scope.launch { load(); portal.refresh() }; if (pdf != null) { pdfUrl = pdf; layer = Layer.Pdf } else layer = Layer.None },
            onStale = { scope.launch { load() } }) } }
        Layer.Conversation -> FirmConversationLayer(m) { layer = Layer.None }
        Layer.Pdf -> pdfUrl?.let { FirmPdfLayer(it, portal.scope) { layer = Layer.None } }
        Layer.None -> {}
    }
    if (confirmSendBack) AlertDialog(onDismissRequest = { confirmSendBack = false }, containerColor = Tk.L.bg,
        title = { Text(tr("firm.sendBack")) }, text = { Text(tr("firm.sendBack.confirm")) },
        confirmButton = { TextButton(onClick = { confirmSendBack = false; scope.launch { act { it.setStatus(ref.id, "awaiting_client") } } }) { Text(tr("firm.sendBack"), color = Tk.L.accent) } },
        dismissButton = { TextButton(onClick = { confirmSendBack = false }) { Text(tr("common.cancel"), color = Tk.L.accent) } })
}

@Composable private fun SectionTitle(text: String) = Text(text, style = Fonts.small(), fontWeight = FontWeight.SemiBold, color = Tk.L.fgMuted)

@Composable
private fun Header(m: FirmMatter) = Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
    Text(FirmText.title(m.client, m.company, m.template?.text ?: FirmMarkdown.firstHeading(m.latest?.markdown)), style = Fonts.title(), color = Tk.L.fg)
    m.lawyerDisplayName?.let { Text(tr("firm.matter.requestedLawyer", mapOf("name" to it)), style = Fonts.small(), color = Tk.L.fgMuted) }
    m.consult?.takeIf { it.status == "requested" || it.status == "scheduled" }?.let { c ->
        Text(if (c.status == "scheduled") tr("firm.matter.callScheduled") else FirmText.callLine(c.times).let { (k, v) -> tr(k, v) },
            style = Fonts.small(), color = if (c.status == "requested") Tk.S.failed else Tk.L.accent, modifier = Modifier.testTag("firm.call"))
    }
}

@Composable
private fun ForLawyer(m: FirmMatter) = Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3), modifier = Modifier.testTag("firm.forLawyer")) {
    val items = m.forLawyer ?: emptyList()
    SectionTitle(tr("firm.matter.forLawyer") + if (items.isEmpty()) "" else " · ${items.size}")
    if (items.isEmpty()) Text(tr("firm.matter.forLawyerEmpty"), style = Fonts.body(), color = Tk.L.fgMuted)
    items.forEachIndexed { i, q ->
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Tk.L.accentWash).padding(Tk.Sp.s3), horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
            Text("${i + 1}", style = Fonts.small(), fontWeight = FontWeight.SemiBold, color = Tk.L.accent)
            Column {
                FirmText.section(q.section)?.takeIf { !q.text.startsWith(q.section ?: "") }?.let { Text(it, style = Fonts.small(), fontWeight = FontWeight.SemiBold, color = Tk.L.fgMuted) }
                Text(q.text, style = Fonts.body(), color = Tk.L.fg)
            }
        }
    }
}

@Composable
private fun Flags(m: FirmMatter) {
    val v = m.flagsVersion ?: return
    val flags = v.notes?.flags?.takeIf { it.isNotEmpty() } ?: return
    Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3), modifier = Modifier.testTag("firm.flags")) {
        SectionTitle(tr("firm.matter.flags") + " · " + tr("firm.matter.version", mapOf("n" to v.n)))
        flags.forEach { FlagRow(it, m.settlement(it)) }
        val fresh = m.newFlags
        val latest = m.latest
        if (fresh.isNotEmpty() && latest != null) {
            // Flags the newest draft raised after the client settled the others: never hidden behind them.
            Text(tr("firm.matter.flagsNew", mapOf("n" to latest.n)), style = Fonts.small(), fontWeight = FontWeight.SemiBold, color = Tk.S.failedText, modifier = Modifier.testTag("firm.flags.new"))
            fresh.forEach { FlagRow(it, null) }
        }
    }
}

@Composable
private fun FlagRow(f: FirmFlag, settlement: String?) = Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
    Box(Modifier.size(7.dp).clip(CircleShape).background(if (f.level == "high") Tk.S.failed else Tk.S.waiting))
    Text(listOfNotNull(FirmText.section(f.section), f.title).filter { it.isNotEmpty() }.joinToString(" · "), style = Fonts.body(), color = Tk.L.fg, modifier = Modifier.weight(1f))
    val color = when (settlement) { "lawyer" -> Tk.S.waiting; null -> Tk.L.fgFaint; else -> Tk.L.accent }
    Text(tr(FirmIdentity.settlementKey(settlement)), style = Fonts.micro().copy(fontWeight = FontWeight.Medium), color = color,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(color.copy(alpha = 0.12f)).padding(horizontal = Tk.Sp.s2, vertical = 2.dp))
}

@Composable
private fun Changes(m: FirmMatter, edits: List<FirmDiff.Change>) {
    val v = m.latest ?: return
    Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2), modifier = Modifier.testTag("firm.changes")) {
        SectionTitle(tr("firm.matter.changes", mapOf("n" to v.n)))
        if (m.previous == null) { Text(tr("firm.matter.firstVersion"), style = Fonts.body(), color = Tk.L.fgMuted); return@Column }
        (v.notes?.changes ?: emptyList()).forEach { Text("• $it", style = Fonts.body(), color = Tk.L.fg) }
        edits.take(12).forEach { e ->
            when (e) {
                is FirmDiff.Change.Removed -> Text(FirmMarkdown.plain(e.text), style = Fonts.small(), color = Tk.S.failedText, textDecoration = TextDecoration.LineThrough)
                is FirmDiff.Change.Added -> Text(FirmMarkdown.plain(e.text), style = Fonts.small(), color = Tk.L.accent)
                is FirmDiff.Change.Same -> {}
            }
        }
    }
}

@Composable
private fun Document(m: FirmMatter, onPdf: (String) -> Unit) {
    val v = m.latest
    Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle(tr("firm.matter.document") + (v?.let { " · " + tr("firm.matter.version", mapOf("n" to it.n)) } ?: ""))
            Spacer(Modifier.weight(1f))
            v?.pdfUrl?.let { url -> TextButton(onClick = { onPdf(url) }, modifier = Modifier.testTag("firm.pdf")) { Text(tr("firm.matter.pdf"), color = Tk.L.accent) } }
        }
        if (v == null) { Text(tr("firm.matter.noDraft"), color = Tk.L.fgMuted); return@Column }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).border(1.dp, Tk.L.rule, RoundedCornerShape(12.dp)).padding(Tk.Sp.s4).testTag("firm.document"),
            verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
            for (b in FirmMarkdown.blocks(v.markdown)) {
                if (b.level > 0) Text(FirmMarkdown.plain(b.text), style = if (b.level <= 1) Fonts.title() else Fonts.heading(), color = Tk.L.fg, modifier = Modifier.padding(top = Tk.Sp.s2))
                else Text(FirmMarkdown.plain(b.text), style = Fonts.body(), color = Tk.L.fg)
            }
        }
    }
}

/** Full-screen layer over the matter with a title row: Cancel/Close on the left, an action on the right. */
@Composable
private fun LayerScaffold(title: String, cancel: String, onCancel: () -> Unit, action: (@Composable () -> Unit)? = null,
                          busy: Boolean = false, backDismisses: Boolean = true, content: @Composable ColumnScope.() -> Unit) {
    // Back never drops work in flight; a dirty draft is left only through Cancel (iOS blocks swipe-dismiss the same way).
    BackHandler(enabled = true) { if (!busy && backDismisses) onCancel() }
    Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onCancel, enabled = !busy) { Text(cancel, color = Tk.L.accent) }
            Text(title, style = Fonts.heading(), color = Tk.L.fg, maxLines = 1, modifier = Modifier.weight(1f))
            action?.invoke()
        }
        Hairline()
        Column(Modifier.weight(1f).fillMaxWidth().padding(Tk.Sp.gutter), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3), content = content)
    }
}

@Composable
private fun FirmReplyLayer(matter: FirmMatter, onCancel: () -> Unit, send: suspend (String) -> Boolean) {
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    LayerScaffold(FirmText.title(matter.client, matter.company, matter.template?.text ?: FirmMarkdown.firstHeading(matter.latest?.markdown)), tr("common.cancel"), onCancel, busy = sending, backDismisses = text.isBlank(), action = {
        TextButton(onClick = { sending = true; scope.launch { send(text.trim()); sending = false } }, enabled = !sending && text.isNotBlank(),
            modifier = Modifier.testTag("firm.reply.send")) { Text(tr("firm.reply.send"), color = Tk.L.accent, fontWeight = FontWeight.SemiBold) }
    }) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
            for ((label, body) in listOf("firm.reply.question" to "firm.reply.question.text", "firm.reply.terms" to "firm.reply.terms.text", "firm.reply.callTime" to "firm.reply.callTime.text")) {
                AssistChip(onClick = { text = if (text.isBlank()) tr(body) else text.trimEnd() + "\n" + tr(body) }, label = { Text(tr(label)) })
            }
        }
        OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().heightIn(min = 160.dp).testTag("firm.reply.text"), placeholder = { Text(tr("firm.reply.placeholder")) }, enabled = !sending)
    }
}

@Composable
private fun FirmEditLayer(version: FirmVersion, onCancel: () -> Unit, save: suspend (String, String) -> Boolean) {
    val scope = rememberCoroutineScope()
    var markdown by remember { mutableStateOf(version.markdown) }
    var note by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    LayerScaffold(tr("firm.edit.title"), tr("common.cancel"), onCancel, busy = saving, backDismisses = markdown == version.markdown && note.isBlank(), action = {
        TextButton(onClick = { saving = true; scope.launch { save(markdown, note); saving = false } }, enabled = !saving && markdown != version.markdown,
            modifier = Modifier.testTag("firm.edit.save")) { Text(tr("firm.edit.save", mapOf("n" to version.n + 1)), color = Tk.L.accent, fontWeight = FontWeight.SemiBold) }
    }) {
        OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth().testTag("firm.edit.note"), placeholder = { Text(tr("firm.edit.note")) }, singleLine = true, enabled = !saving)
        OutlinedTextField(markdown, { markdown = it }, Modifier.fillMaxWidth().weight(1f).testTag("firm.edit.text"), enabled = !saving, textStyle = Fonts.small())
    }
}

@Composable
private fun FirmConversationLayer(matter: FirmMatter, onClose: () -> Unit) {
    val entries = matter.transcript.filter { it.role != "event" }
    LayerScaffold(tr("firm.matter.conversation", mapOf("count" to entries.size)), tr("common.close"), onClose) {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
            for (e in entries) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val who = when (e.role) { "user" -> tr("firm.who.client"); "lawyer" -> e.name?.takeIf { it.isNotEmpty() } ?: tr("firm.tab"); else -> tr("firm.who.assistant") }
                Text(who, style = Fonts.micro().copy(fontWeight = FontWeight.Medium), color = if (e.role == "lawyer") Tk.L.accent else Tk.L.fgMuted)
                Text(FirmMarkdown.plain(e.content), style = Fonts.body(), color = Tk.L.fg)
            }
        }
    }
}

/** Sign-off: the identity shown (never typed), three attestations, then the device owner (screen lock). */
@Composable
private fun FirmSignoffLayer(portal: FirmPortal, link: FirmLink, matter: FirmMatter, version: FirmVersion, onCancel: () -> Unit,
                             onSigned: (String?) -> Unit, onStale: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var conflicts by remember { mutableStateOf(false) }
    var engagement by remember { mutableStateOf(false) }
    var reviewed by remember { mutableStateOf(false) }
    var details by remember { mutableStateOf(portal.savedDetails(link.portalID)) }
    var signing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val signer = link.signer(matter)
    val ready = FirmIdentity.signoffReady(conflicts, engagement, reviewed, signer)
    val asks = link.asksDetails
    suspend fun sign() {
        val s = signer ?: run { error = tr("firm.error.access"); return }
        val client = link.client() ?: run { error = tr("firm.error.access"); return }
        try {
            val given = if (asks) details.mapValues { it.value.trim() } else emptyMap()
            val pdf = client.signoff(matter.id, version.n, s.name, given)
            if (asks) portal.saveDetails(link.portalID, given)
            onSigned(pdf?.takeIf { FirmPortalLink.isPortalUrl(it) })
        } catch (e: CancellationException) { throw e } catch (e: FirmPortalError) {
            error = tr(e.messageKey)
            if (e.code == "version_changed") { reviewed = false; onStale() }
        }
    }
    val ownerCheck = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) scope.launch { sign(); signing = false } else signing = false
    }
    LayerScaffold(tr("firm.signoff.title", mapOf("n" to version.n)), tr("common.cancel"), { if (!signing) onCancel() }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
            Text(FirmText.title(matter.client, matter.company, matter.template?.text ?: FirmMarkdown.firstHeading(matter.latest?.markdown)), style = Fonts.heading(), color = Tk.L.fg)
            matter.template?.text?.let { Text(it, color = Tk.L.fgMuted) }
            SectionTitle(tr("firm.signoff.signer"))
            Column(Modifier.testTag("firm.signoff.signer")) {
                Text(signer?.name ?: "—", style = Fonts.body(), fontWeight = FontWeight.SemiBold, color = Tk.L.fg)
                signer?.detail?.let { Text(it, style = Fonts.small(), color = Tk.L.fgMuted) }
            }
            if (asks) for ((key, label) in listOf("title" to "firm.signoff.lawyerTitle", "firm" to "firm.signoff.firm", "admission" to "firm.signoff.admission")) {
                OutlinedTextField(details[key] ?: "", { details = details + (key to it) }, Modifier.fillMaxWidth().testTag("firm.signoff.$key"), placeholder = { Text(tr(label)) }, singleLine = true, enabled = !signing)
            }
            if (signer?.demo == true) Text(tr("firm.signoff.demo"), style = Fonts.small(), color = Tk.L.fgMuted)
            else if (asks) Text(tr("firm.signoff.firmHint"), style = Fonts.small(), color = Tk.L.fgMuted)
            Check(tr("firm.signoff.conflicts"), conflicts, "firm.signoff.conflicts") { conflicts = it }
            Check(tr("firm.signoff.engagement"), engagement, "firm.signoff.engagement") { engagement = it }
            Check(tr("firm.signoff.reviewed", mapOf("n" to version.n)), reviewed, "firm.signoff.reviewed") { reviewed = it }
            Text(tr("firm.signoff.footer"), style = Fonts.small(), color = Tk.L.fgMuted)
            error?.let { Text(it, color = Tk.S.failedText, modifier = Modifier.testTag("firm.signoff.error")) }
        }
        Button(onClick = {
            signing = true; error = null
            // Device-owner confirmation before an irreversible professional act; no screen lock means the confirmations alone (as on iOS).
            val intent = ownerCheckIntent(context, version.n)
            if (intent != null) ownerCheck.launch(intent) else scope.launch { sign(); signing = false }
        }, enabled = ready && !signing, modifier = Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).testTag("firm.signoff.confirm"),
            colors = ButtonDefaults.buttonColors(containerColor = Tk.L.accent)) {
            if (signing) CircularProgressIndicator(Modifier.size(20.dp), color = Tk.L.bg, strokeWidth = 2.dp)
            else Text(tr("firm.signoff.confirm", mapOf("n" to version.n)), fontWeight = FontWeight.SemiBold)
        }
    }
}

@Suppress("DEPRECATION")
private fun ownerCheckIntent(context: Context, version: Int): Intent? {
    val km = context.getSystemService(KeyguardManager::class.java) ?: return null
    if (!km.isDeviceSecure) return null
    return km.createConfirmDeviceCredentialIntent(tr("firm.signoff.title", mapOf("n" to version)), tr("firm.signoff.reason"))
}

@Composable
private fun Check(title: String, on: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).clickable { onChange(!on) }.testTag(tag), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
        Checkbox(checked = on, onCheckedChange = null, colors = CheckboxDefaults.colors(checkedColor = Tk.L.accent))
        Text(title, style = Fonts.body(), color = Tk.L.fg)
    }
}

/** Downloads a signed PDF from an allowlisted portal host only (no account credential sent) and shows it. */
@Composable
private fun FirmPdfLayer(url: String, scope: String?, onClose: () -> Unit) {
    val context = LocalContext.current
    var file by remember(url) { mutableStateOf<File?>(null) }
    var failed by remember(url) { mutableStateOf(false) }
    LaunchedEffect(url) {
        if (!FirmPortalLink.isPortalUrl(url)) { failed = true; return@LaunchedEffect }
        file = runCatching { withContext(Dispatchers.IO) { downloadPdf(context, FirmPortalLink.localize(url), scope) } }.getOrNull()
        failed = file == null
    }
    LayerScaffold(tr("firm.matter.pdf"), tr("common.close"), onClose, action = {
        file?.let { f -> TextButton(onClick = {
            val uri = FileProvider.getUriForFile(context, context.packageName + ".preview", f)
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/pdf").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            runCatching { context.startActivity(Intent.createChooser(view, tr("files.openWith"))) }
        }) { Text(tr("files.openWith"), color = Tk.L.accent) } }
    }) {
        when {
            file != null -> FilePreview(file!!, PreviewKind.Pdf, Modifier.fillMaxSize())
            failed -> Text(tr("firm.error.network"), color = Tk.S.failedText)
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Tk.L.accent) }
        }
    }
}

/**
 * Blocking; call on Dispatchers.IO. Saved under the preview FileProvider path (per account scope, so another account
 * never sees it; the whole folder is removed on sign-out, see [FirmPdf.folder]) so it can be opened in another app.
 * Redirects are not followed: only the allowlisted URL itself may serve the signed PDF.
 */
private fun downloadPdf(context: Context, url: String, scope: String?): File? {
    val dir = File(FirmPdf.folder(context.filesDir), scope ?: return null).apply { mkdirs() }
    val name = MessageDigest.getInstance("SHA-256").digest(url.toByteArray()).take(12).joinToString("") { "%02x".format(it) } + ".pdf"
    val body = FirmPdf.client.newCall(Request.Builder().url(url).get().build()).execute()
        .use { r -> if (r.isSuccessful && r.request.url.toString() == url) r.body?.bytes() else null } ?: return null
    if (!FirmPdf.looksLikePdf(body)) return null
    return File(dir, name).apply { writeBytes(body) }
}
