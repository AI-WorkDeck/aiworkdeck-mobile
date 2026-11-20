// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit
import LocalAuthentication

// MARK: - Reply: one sentence to the client, with three starters

struct FirmReplySheet: View {
    let matter: FirmMatter
    let send: (String) async -> Bool
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(matter: FirmMatter, send: @escaping (String) async -> Bool) { self.matter = matter; self.send = send }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: T.Sp.s3) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: T.Sp.s2) {
                        starter("firm.reply.question", "firm.reply.question.text")
                        starter("firm.reply.terms", "firm.reply.terms.text")
                        starter("firm.reply.callTime", "firm.reply.callTime.text")
                    }
                }
                TextField(tr("firm.reply.placeholder"), text: $text, axis: .vertical)
                    .lineLimit(4...12).font(.body).focused($focused)
                    .padding(T.Sp.s3).background(FirmColor.field, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("firm.reply.text")
                Spacer()
            }
            .padding(T.Sp.gutter)
            .navigationTitle(FirmText.who(matter.client, matter.company))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("firm.reply.send")) {
                        sending = true
                        Task { if await send(text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }; sending = false }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("firm.reply.send")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func starter(_ label: String, _ insert: String) -> some View {
        Button(tr(label)) { text = tr(insert) + text; focused = true }
            .font(T.F.small()).buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
}

// MARK: - Small fix: edit the latest text, save as the next version

struct FirmEditSheet: View {
    let version: FirmVersion
    let save: (String, String) async -> Bool
    @State private var markdown: String
    @State private var note = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(version: FirmVersion, save: @escaping (String, String) async -> Bool) {
        self.version = version; self.save = save
        _markdown = State(initialValue: version.markdown)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: T.Sp.s3) {
                TextField(tr("firm.edit.note"), text: $note).textFieldStyle(.roundedBorder).accessibilityIdentifier("firm.edit.note")
                TextEditor(text: $markdown).font(.callout).scrollContentBackground(.hidden)
                    .padding(T.Sp.s2).background(FirmColor.field, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("firm.edit.text")
            }
            .padding(T.Sp.gutter)
            .navigationTitle(tr("firm.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("firm.edit.save", ["n": String(version.n + 1)])) {
                        saving = true
                        Task { if await save(markdown, note) { dismiss() }; saving = false }
                    }
                    .disabled(saving || markdown == version.markdown)
                    .accessibilityIdentifier("firm.edit.save")
                }
            }
        }
        .interactiveDismissDisabled(markdown != version.markdown)
    }
}

// MARK: - Sign off: three confirmations, a name, then the device owner (Face ID / passcode)

struct FirmSignoffSheet: View {
    let matter: FirmMatter
    let version: FirmVersion
    let onSigned: (URL?) -> Void
    let onStale: () -> Void
    @State private var conflicts = false
    @State private var engagement = false
    @State private var reviewed = false
    @State private var name: String
    @State private var signing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(matter: FirmMatter, version: FirmVersion, defaultName: String, onSigned: @escaping (URL?) -> Void, onStale: @escaping () -> Void) {
        self.matter = matter; self.version = version; self.onSigned = onSigned; self.onStale = onStale
        _name = State(initialValue: defaultName)
    }

    static func ready(conflicts: Bool, engagement: Bool, reviewed: Bool, name: String) -> Bool {
        conflicts && engagement && reviewed && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var ready: Bool { Self.ready(conflicts: conflicts, engagement: engagement, reviewed: reviewed, name: name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(FirmText.who(matter.client, matter.company)).font(T.F.heading())
                    if let doc = matter.template?.text { Text(doc).foregroundStyle(Color.secondary) }
                }
                Section {
                    Toggle(tr("firm.signoff.conflicts"), isOn: $conflicts).accessibilityIdentifier("firm.signoff.conflicts")
                    Toggle(tr("firm.signoff.engagement"), isOn: $engagement).accessibilityIdentifier("firm.signoff.engagement")
                    Toggle(tr("firm.signoff.reviewed", ["n": String(version.n)]), isOn: $reviewed).accessibilityIdentifier("firm.signoff.reviewed")
                }
                .tint(FirmColor.accent)
                Section(tr("firm.signoff.name")) {
                    TextField(tr("firm.signoff.name"), text: $name).textContentType(.name).accessibilityIdentifier("firm.signoff.name")
                }
                if let error {
                    Section { Text(error).foregroundStyle(FirmColor.urgent).accessibilityIdentifier("firm.signoff.error") }
                }
                Section {
                    Button { Task { await sign() } } label: {
                        HStack { Spacer(); if signing { ProgressView() } else { Text(tr("firm.signoff.confirm", ["n": String(version.n)])).fontWeight(.semibold) }; Spacer() }
                    }
                    .disabled(!ready || signing)
                    .accessibilityIdentifier("firm.signoff.confirm")
                }
            }
            .navigationTitle(tr("firm.signoff.title", ["n": String(version.n)]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("common.cancel")) { dismiss() } } }
        }
        .interactiveDismissDisabled(signing)
    }

    private func sign() async {
        guard ready, let client = FirmPortal.shared.client else { return }
        signing = true; defer { signing = false }
        guard await FirmOwnerCheck.confirm(reason: tr("firm.signoff.reason")) else { return }
        do {
            let pdf = try await client.signoff(matter.id, version: version.n, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
            onSigned(pdf.flatMap(URL.init(string:)))
        } catch let e as FirmPortalError where e.code == "version_changed" {
            error = e.errorDescription
            reviewed = false
            onStale()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Device-owner confirmation before an irreversible professional act. Falls back to the passcode;
/// a device without any owner authentication relies on the explicit confirmations alone.
enum FirmOwnerCheck {
    nonisolated(unsafe) static var override: ((String) async -> Bool)?
    @MainActor static func confirm(reason: String) async -> Bool {
        if let override { return await override(reason) }
#if DEBUG
        if FirmUITestSeed.isOn { return true }
#endif
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: - PDF

struct FirmPDFSheet: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let document { FirmPDFKitView(document: document).ignoresSafeArea(edges: .bottom) }
                else if failed { Text(tr("firm.error.network")).foregroundStyle(FirmColor.urgent) }
                else { ProgressView() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("common.close")) { dismiss() } }
                if document != nil { ToolbarItem(placement: .primaryAction) { ShareLink(item: url) } }
            }
        }
        .task {
            guard FirmPortalLink.isPortalURL(url) else { failed = true; return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let d = PDFDocument(data: data) { document = d } else { failed = true }
            } catch { failed = true }
        }
    }
}

