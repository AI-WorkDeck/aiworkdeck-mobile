// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile.features.personal

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.aiworkdeck.mobile.Overlay
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
    private val operations = Mutex()
    private fun saveConversation() { conversationStore?.save(PersonalConversation(conversationId, pending)) }
    fun newConversation() { messages.clear(); sources = emptyList(); conversationId = null; pending = null; draft = ""; saveConversation() }
    internal suspend fun restoreConversation(store: PersonalConversationStore) {
        conversationStore = store
        if (!store.isCurrent()) return
        val saved = store.load()
        conversationId = saved.conversationId; pending = saved.pending
        pending?.let { question ->
            draft = question.message; busy = true
            try {
                val reply = backend.personalRequest(question.requestId)
                if (!store.isCurrent() || pending?.requestId != question.requestId) return
                conversationId = reply.conversationId
                if (reply.status == "completed") { pending = null; draft = "" }
                else error = tr("error.network")
                saveConversation()
            } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = e.message }
            finally { busy = false }
        }
        conversationId?.let { id ->
            try {
                val history = backend.personalHistory(id)
                if (!store.isCurrent() || conversationId != id || history.conversationId != id) return
                messages.clear(); messages.addAll(history.messages.map { it.role to it.content })
                sources = history.messages.lastOrNull { it.role == "assistant" }?.sources.orEmpty()
            } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = e.message }
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
                    messages.clear(); sources = emptyList(); conversationId = null; pending = null; draft = ""
                } else if (status?.enabled == true && status?.subscriptionActive == true) restore = true
                else { messages.clear(); sources = emptyList() }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
            try { calendar = backend.personalCalendar(); calendarError = null; CalendarReminders.replace(context, calendar?.takeIf { it.enabled && it.subscriptionActive }?.events ?: emptyList()) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { calendarError = e.message }
            if (restore && !busy) restoreConversation(conversationStore ?: PersonalConversationStore.open(context, backend))
        } finally { loading = false }
    }
    suspend fun configure(feature: String, enabled: Boolean, context: android.content.Context) = operations.withLock {
        loading = true
        try {
            backend.personalSettings(feature, enabled)
            if (feature == "assistant" && !enabled) {
                PersonalConversationStore.clear(context); conversationStore = null
                messages.clear(); sources = emptyList(); conversationId = null; pending = null; draft = ""
            }
            fetch(context)
        }
        catch (e: CancellationException) { throw e } catch (e: Exception) { if (feature == "calendar") calendarError = e.message else error = e.message }
        finally { loading = false }
    }
    suspend fun send() {
        if (busy || loading || draft.isBlank() || status?.enabled != true || status?.subscriptionActive != true) return
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
        } catch (e: CancellationException) { throw e } catch (e: Exception) { if (store.isCurrent()) error = e.message }
        finally { busy = false }
    }
}

