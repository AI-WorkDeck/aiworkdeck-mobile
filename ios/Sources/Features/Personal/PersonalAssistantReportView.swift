// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct PersonalAssistantReport: Decodable {
    let id: Int64
    let status: String
    let aiContentReport: Bool?
    let reporterResponse: String?
    let responsePublishedAt: String?
}

@MainActor @Observable
final class PersonalAssistantReportModel: Identifiable {
    var id: String { conversationID }
    var description = ""
    private(set) var reportID: Int64?
    private(set) var progress: PersonalAssistantReport?
    private(set) var busy = false
    private(set) var error: String?
    private let conversationID: String
    private let service: PersonalWorkspaceService
    private let account: String?
    private let host: URL

    init(conversationID: String, service: PersonalWorkspaceService) {
        self.conversationID = conversationID; self.service = service
        account = service.sessionID(); host = service.baseURL()
    }
    private var isCurrent: Bool { account != nil && service.sessionID() == account && service.baseURL() == host }
    var canSubmit: Bool { !busy && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && description.count <= 2000 }

    func submit() async {
        guard canSubmit, reportID == nil, isCurrent else { return }
        busy = true; error = nil
        do {
            let id = try await service.reportAssistant(conversationID, description: description)
            guard isCurrent else { busy = false; return }
            reportID = id
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
        busy = false
        if reportID != nil { await refresh() }
    }
    func refresh() async {
        guard let id = reportID, !busy, isCurrent else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await service.assistantReport(id)
            guard isCurrent else { return }
            guard let result else { throw APIError(message: tr("error.badResponse")) }
            progress = result
        } catch is CancellationError {} catch { if isCurrent { self.error = error.localizedDescription } }
    }
}

struct PersonalAssistantReportView: View {
    @Bindable var model: PersonalAssistantReportModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if model.reportID != nil {
                    Text(tr("personal.report.sent")).accessibilityIdentifier("personal.reportSent")
                    if let progress = model.progress {
                        Text(tr(progress.status == "RESOLVED" ? "personal.report.resolved" : "personal.report.processing"))
                            .accessibilityIdentifier("personal.reportStatus")
                        if let response = progress.reporterResponse, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(tr("personal.report.response")).font(.headline)
                            Text(response).accessibilityIdentifier("personal.reportResponse")
                            if let time = progress.responsePublishedAt {
                                Text(tr("personal.report.responsePublishedAt", ["time": PersonalDates.display(time) ?? time])).font(.caption)
                            }
                        } else { Text(tr("personal.report.noResponse")) }
                    }
                    Button(tr("personal.report.refreshProgress")) { Task { await model.refresh() } }
                        .disabled(model.busy).accessibilityIdentifier("personal.reportRefresh")
                } else {
                    Text(tr("personal.report.privacy")).font(.callout)
                    TextField(tr("personal.report.reason"), text: $model.description, axis: .vertical)
                        .lineLimit(3...8).disabled(model.busy).accessibilityIdentifier("personal.reportReason")
                        .onChange(of: model.description) { _, value in
                            if value.count > 2000 { model.description = String(value.prefix(2000)) }
                        }
                    Button(tr("personal.send")) { Task { await model.submit() } }
                        .disabled(!model.canSubmit).accessibilityIdentifier("personal.reportSend")
                }
                if model.busy { ProgressView(tr("common.loading")) }
                if let error = model.error {
                    Text(error).foregroundStyle(T.S.failed).accessibilityIdentifier("personal.reportError")
                    Button(tr("project.retry")) { Task { if model.reportID == nil { await model.submit() } else { await model.refresh() } } }
                        .disabled(model.busy).accessibilityIdentifier("personal.reportRetry")
                }
            }
            .navigationTitle(tr("personal.report.conversation")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("common.close")) { dismiss() }.disabled(model.busy).accessibilityIdentifier("personal.reportClose")
                }
            }
            .interactiveDismissDisabled(model.busy)
            .task { if model.reportID != nil { await model.refresh() } }
        }
    }
}
