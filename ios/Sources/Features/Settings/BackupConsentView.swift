import SwiftUI

struct BackupConsentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var confirmDisable = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("backup.message"))
                    if let consent = model.backupConsent {
                        if !consent.subscriptionActive { Text(tr("backup.subscriptionRequired")) }
                        if consent.enabled {
                            Button(tr("backup.disable"), role: .destructive) { confirmDisable = true }
                                .accessibilityIdentifier("backup.disable")
                        } else if consent.subscriptionActive {
                            Button(tr("backup.enable")) { save(true) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("backup.enable")
                        }
                        if !consent.decided {
                            Button(tr("backup.decline")) { save(false) }
                                .accessibilityIdentifier("backup.decline")
                        }
                    } else {
                        Button(tr("project.retry")) { Task { await model.refreshBackupConsent() } }
                    }
                    if busy { ProgressView() }
                    if let error = model.backupError { Text(error).foregroundStyle(T.S.failed) }
                }.padding().disabled(busy)
            }
            .navigationTitle(tr("backup.title"))
            .toolbar {
                if model.backupConsent?.decided != false || model.backupError != nil {
                    Button(tr("common.close")) { dismiss() }.disabled(busy)
                }
            }
            .alert(tr("backup.disable"), isPresented: $confirmDisable) {
                Button(tr("common.cancel"), role: .cancel) {}
                Button(tr("backup.disable"), role: .destructive) { save(false) }
            } message: { Text(tr("backup.disableMessage")) }
        }
        .interactiveDismissDisabled(busy || (model.backupConsent?.decided == false && model.backupError == nil))
        .task { await model.refreshBackupConsent(promptIfNeeded: false) }
    }

    private func save(_ enabled: Bool) {
        busy = true
        Task {
            if await model.setBackupConsent(enabled: enabled) { dismiss() }
            busy = false
        }
    }
}