private struct FirmPDFKitView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.displayDirection = .vertical; v.document = document; return v
    }
    func updateUIView(_ v: PDFView, context: Context) { if v.document !== document { v.document = document } }
}

// MARK: - Conversation

struct FirmConversationSheet: View {
    let matter: FirmMatter
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Array(matter.transcript.filter { $0.role != "event" }.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(who(e)).font(T.F.nano()).foregroundStyle(e.role == "lawyer" ? FirmColor.accent : Color(.tertiaryLabel))
                    Text(FirmMarkdown.inline(e.content)).font(.callout).foregroundStyle(Color.primary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
            .navigationTitle(tr("firm.matter.conversation", ["count": String(matter.transcript.filter { $0.role != "event" }.count)]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("common.close")) { dismiss() } } }
        }
    }
    private func who(_ e: FirmTranscriptEntry) -> String {
        switch e.role {
        case "user": tr("firm.who.client")
        case "lawyer": e.name.flatMap { $0.isEmpty ? nil : $0 } ?? tr("firm.tab")
        default: tr("firm.who.assistant")
        }
    }
}

// MARK: - Join (Settings → Firm review)

struct FirmJoinView: View {
    @State private var portal = FirmPortal.shared
    @State private var link = ""
    @State private var trial = ""
    @State private var showTrial = false
    @State private var error: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if portal.portalID != nil, portal.access != .none, portal.access != .failed {
                    Section {
                        Text(statusText).accessibilityIdentifier("firm.join.status")
                        if let until = portal.me?.trialUntil { Text(tr("firm.trial.until", ["date": String(until.prefix(10))])).foregroundStyle(Color.secondary) }
                        if portal.access == .pending || portal.access == .checking {
                            Button(tr("firm.status.check")) { Task { await portal.check() } }
                        }
                        Button(tr("firm.leave"), role: .destructive) { portal.disconnect() }.accessibilityIdentifier("firm.leave")
                    }
                } else {
                    Section {
                        Text(tr("firm.join.body")).foregroundStyle(Color.secondary)
                        TextField(tr("firm.join.link"), text: $link)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("firm.join.link")
                        if showTrial {
                            SecureField(tr("firm.trial.code"), text: $trial).accessibilityIdentifier("firm.join.trial")
                        } else {
                            Button(tr("firm.trial.use")) { showTrial = true }.font(T.F.small())
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(FirmColor.urgent).accessibilityIdentifier("firm.join.error") } }
                    Section {
                        Button { Task { await join() } } label: { HStack { Spacer(); if working { ProgressView() } else { Text(tr("firm.join.connect")).fontWeight(.semibold) }; Spacer() } }
                            .disabled(working || link.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("firm.join.connect")
                    }
                }
            }
            .navigationTitle(tr("firm.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("common.close")) { dismiss() } } }
        }
    }

    private var statusText: String {
        switch portal.access {
        case .pending, .checking: tr("firm.status.pending", ["firm": portal.firmName])
        case .revoked: tr("firm.status.revoked", ["firm": portal.firmName])
        default: tr("firm.status.approved", ["firm": portal.firmName])
        }
    }

    private func join() async {
        error = nil
        guard let id = FirmPortalLink.portal(from: link) else { error = tr("firm.join.badHost"); return }
        working = true; defer { working = false }
        if portal.scope == nil { await portal.restore(userID: nil) }
        error = await portal.connect(portal: id, trialCode: showTrial ? trial : nil)
    }
}