@Composable
fun PersonalWorkspaceScreen(state: PersonalWorkspaceState, notificationEventId: String?, onOpen: (Overlay) -> Unit, onProject: (RelayProject) -> Unit) {
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
    LaunchedEffect(notificationEventId, state.calendar) {
        if (notificationEventId != null) { state.tab = "calendar"; state.selected = state.calendar?.events?.find { it.id == notificationEventId } }
    }
    Column(Modifier.fillMaxSize().background(Tk.L.bg).padding(16.dp).imePadding()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(tr("personal." + state.tab), style = MaterialTheme.typography.titleLarge, color = Tk.L.fg)
            TextButton(onClick = { onOpen(Overlay.Settings) }) { Text(tr("home.settings")) }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { state.tab = "assistant" }) { Text(tr("personal.assistant")) }
            TextButton(onClick = { state.tab = "calendar" }) { Text(tr("personal.calendar")) }
            TextButton(onClick = { onOpen(Overlay.Projects) }) { Text(tr("workspace.title")) }
            TextButton(onClick = { onOpen(Overlay.None) }) { Text(tr("workspace.capture")) }
        }
        if (state.tab == "assistant") {
            state.status?.let { status ->
                if (!status.enabled || !status.subscriptionActive) {
                    Text(tr(if (status.subscriptionActive) "personal.assistantConsent" else "personal.subscription"), color = Tk.L.fgMuted)
                    if (status.subscriptionActive && !status.backupEnabled) TextButton(onClick = { onOpen(Overlay.Backup) }) { Text(tr("backup.title")) }
                    if (!status.subscriptionActive) TextButton(onClick = { onOpen(Overlay.Settings) }) { Text(tr("settings.account")) }
                    if (status.subscriptionActive && status.backupEnabled) TextButton(onClick = { consent = "assistant" }) { Text(tr("common.on")) }
                }
            }
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                if (state.messages.isEmpty()) item { Text(tr("personal.ask"), style = MaterialTheme.typography.titleMedium, color = Tk.L.fg); Text(tr("personal.summaries", mapOf("count" to (state.status?.summaryCount ?: 0))), color = Tk.L.fgMuted) }
                items(state.messages) { message -> SelectionContainer { Text(message.second, color = Tk.L.fg, modifier = Modifier.fillMaxWidth().padding(12.dp)) } }
                if (state.sources.isNotEmpty()) item { Text(tr("personal.sources"), color = Tk.L.fgMuted) }
                items(state.sources) { source -> TextButton(onClick = { onProject(RelayProject(source.deviceId, null, source.projectKey, source.projectName)) }) { Text(source.projectName + " · " + personalSourceDate(source.sourceUpdatedAt)) } }
                if (state.busy) item { Text(tr("personal.processing"), color = Tk.L.fgMuted); LinearProgressIndicator(Modifier.fillMaxWidth()) }
            }
            state.error?.let { Text(it, color = Tk.S.failed); TextButton(onClick = { scope.launch { if (state.pending != null) { state.draft = state.pending!!.message; state.send() } else state.load(context) } }, enabled = !state.busy) { Text(tr("project.retry")) } }
            Row {
                OutlinedTextField(value = state.draft, onValueChange = { state.draft = it }, enabled = !state.busy && !state.loading, placeholder = { Text(tr("personal.ask")) }, modifier = Modifier.weight(1f), maxLines = 5)
                TextButton(onClick = { scope.launch { state.send() } }, enabled = !state.busy && !state.loading && state.draft.isNotBlank() && state.status?.enabled == true && state.status?.subscriptionActive == true) { Text(tr("personal.send")) }
            }
            Row {
                TextButton(onClick = { state.newConversation() }, enabled = !state.busy && !state.loading && state.pending == null) { Text(tr("personal.newChat")) }
                if (state.status?.enabled == true) TextButton(onClick = { scope.launch { state.configure("assistant", false, context) } }, enabled = !state.busy && !state.loading) { Text(tr("common.off")) }
            }
        } else {
            val calendar = state.calendar
            if (calendar != null && (!calendar.enabled || !calendar.subscriptionActive)) {
                Text(tr(if (calendar.subscriptionActive) "personal.calendarConsent" else "personal.subscription"), color = Tk.L.fgMuted)
                if (calendar.subscriptionActive) TextButton(onClick = { consent = "calendar" }) { Text(tr("common.on")) }
            }
            Row { for (n in listOf(1, 3, 5)) TextButton(onClick = { days = n }) { Text(if (n == 1) tr("personal.today") else tr("personal.nextDays", mapOf("days" to n))) }; TextButton(onClick = { scope.launch { state.load(context) } }) { Text(tr("common.refresh")) } }
            var expanded by remember { mutableStateOf(false) }
            Box {
                TextButton(onClick = { expanded = true }) { Text(calendar?.events?.find { it.projectIdentity == project }?.projectName ?: tr("personal.allProjects")) }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    DropdownMenuItem(text = { Text(tr("personal.allProjects")) }, onClick = { project = ""; expanded = false })
                    calendar?.events?.distinctBy { it.projectIdentity }?.forEach { event -> DropdownMenuItem(text = { Text(event.projectName) }, onClick = { project = event.projectIdentity; expanded = false }) }
                }
            }
            Row { Text(tr("personal.reminders"), color = Tk.L.fg, modifier = Modifier.weight(1f)); Switch(checked = reminders, enabled = calendar?.enabled == true && calendar.subscriptionActive, onCheckedChange = { on ->
                if (!on) { CalendarReminders.clear(context); reminders = false }
                else if (Build.VERSION.SDK_INT >= 33) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
                else { reminders = CalendarReminders.enable(context); notificationError = !reminders; scope.launch { CalendarReminders.replace(context, calendar?.events ?: emptyList()) } }
            }) }
            Text(tr("personal.remindersHint"), style = MaterialTheme.typography.bodySmall, color = Tk.L.fgMuted)
            if (notificationError) Text(tr("personal.remindersUnavailable"), color = Tk.S.failed)
            val events = calendar?.events.orEmpty().filter { it.within(days) && (project.isEmpty() || it.projectIdentity == project) }.sortedBy { it.dueDate + (it.dueTime ?: "") }
            LazyColumn(Modifier.weight(1f)) {
                if (events.isEmpty()) item { Text(tr("personal.noEvents"), color = Tk.L.fgMuted, modifier = Modifier.padding(vertical = 30.dp)) }
                items(events, key = { it.id }) { event -> TextButton(onClick = { state.selected = event }) { Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                    Text(event.title, style = MaterialTheme.typography.titleMedium, color = Tk.L.fg)
                    Text(event.dueDate + " " + (event.dueTime ?: "") + " · " + event.timeZone, color = Tk.L.fgMuted)
                    Text(event.projectName, color = Tk.L.fgMuted)
                } }; HorizontalDivider(color = Tk.L.rule) }
            }
            state.calendarError?.let { Text(it, color = Tk.S.failed) }
            if (calendar?.enabled == true) TextButton(onClick = { scope.launch { state.configure("calendar", false, context); CalendarReminders.clear(context); reminders = false } }) { Text(tr("common.off")) }
        }
    }
    consent?.let { feature -> AlertDialog(onDismissRequest = { consent = null }, title = { Text(tr("personal." + feature)) }, text = { Text(tr("personal." + feature + "Consent")) }, confirmButton = { TextButton(onClick = { consent = null; scope.launch { state.configure(feature, true, context) } }) { Text(tr("common.ok")) } }, dismissButton = { TextButton(onClick = { consent = null }) { Text(tr("common.cancel")) } }) }
    state.selected?.let { event -> AlertDialog(onDismissRequest = { state.selected = null }, title = { Text(event.title) }, text = { Column { Text(event.dueDate + " " + (event.dueTime ?: "") + " · " + event.timeZone); Text(event.projectName); event.files.forEach { Text(it.fileName) } } }, confirmButton = { TextButton(onClick = { state.selected = null; onProject(RelayProject(event.deviceId, null, event.projectKey, event.projectName, event.projectUid)) }) { Text(tr("project.files")) } }, dismissButton = { TextButton(onClick = { state.selected = null }) { Text(tr("common.close")) } }) }
}
