// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct ConversationCopyView: View {
    @Bindable var model: PersonalWorkspaceModel
    let files: any ProjectFilesServing
    let onClose: () -> Void
    let onCloudCopied: () -> Void
    @State private var targets: [PersonalCopyDestination] = []
    @State private var upgrade = false
    @State private var loading = true
    @State private var choosing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Text(tr("personal.copy.hint")).font(.footnote)
                if upgrade { Text(tr("personal.copy.upgrade")).font(.footnote) }
                if let error { Text(error).foregroundStyle(T.S.failed) }
                if loading { ProgressView() }
                if !loading && targets.isEmpty && !upgrade { Text(tr("project.emptyTitle")) }
                ForEach(targets) { target in
                    Button {
                        Task {
                            choosing = true
                            defer { choosing = false }
                            do {
                                if target.desktop != nil { try await model.queueDesktopCopy(target) }
                                else {
                                    guard let id = model.conversationID, !model.busy else { return }
                                    _ = try await model.service.copyConversation(id, to: target.project)
                                    onCloudCopied()
                                }
                                onClose()
                            } catch { self.error = target.desktop == nil ? error.localizedDescription : tr("personal.copy.unknown") }
                        }
                    } label: { VStack(alignment: .leading) { Text(target.project.name); Text(target.locationName).font(.caption) } }
                    .accessibilityIdentifier(target.desktop == nil ? "projectPicker.project.\(target.project.key)" : "personal.copy.desktop.\(target.desktop!.deviceId).\(target.desktop!.key)")
                }
            }
            .disabled(choosing)
            .navigationTitle(tr("personal.copy.title"))
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(tr("common.close"), action: onClose).disabled(choosing) } }
            .task {
                defer { loading = false }
                do { let projects = try await files.projects(); targets = PersonalCopyDestination.targets(projects); upgrade = PersonalCopyDestination.needsUpgrade(projects) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
