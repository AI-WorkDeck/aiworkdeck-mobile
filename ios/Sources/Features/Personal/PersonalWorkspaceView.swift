// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@MainActor @Observable
final class PersonalWorkspaceModel {
    var status: AssistantStatus?
    var calendar: PersonalCalendar?
    var messages: [PersonalMessage] = []
    var sources: [AssistantSource] = []
    var conversationID: String?
    var draft = ""
    var pending: PendingPersonalQuestion?
    var busy = false
    var loading = false
    var error: String?
    var calendarError: String?
    var service = PersonalWorkspaceService()
    private let storageScope = PersonalConversationStore.scope
    private var restored = false
    init() {
        if let saved = PersonalConversationStore.read(scope: storageScope) { conversationID = saved.conversationId; pending = saved.pending; draft = saved.pending?.message ?? "" }
#if DEBUG
        if PersonalUITestSeed.isOn { service = PersonalUITestSeed.service() }
#endif
    }
    func load() async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        await fetch()
        if !restored && status?.enabled == true { await restore() }
    }
    private func fetch() async {
        do {
            status = try await service.status(); error = nil
            if status?.consentEnabled == false { messages = []; sources = []; conversationID = nil; pending = nil; draft = ""; PersonalConversationStore.clear() }
        } catch is CancellationError { return } catch { self.error = error.localizedDescription }
        do {
            calendar = try await service.calendar(); calendarError = nil
            let allowed = calendar?.enabled == true && calendar?.subscriptionActive == true
            if allowed && CalendarReminders.shared.enabled { await CalendarRemotePush.shared.prepare() }
            if !allowed { CalendarRemotePush.shared.clear() }
            await CalendarReminders.shared.replace(allowed ? (calendar?.events ?? []) : [])
        } catch is CancellationError {} catch { calendarError = error.localizedDescription }
    }
    func send() async {
        guard !busy, status?.enabled == true else { return }
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        // Keep the same request UUID for retries, including after switching tabs.
        let question = pending?.message == message ? pending! : PendingPersonalQuestion(conversationId: conversationID, message: message)
        pending = question; save(); busy = true; error = nil
        defer { busy = false }
        do {
            let reply = try await service.ask(question)
            guard reply.requestId == question.requestId else { throw APIError(message: tr("error.badResponse")) }
            messages.append(PersonalMessage(role: "user", content: question.message, createdAt: question.requestId))
            messages.append(PersonalMessage(role: "assistant", content: reply.answer, createdAt: reply.requestId))
            conversationID = reply.conversationId; sources = reply.sources; pending = nil; draft = ""; save()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func save() { PersonalConversationStore.write(SavedPersonalConversation(conversationId: conversationID, pending: pending), scope: storageScope) }
    func newConversation() {
        guard !busy, pending == nil else { return }
        messages = []; sources = []; conversationID = nil; draft = ""; save()
    }
    private func restore() async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        do {
            if let question = pending {
                let reply = try await service.recover(question)
                let history = try await service.history(reply.conversationId)
                messages = history.messages; sources = reply.sources; conversationID = reply.conversationId; pending = nil; draft = ""; save()
            } else if let conversationID {
                messages = try await service.history(conversationID).messages
            }
            restored = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func configure(_ feature: String, enabled: Bool) async {
        guard !loading, !busy else { return }; loading = true
        defer { loading = false }
        do {
            try await service.configure(feature, enabled: enabled)
            if feature == "assistant" && !enabled { messages = []; sources = []; conversationID = nil; pending = nil; draft = ""; PersonalConversationStore.clear() }
            await fetch()
        }
        catch { if feature == "calendar" { calendarError = error.localizedDescription } else { self.error = error.localizedDescription }; loading = false }
    }
}

struct PersonalWorkspaceView: View {
    @Environment(AppModel.self) private var account
    @State private var model = PersonalWorkspaceModel()
    @State private var tab = "assistant"
    @State private var reminders = CalendarReminders.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { value in
            guard !CameraService.shared.isRecording, !CameraService.shared.isStartingRecording, !CameraService.shared.isCapturingPhoto else { return }
            tab = value
        })) {
            AssistantView(model: model).tabItem { Label(tr("personal.assistant"), systemImage: "bubble.left.and.bubble.right") }.tag("assistant")
            PersonalCalendarView(model: model).tabItem { Label(tr("personal.calendar"), systemImage: "calendar") }.tag("calendar")
            WorkspaceView().tabItem { Label(tr("workspace.title"), systemImage: "folder") }.tag("projects")
            CaptureFlowView(onClose: { tab = "projects" }).tabItem { Label(tr("workspace.capture"), systemImage: "camera") }.tag("capture")
        }
        .tint(T.L.accent)
        .task { await model.load(); if reminders.selectedEventID != nil { tab = "calendar" } }
        .onChange(of: reminders.selectedEventID) { _, value in if value != nil { tab = "calendar" } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.load() } } }
    }
}

