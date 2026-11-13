// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.personal

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.aiworkdeck.mobile.R
import com.aiworkdeck.mobile.design.Segmented
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.aiworkdeck.mobile.Overlay
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.LightStatusBar
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.services.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class PersonalWorkspaceState(
    private val backend: Backend = ServiceLocator.backend.accountSnapshot(),
    private var conversationStore: PersonalConversationStore? = null,
) {
    var tab by mutableStateOf("assistant")
    var status by mutableStateOf<PersonalStatus?>(null)
    var calendar by mutableStateOf<PersonalCalendar?>(null)
    var conversationId: String? = null
    var pending: PersonalQuestion? = null
    val messages = mutableStateListOf<Pair<String, String>>()
    var sources by mutableStateOf<List<PersonalSource>>(emptyList())
    var draft by mutableStateOf("")
    var busy by mutableStateOf(false)
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var calendarError by mutableStateOf<String?>(null)
    var selected by mutableStateOf<PersonalCalendarEvent?>(null)
    var copyTargets by mutableStateOf<List<PersonalCopyDestination>?>(null)
    var copyNeedsUpgrade by mutableStateOf(false)
    var desktopCopy by mutableStateOf<PersonalDesktopCopy?>(null)
    private var recentDesktopCopies: List<DesktopCopyReceipt> = emptyList()
    var copySuccess by mutableStateOf(false)
    var reportConversationId by mutableStateOf<String?>(null)
    var reportDescription by mutableStateOf("")
    var reporting by mutableStateOf(false)
    var reportSubmitted by mutableStateOf(false)
    var reportError by mutableStateOf<String?>(null)
    var reportId by mutableStateOf<Long?>(null)
    var reportProgress by mutableStateOf<AssistantReport?>(null)
    var reportRefreshing by mutableStateOf(false)
    var reportProgressError by mutableStateOf<String?>(null)
    private var reportedConversationId: String? = null
    fun openReport() {
        if (reporting || conversationStore?.isCurrent() != true) return
        val id = conversationId ?: return
        if (reportedConversationId != id) {
            reportId = null; reportProgress = null; reportDescription = ""
        }
        reportConversationId = id
        reportSubmitted = reportId != null; reportError = null; reportProgressError = null
    }
    suspend fun submitReport() {
        val id = reportConversationId ?: return
        val store = conversationStore ?: return
        if (reporting || reportSubmitted || reportDescription.isBlank() || !store.isCurrent()) return
        reporting = true; reportError = null
        try {
            val submittedId = backend.reportAssistant(id, reportDescription)
            if (store.isCurrent() && reportConversationId == id) {
                reportId = submittedId; reportedConversationId = id; reportProgress = null
                reportProgressError = null; reportSubmitted = true
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (store.isCurrent() && reportConversationId == id) reportError = userFacingMessage(e) }
        finally { reporting = false }
    }
    suspend fun refreshReportProgress() {
        val id = reportId ?: return
        val store = conversationStore ?: return
        if (reportRefreshing || !store.isCurrent()) return
        reportRefreshing = true; reportProgressError = null
        try {
            val progress = backend.assistantReport(id) ?: throw ApiError(1, tr("error.badResponse"))
            if (store.isCurrent() && reportId == id) reportProgress = progress
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            if (store.isCurrent() && reportId == id) reportProgressError = userFacingMessage(e)
        } finally { reportRefreshing = false }
    }
    suspend fun prepareCopy() {
        if (busy || loading || pending != null || conversationId == null) return
        val store = conversationStore ?: return
        if (!store.isCurrent()) return
        loading = true; error = null; copySuccess = false; recentDesktopCopies = emptyList()
        try {
            val id = conversationId ?: return
            var desktopReady = false
            try {
                val recent = backend.personalDesktopCopies(id)
                if (!store.isCurrent() || conversationId != id) return
                recentDesktopCopies = recent
                val current = desktopCopy
                val restored = if (current == null) recent.firstOrNull() else recent.firstOrNull { it.requestId == current.request.requestId }
                if (restored != null) { desktopCopy = PersonalDesktopCopy(restored.request, restored); saveConversation() }
                desktopReady = true
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                if (!store.isCurrent()) return
                error = userFacingMessage(e)
            }
            val projects = backend.myProjects()
            if (store.isCurrent() && conversationId == id) {
                copyTargets = PersonalCopyDestination.targets(projects).filter { desktopReady || it.desktop == null }
                copyNeedsUpgrade = PersonalCopyDestination.needsUpgrade(projects)
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
        finally { loading = false }
    }
    suspend fun copyTo(project: RelayProject) {
        if (busy || loading || pending != null) return
        val id = conversationId ?: return
        val target = personalCopyTarget(project) ?: return
        val store = conversationStore ?: return
        if (!store.isCurrent()) return
        loading = true; error = null
        try {
            val result = backend.personalCopy(id, target)
            if (!store.isCurrent() || conversationId != id) return
            check(result.mode == "copy" && result.sourcePreserved && !result.filesCopied && result.sourceConversationId == id && result.targetProjectId == target) { tr("error.badResponse") }
            copySuccess = true; copyTargets = null
        } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
        finally { loading = false }
    }
    suspend fun copyTo(destination: PersonalCopyDestination) {
        val location = destination.desktop
        if (location == null) { copyTo(destination.project); return }
        if (!PersonalCopyDestination.eligible(location)) return
        val id = conversationId ?: return
        val existing = desktopCopy
        val request = existing?.request?.takeIf { it.sourceConversationId == id && it.targetProjectUid == location.projectUid &&
            it.targetDeviceId == location.deviceId && it.targetProjectKey == location.key && existing.receipt?.terminal != true }
            ?: recentDesktopCopies.firstOrNull { it.sourceConversationId == id && it.targetProjectUid == location.projectUid &&
                it.targetDeviceId == location.deviceId && it.targetProjectKey == location.key }?.takeUnless { it.terminal }?.request
            ?: DesktopCopyRequest(sourceConversationId = id, targetProjectUid = location.projectUid!!, targetDeviceId = location.deviceId, targetProjectKey = location.key)
        submitDesktopCopy(request)
    }
    suspend fun retryDesktopCopy() {
        val current = desktopCopy ?: return
        if (!current.canRetry) return
        val request = if (current.receipt?.terminal == true) current.request.copy(requestId = java.util.UUID.randomUUID().toString()) else current.request
        submitDesktopCopy(request)
    }
    private suspend fun submitDesktopCopy(request: DesktopCopyRequest) {
        val store = conversationStore ?: return
        if (busy || loading || pending != null || conversationId != request.sourceConversationId || !store.isCurrent()) return
        loading = true; error = null
        try {
            val previous = desktopCopy?.takeIf { it.request == request }
            desktopCopy = previous ?: PersonalDesktopCopy(request)
            check(store.save(PersonalConversation(conversationId, pending, desktopCopy))) { tr("error.network") }
            val receipt = backend.personalDesktopCopy(request)
            if (!store.isCurrent() || conversationId != request.sourceConversationId || desktopCopy?.request != request) return
            desktopCopy = PersonalDesktopCopy(request, receipt); saveConversation(); copyTargets = null
        } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
        finally { loading = false }
    }
    suspend fun refreshDesktopCopy() {
        val current = desktopCopy ?: return
        val store = conversationStore ?: return
        if (busy || loading || !store.isCurrent() || conversationId != current.request.sourceConversationId) return
        loading = true; error = null
        try {
            val receipt = backend.personalDesktopCopyStatus(current.request)
            if (!store.isCurrent() || desktopCopy?.request != current.request || conversationId != current.request.sourceConversationId) return
            desktopCopy = PersonalDesktopCopy(current.request, receipt); saveConversation()
        } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
        finally { loading = false }
    }
    private val operations = Mutex()
    private fun saveConversation() { conversationStore?.save(PersonalConversation(conversationId, pending, desktopCopy)) }
    fun newConversation() { desktopCopy = null; copySuccess = false; copyTargets = null; messages.clear(); sources = emptyList(); conversationId = null; pending = null; draft = ""; saveConversation() }
    internal suspend fun restoreConversation(store: PersonalConversationStore) {
        conversationStore = store
        if (!store.isCurrent()) return
        val saved = store.load()
        conversationId = saved.conversationId; pending = saved.pending; desktopCopy = saved.desktopCopy?.takeIf { it.request.sourceConversationId == conversationId }
        pending?.let { question ->
            draft = question.message; busy = true
            try {
                val reply = backend.personalRequest(question.requestId)
                if (!store.isCurrent() || pending?.requestId != question.requestId) return
                conversationId = reply.conversationId
                if (reply.status == "completed") { pending = null; draft = "" }
                else error = tr("error.network")
                saveConversation()
            } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
            finally { busy = false }
        }
        conversationId?.let { id ->
            try {
                val history = backend.personalHistory(id)
                if (!store.isCurrent() || conversationId != id || history.conversationId != id) return
                messages.clear(); messages.addAll(history.messages.map { it.role to it.content })
                sources = history.messages.lastOrNull { it.role == "assistant" }?.sources.orEmpty()
            } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
        }
    }
    suspend fun load(context: android.content.Context) = operations.withLock { fetch(context) }
    private suspend fun fetch(context: android.content.Context) {
        loading = true
        var restore = false
        try {
            try {
                status = backend.personalStatus(); error = null
                if (status?.consentEnabled == false) {
                    PersonalConversationStore.clear(context); conversationStore = null
                    desktopCopy = null; copyTargets = null; messages.clear(); sources = emptyList(); conversationId = null; pending = null; draft = ""
                } else if (status?.enabled == true && status?.canUseCloud == true) restore = true
                else { messages.clear(); sources = emptyList() }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = userFacingMessage(e) }
            try { calendar = backend.personalCalendar(); calendarError = null; CalendarReminders.replace(context, calendar?.takeIf { it.enabled && it.canReadCloud }?.events ?: emptyList()) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { calendarError = userFacingMessage(e) }
            if (restore && !busy) restoreConversation(conversationStore ?: PersonalConversationStore.open(context, backend))
        } finally { loading = false }
    }
    suspend fun configure(feature: String, enabled: Boolean, context: android.content.Context) = operations.withLock {
        loading = true
        try {
            backend.personalSettings(feature, enabled)
            if (feature == "assistant" && !enabled) {
                PersonalConversationStore.clear(context); conversationStore = null
                desktopCopy = null; copyTargets = null; messages.clear(); sources = emptyList(); conversationId = null; pending = null; draft = ""
            }
            fetch(context)
        }
        catch (e: CancellationException) { throw e } catch (e: Exception) { if (feature == "calendar") calendarError = userFacingMessage(e) else error = userFacingMessage(e) }
        finally { loading = false }
    }
    suspend fun send() {
        if (busy || loading || draft.isBlank() || status?.enabled != true || status?.canUseCloud != true) return
        val store = conversationStore ?: return
        if (!store.isCurrent()) return
        val question = pending?.takeIf { it.message == draft.trim() } ?: PersonalQuestion(conversationId, draft.trim())
        pending = question; saveConversation(); busy = true; error = null
        try {
            val reply = backend.personalChat(question)
            if (!store.isCurrent() || pending?.requestId != question.requestId) return
            check(reply.requestId == question.requestId && reply.status == "completed") { tr("error.network") }
            if (messages.lastOrNull() != ("user" to question.message)) messages.add("user" to question.message)
            messages.add("assistant" to reply.answer)
            sources = reply.sources; conversationId = reply.conversationId; pending = null; draft = ""; saveConversation()
        } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = userFacingMessage(e) }
        finally { busy = false }
    }
}

@Composable
/** 日程 / 助理两栏的内容；切哪一栏由外壳的底部栏决定（[tab] = "calendar" | "assistant"）。 */
fun PersonalWorkspaceScreen(state: PersonalWorkspaceState, tab: String, notificationEventId: String?, onOpen: (Overlay) -> Unit, onProject: (RelayProject) -> Unit) {
    state.tab = tab
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var consent by remember { mutableStateOf<String?>(null) }
    var days by remember { mutableStateOf(3) }
    var project by remember { mutableStateOf("") }
    var reminders by remember { mutableStateOf(CalendarReminders.enabled(context)) }
    var notificationError by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        notificationError = !granted; reminders = granted && CalendarReminders.enable(context)
        if (reminders) scope.launch { CalendarReminders.replace(context, state.calendar?.events ?: emptyList()) }
    }
    LaunchedEffect(Unit) { state.load(context) }
    LaunchedEffect(state.reportConversationId, state.reportId) {
        if (state.reportConversationId != null && state.reportId != null) state.refreshReportProgress()
    }
    LaunchedEffect(notificationEventId, state.calendar) {
        if (notificationEventId != null) { state.selected = state.calendar?.events?.find { it.id == notificationEventId } }
    }
    LightStatusBar()
    Column(Modifier.fillMaxSize().background(Tk.L.bg).safeDrawingPadding().padding(horizontal = Tk.Sp.gutter).imePadding()) {
        Row(Modifier.fillMaxWidth().heightIn(min = Tk.touchMin), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text(tr("personal." + state.tab), style = Fonts.title(), color = Tk.L.fg)
            TextButton(onClick = { onOpen(Overlay.Settings) }) { Text(tr("home.settings"), style = Fonts.body()) }
        }
        if (state.tab == "assistant") {
            state.status?.let { status ->
                if (!status.enabled || !status.canUseCloud) Notice(tr(if (status.canUseCloud) "personal.assistantConsent" else "postpaid.restricted")) {
                    if (status.canUseCloud && !status.backupEnabled) Link(tr("backup.title")) { onOpen(Overlay.Backup) }
                    if (!status.canUseCloud) Link(tr("settings.account")) { onOpen(Overlay.Settings) }
                    if (status.canUseCloud && status.backupEnabled) Link(tr("common.on")) { consent = "assistant" }
                }
            }
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s5), contentPadding = PaddingValues(vertical = Tk.Sp.s4)) {
                if (state.messages.isEmpty()) item {
                    Column(Modifier.padding(vertical = Tk.Sp.s8), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                        Text(tr("personal.ask"), style = Fonts.title(), color = Tk.L.fg)
                        Text(tr("personal.summaries", mapOf("count" to (state.status?.summaryCount ?: 0))), style = Fonts.small(), color = Tk.L.fgMuted)
                    }
                }
                items(state.messages) { message -> PersonalMessage(message.first, message.second) }
                if (state.sources.isNotEmpty()) item { Text(tr("personal.sources"), style = Fonts.nano(), color = Tk.L.fgMuted) }
                items(state.sources) { source ->
                    Column(Modifier.fillMaxWidth().heightIn(min = Tk.touchMin).clickable(role = Role.Button) { onProject(RelayProject(source.deviceId, null, source.projectKey, source.projectName)) }.padding(vertical = Tk.Sp.s1)) {
                        Text(source.projectName, style = Fonts.body(), color = Tk.L.accent)
                        personalSourceDate(source.sourceUpdatedAt).takeIf { it.isNotBlank() }?.let { Text(it, style = Fonts.micro(), color = Tk.L.fgMuted) }
                    }
                }
                if (state.busy) item {
                    Column(verticalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                        Text(tr("personal.processing"), style = Fonts.small(), color = Tk.L.fgMuted)
                        LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tk.L.accent, trackColor = Tk.L.sunken)
                    }
                }
            }
            state.error?.let { Row(verticalAlignment = Alignment.CenterVertically) {
                Text(it, style = Fonts.small(), color = Tk.S.failed, modifier = Modifier.weight(1f))
                Link(tr("project.retry"), !state.busy) { scope.launch { if (state.pending != null) { state.draft = state.pending!!.message; state.send() } else state.load(context) } }
            } }
            state.desktopCopy?.let { copy -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text(tr(copy.statusKey), style = Fonts.small(), color = Tk.L.fgMuted, modifier = Modifier.weight(1f))
                Link(tr("common.refresh"), !state.loading && !state.busy) { scope.launch { state.refreshDesktopCopy() } }
                if (copy.canRetry) Link(tr("project.retry"), !state.loading && !state.busy) { scope.launch { state.retryDesktopCopy() } }
            } }
            if (state.copySuccess) Text(tr("personal.copy.success"), style = Fonts.small(), color = Tk.L.fgMuted)
            Row(Modifier.fillMaxWidth().padding(vertical = Tk.Sp.s2), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                OutlinedTextField(value = state.draft, onValueChange = { state.draft = it }, enabled = !state.busy && !state.loading,
                    placeholder = { Text(tr("personal.ask"), style = Fonts.body()) }, textStyle = Fonts.body(), shape = RoundedCornerShape(22.dp),
                    modifier = Modifier.weight(1f), maxLines = 5)
                val canSend = !state.busy && !state.loading && state.draft.isNotBlank() && state.status?.canUseCloud == true
                Box(Modifier.size(Tk.touchMin + 4.dp).clip(CircleShape).background(if (canSend) Tk.L.accent else Tk.L.sunken)
                    .clickable(enabled = canSend, role = Role.Button, onClickLabel = tr("personal.send")) {
                        if (state.status?.enabled != true) consent = "assistant" else scope.launch { state.send() }
                    }.semantics { contentDescription = tr("personal.send") }, contentAlignment = Alignment.Center) {
                    Icon(painterResource(R.drawable.ic_send), contentDescription = null, tint = if (canSend) Tk.L.bg else Tk.L.fgFaint, modifier = Modifier.size(20.dp))
                }
            }
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s4)) {
                Link(tr("personal.newChat"), !state.busy && !state.loading && state.pending == null) { state.newConversation() }
                Link(tr("personal.copy.title"), !state.busy && !state.loading && state.pending == null && state.messages.isNotEmpty()) { scope.launch { state.prepareCopy() } }
                if (state.messages.any { it.first == "assistant" }) Link(tr("personal.report.conversation"), !state.reporting && state.conversationId != null) { state.openReport() }
                if (state.status?.enabled == true) Link(tr("common.off"), !state.busy && !state.loading, muted = true) { scope.launch { state.configure("assistant", false, context) } }
            }
        } else {
            val calendar = state.calendar
            if (calendar != null && (!calendar.enabled || !calendar.canReadCloud)) Notice(tr(if (calendar.canReadCloud) "personal.calendarConsent" else "postpaid.restricted")) {
                if (calendar.canWriteCloud) Link(tr("common.on")) { consent = "calendar" }
            }
            Row(Modifier.fillMaxWidth().padding(top = Tk.Sp.s2), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
                Segmented(listOf(1, 3, 5).map { it to (if (it == 1) tr("personal.today") else tr("personal.nextDays", mapOf("days" to it))) }, days,
                    modifier = Modifier.weight(1f)) { days = it }
                Link(tr("common.refresh")) { scope.launch { state.load(context) } }
            }
            var expanded by remember { mutableStateOf(false) }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    Row(Modifier.heightIn(min = Tk.touchMin).clickable(role = Role.Button) { expanded = true }, verticalAlignment = Alignment.CenterVertically) {
                        Text(calendar?.events?.find { it.projectIdentity == project }?.projectName ?: tr("personal.allProjects"), style = Fonts.body(), color = Tk.L.accent)
                        Icon(painterResource(R.drawable.ic_expand), contentDescription = null, tint = Tk.L.accent, modifier = Modifier.size(20.dp))
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        DropdownMenuItem(text = { Text(tr("personal.allProjects")) }, onClick = { project = ""; expanded = false })
                        calendar?.events?.distinctBy { it.projectIdentity }?.forEach { event -> DropdownMenuItem(text = { Text(event.projectName) }, onClick = { project = event.projectIdentity; expanded = false }) }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().heightIn(min = Tk.touchMin), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("personal.reminders"), style = Fonts.body(), color = Tk.L.fg, modifier = Modifier.weight(1f))
                Switch(checked = reminders, enabled = calendar?.enabled == true && calendar.canReadCloud, onCheckedChange = { on ->
                    if (!on) { CalendarReminders.clear(context); reminders = false }
                    else if (Build.VERSION.SDK_INT >= 33) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else { reminders = CalendarReminders.enable(context); notificationError = !reminders; scope.launch { CalendarReminders.replace(context, calendar?.events ?: emptyList()) } }
                })
            }
            Text(tr("personal.remindersHint"), style = Fonts.micro(), color = Tk.L.fgMuted)
            if (notificationError) Text(tr("personal.remindersUnavailable"), style = Fonts.small(), color = Tk.S.failed)
            HorizontalDivider(color = Tk.L.rule, modifier = Modifier.padding(top = Tk.Sp.s3))
            val events = calendar?.events.orEmpty().filter { it.within(days) && (project.isEmpty() || it.projectIdentity == project) }.sortedBy { it.dueDate + (it.dueTime ?: "") }
            LazyColumn(Modifier.weight(1f)) {
                if (events.isEmpty()) item { Text(tr("personal.noEvents"), style = Fonts.body(), color = Tk.L.fgMuted, modifier = Modifier.padding(vertical = Tk.Sp.s8)) }
                items(events, key = { it.id }) { event ->
                    Column(Modifier.fillMaxWidth().clickable(role = Role.Button) { state.selected = event }.padding(vertical = Tk.Sp.s3), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
                        Text(event.title, style = Fonts.heading(), color = Tk.L.fg)
                        Text(event.dueDate + " " + (event.dueTime ?: "") + " · " + event.timeZone, style = Fonts.mono(Tk.Ty.small), color = Tk.L.fgMuted)
                        Text(event.projectName, style = Fonts.small(), color = Tk.L.fgMuted)
                    }
                    HorizontalDivider(color = Tk.L.rule)
                }
            }
            state.calendarError?.let { Text(it, style = Fonts.small(), color = Tk.S.failed) }
            if (calendar?.enabled == true) Link(tr("common.off"), muted = true) { scope.launch { state.configure("calendar", false, context); CalendarReminders.clear(context); reminders = false } }
        }
    }
    if (state.reportConversationId != null) {
        AlertDialog(onDismissRequest = { if (!state.reporting) state.reportConversationId = null },
            title = { Text(tr("personal.report.conversation")) },
            text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.reportSubmitted) {
                    Text(tr("personal.report.sent"))
                    state.reportProgress?.let { progress ->
                        Text(tr(if (progress.resolved) "personal.report.resolved" else "personal.report.processing"))
                        val response = progress.reporterResponse?.takeIf { it.isNotBlank() }
                        if (response == null) Text(tr("personal.report.noResponse"))
                        else {
                            Text(tr("personal.report.response"), style = MaterialTheme.typography.titleSmall)
                            Text(response)
                            progress.responsePublishedAt?.let { published ->
                                Text(tr("personal.report.responsePublishedAt", mapOf("time" to personalSourceDate(published).ifBlank { published })))
                            }
                        }
                    }
                    if (state.reportRefreshing) { Text(tr("common.loading")); LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    state.reportProgressError?.let { Text(it, color = Tk.S.failed) }
                } else {
                    Text(tr("personal.report.privacy"))
                    OutlinedTextField(value = state.reportDescription, onValueChange = { state.reportDescription = it.take(2000) },
                        enabled = !state.reporting, label = { Text(tr("personal.report.reason")) }, maxLines = 5)
                    if (state.reporting) { Text(tr("personal.processing")); LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    state.reportError?.let { Text(it, color = Tk.S.failed) }
                }
            } },
            confirmButton = {
                if (state.reportSubmitted) TextButton(onClick = { scope.launch { state.refreshReportProgress() } },
                    enabled = !state.reportRefreshing) { Text(tr("personal.report.refreshProgress")) }
                else TextButton(onClick = { scope.launch { state.submitReport() } },
                    enabled = !state.reporting && state.reportDescription.isNotBlank()) { Text(tr("personal.send")) }
            },
            dismissButton = { TextButton(enabled = !state.reporting, onClick = { state.reportConversationId = null }) {
                Text(tr(if (state.reportSubmitted) "common.close" else "common.cancel"))
            } })
    }
    state.copyTargets?.let { targets ->
        AlertDialog(onDismissRequest = { if (!state.loading) state.copyTargets = null },
            title = { Text(tr("personal.copy.title")) },
            text = { Column { Text(tr("personal.copy.hint")); if (state.copyNeedsUpgrade) Text(tr("personal.copy.upgrade")); state.error?.let { Text(it, color = Tk.S.failed) }; if (targets.isEmpty()) Text(tr("project.emptyTitle")); LazyColumn { items(targets) { target -> TextButton(enabled = !state.loading, onClick = { scope.launch { state.copyTo(target) } }) { Text(target.label) } } } } },
            confirmButton = {}, dismissButton = { TextButton(enabled = !state.loading, onClick = { state.copyTargets = null }) { Text(tr("common.cancel")) } })
    }
    consent?.let { feature -> AlertDialog(onDismissRequest = { consent = null }, title = { Text(tr("personal." + feature)) }, text = { Text(tr("personal." + feature + "Consent")) }, confirmButton = { TextButton(onClick = { consent = null; scope.launch { state.configure(feature, true, context) } }) { Text(tr("common.ok")) } }, dismissButton = { TextButton(onClick = { consent = null }) { Text(tr("common.cancel")) } }) }
    state.selected?.let { event -> AlertDialog(onDismissRequest = { state.selected = null }, title = { Text(event.title) }, text = { Column { Text(event.dueDate + " " + (event.dueTime ?: "") + " · " + event.timeZone); Text(event.projectName); event.files.forEach { Text(it.fileName) } } }, confirmButton = { TextButton(onClick = { state.selected = null; onProject(RelayProject(event.deviceId, null, event.projectKey, event.projectName, event.projectUid)) }) { Text(tr("project.files")) } }, dismissButton = { TextButton(onClick = { state.selected = null }) { Text(tr("common.close")) } }) }
}

/** 浅底提示块：说明 + 一排操作。 */
@Composable
private fun Notice(text: String, actions: @Composable RowScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = Tk.Sp.s2).clip(RoundedCornerShape(10.dp)).background(Tk.L.sunken).padding(Tk.Sp.s3), verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
        Text(text, style = Fonts.small(), color = Tk.L.fg)
        Row(horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s4), content = actions)
    }
}

/** 文字操作：品牌色、至少一个触摸高度。 */
@Composable
private fun Link(text: String, enabled: Boolean = true, muted: Boolean = false, onClick: () -> Unit) {
    Text(text, style = Fonts.small(), color = if (!enabled) Tk.L.fgFaint else if (muted) Tk.L.fgMuted else Tk.L.accent,
        modifier = Modifier.heightIn(min = Tk.touchMin).clickable(enabled = enabled, role = Role.Button, onClick = onClick).wrapContentHeight())
}