private struct AssistantView: View {
    @Bindable var model: PersonalWorkspaceModel
    @State private var showConsent = false
    @State private var showSettings = false
    @State private var showBackup = false
    @FocusState private var inputFocused: Bool
    @State private var source: AssistantSource?
    @Environment(AppModel.self) private var account
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let status = model.status, !status.enabled || !status.subscriptionActive {
                    Text(status.subscriptionActive ? tr("personal.assistantConsent") : tr("personal.subscription")).font(.callout).foregroundStyle(.secondary)
                    if status.subscriptionActive && !status.backupEnabled { Button(tr("backup.title")) { showBackup = true } }
                    if !status.subscriptionActive { Button(tr("settings.account")) { showSettings = true } }
                    if status.subscriptionActive && status.backupEnabled { Button(tr("common.on")) { showConsent = true }.disabled(model.loading) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if model.messages.isEmpty {
                            Text(tr("personal.ask")).font(.title3).padding(.vertical, 32)
                            if let status = model.status { Text(tr("personal.summaries", ["count": String(status.summaryCount)])).font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(model.messages) { message in
                            Text(message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                .padding(12).background(message.role == "user" ? T.L.accent.opacity(0.08) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if !model.sources.isEmpty {
                            Text(tr("personal.sources")).font(.caption).foregroundStyle(.secondary)
                            ForEach(model.sources, id: \.self) { item in
                                Button { source = item } label: { VStack(alignment: .leading) { Text(item.projectName); if let date = PersonalDates.display(item.sourceUpdatedAt) { Text(date).font(.caption2) } } }
                            }
                        }
                        if model.busy { ProgressView(tr("personal.processing")) }
                    }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(T.S.failed); Button(tr("project.retry")) { Task { if model.pending != nil { await model.send() } else { await model.load() } } }.disabled(model.busy) }
                HStack(alignment: .bottom) {
                    TextField(tr("personal.ask"), text: $model.draft, axis: .vertical).lineLimit(1...5).focused($inputFocused).disabled(model.busy).accessibilityIdentifier("personal.input")
                    Button(tr("personal.send")) { inputFocused = false; Task { await model.send() } }.disabled(model.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.status?.enabled != true || model.status?.subscriptionActive != true).accessibilityIdentifier("personal.send")
                }.padding(12).background(T.L.bg).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding().navigationTitle(tr("personal.assistant")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").accessibilityLabel(tr("home.settings")) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(tr("personal.newChat")) { model.newConversation() }.disabled(model.busy || model.pending != nil)
                        if model.status?.enabled == true { Button(tr("common.off")) { Task { await model.configure("assistant", enabled: false) } }.disabled(model.loading || model.busy) }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(tr("personal.assistant")) }
                }
            }
            .alert(tr("personal.assistant"), isPresented: $showConsent) {
                Button(tr("common.ok")) { Task { await model.configure("assistant", enabled: true) } }; Button(tr("common.cancel"), role: .cancel) {}
            } message: { Text(tr("personal.assistantConsent")) }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await model.load() } }) { SettingsView(onClose: { showSettings = false }).environment(account) }
            .sheet(isPresented: $showBackup, onDismiss: { Task { await model.load() } }) { BackupConsentView().environment(account) }
            .sheet(isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } })) {
                if let source { NavigationStack { ProjectContentsView(project: source.project, client: account.workspaceFiles()).navigationTitle(source.projectName) } }
            }
        }
    }
}

private struct PersonalCalendarView: View {
    @Bindable var model: PersonalWorkspaceModel
    @State private var days = 3
    @State private var project = ""
    @State private var showConsent = false
    @State private var reminders = CalendarReminders.shared
    @State private var notificationError = false
    @State private var selected: PersonalCalendarEvent?
    @Environment(AppModel.self) private var account
    private var events: [PersonalCalendarEvent] { (model.calendar?.events ?? []).filter { $0.isWithin(days: days) && (project.isEmpty || $0.projectIdentity == project) }.sorted { ($0.dueDate + ($0.dueTime ?? "")) < ($1.dueDate + ($1.dueTime ?? "")) } }
    private var projects: [PersonalCalendarEvent] { var seen = Set<String>(); return (model.calendar?.events ?? []).filter { seen.insert($0.projectIdentity).inserted } }
    var body: some View {
        NavigationStack {
            List {
                if let calendar = model.calendar, !calendar.enabled || !calendar.subscriptionActive {
                    Text(calendar.subscriptionActive ? tr("personal.calendarConsent") : tr("personal.subscription"))
                    if calendar.subscriptionActive { Button(tr("common.on")) { showConsent = true }.disabled(model.loading) }
                }
                if model.calendar?.enabled == true {
                    Picker(tr("personal.calendar"), selection: $days) {
                        Text(tr("personal.today")).tag(1)
                        Text(tr("personal.nextDays", ["days": "3"])).tag(3)
                        Text(tr("personal.nextDays", ["days": "5"])).tag(5)
                    }.pickerStyle(.segmented)
                    Picker(tr("workspace.title"), selection: $project) {
                        Text(tr("personal.allProjects")).tag("")
                        ForEach(projects) { event in Text(event.projectName).tag(event.projectIdentity) }
                    }
                    Toggle(tr("personal.reminders"), isOn: Binding(get: { reminders.enabled }, set: { value in
                        Task { if value { notificationError = !((await reminders.allow())); await reminders.replace(model.calendar?.events ?? []) } else { reminders.clear() } }
                    }))
                    if !CalendarRemotePush.shared.registered { Text(tr("personal.remindersHint")).font(.caption).foregroundStyle(.secondary) }
                    if notificationError { Text(tr("personal.remindersUnavailable")).font(.caption).foregroundStyle(T.S.failed) }
                    if events.isEmpty { Text(tr("personal.noEvents")).foregroundStyle(.secondary) }
                    ForEach(events) { event in
                        Button { selected = event } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.title).font(.headline).foregroundStyle(.primary)
                                Text(event.dueDate + " " + (event.dueTime ?? "") + " · " + event.timeZone).font(.caption)
                                Text(event.projectName).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }.id(event.id)
                    }
                }
                if let error = model.calendarError { Text(error).foregroundStyle(T.S.failed); Button(tr("project.retry")) { Task { await model.load() } } }
                if model.loading { ProgressView() }
                if let sync = PersonalDates.display(model.calendar?.syncedAt) { Text(sync).font(.caption2).foregroundStyle(.secondary) }
            }.navigationTitle(tr("personal.calendar"))
            .toolbar {
                Button(tr("common.refresh")) { Task { await model.load() } }.disabled(model.loading)
                if model.calendar?.enabled == true { Button(tr("common.off")) { Task { await model.configure("calendar", enabled: false); reminders.clear() } }.disabled(model.loading) }
            }
            .refreshable { await model.load() }
            .alert(tr("personal.calendar"), isPresented: $showConsent) {
                Button(tr("common.ok")) { Task { await model.configure("calendar", enabled: true) } }; Button(tr("common.cancel"), role: .cancel) {}
            } message: { Text(tr("personal.calendarConsent")) }
            .task(id: reminders.selectedEventID) {
                if let id = reminders.selectedEventID {
                    if let event = model.calendar?.events.first(where: { $0.id == id }) { selected = event; reminders.selectedEventID = nil }
                    else { await model.load(); selected = model.calendar?.events.first(where: { $0.id == id }); reminders.selectedEventID = nil }
                }
            }
            .sheet(item: $selected) { event in
                NavigationStack {
                    List {
                        Text(event.title).font(.title2)
                        Text(event.dueDate + " " + (event.dueTime ?? "") + " · " + event.timeZone)
                        Text(event.projectName)
                        ForEach(event.files, id: \.fileId) { file in Text(file.fileName) }
                        NavigationLink(tr("project.files")) { ProjectContentsView(project: event.project, client: account.workspaceFiles()).navigationTitle(event.projectName) }
                    }.toolbar { Button(tr("common.close")) { selected = nil } }
                }
            }
        }
    }
}
