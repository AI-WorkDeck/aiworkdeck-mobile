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
            .navigationTitle(FirmText.title(matter.client, matter.company, matter.template?.text ?? FirmMarkdown.firstHeading(matter.latest?.markdown)))
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
    let link: FirmLink?
    let onSigned: (URL?) -> Void
    let onStale: () -> Void
    @State private var conflicts = false
    @State private var engagement = false
    @State private var reviewed = false
    @State private var details: [String: String] = [:]
    @State private var signing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    static func ready(conflicts: Bool, engagement: Bool, reviewed: Bool, signer: FirmPortal.Signer?) -> Bool {
        conflicts && engagement && reviewed && signer != nil
    }
    private var signer: FirmPortal.Signer? { link?.signer(for: matter) }
    private var ready: Bool { Self.ready(conflicts: conflicts, engagement: engagement, reviewed: reviewed, signer: signer) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(FirmText.title(matter.client, matter.company, matter.template?.text ?? FirmMarkdown.firstHeading(matter.latest?.markdown))).font(T.F.heading())
                    if let doc = matter.template?.text { Text(doc).foregroundStyle(T.LD.fgMuted) }
                }.listRowBackground(T.LD.surface)
                // The signature is the signed-in identity: shown, not typed.
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signer?.name ?? "—").font(.body.weight(.semibold)).foregroundStyle(T.LD.fg)
                        if let detail = signer?.detail { Text(detail).font(.subheadline).foregroundStyle(T.LD.fgMuted) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("firm.signoff.signer")
                    if link?.asksDetails == true {
                        detail("title", tr("firm.signoff.lawyerTitle"), .jobTitle)
                        detail("firm", tr("firm.signoff.firm"), .organizationName)
                        detail("admission", tr("firm.signoff.admission"), nil)
                    }
                } header: {
                    Text(tr("firm.signoff.signer"))
                } footer: {
                    if signer?.demo == true { Text(tr("firm.signoff.demo")) }
                    else if link?.asksDetails == true { Text(tr("firm.signoff.firmHint")) }
                }.listRowBackground(T.LD.surface)
                // Attestations, not settings: checklist rows rather than switches.
                Section {
                    check(tr("firm.signoff.conflicts"), $conflicts, id: "firm.signoff.conflicts")
                    check(tr("firm.signoff.engagement"), $engagement, id: "firm.signoff.engagement")
                    check(tr("firm.signoff.reviewed", ["n": String(version.n)]), $reviewed, id: "firm.signoff.reviewed")
                } footer: {
                    Text(tr("firm.signoff.footer"))
                }.listRowBackground(T.LD.surface)
                if let error {
                    Section { Text(error).foregroundStyle(FirmColor.urgent).accessibilityIdentifier("firm.signoff.error") }.listRowBackground(T.LD.surface)
                }
            }
            .paperList()
            .safeAreaInset(edge: .bottom) {
                Button { Task { await sign() } } label: {
                    HStack(spacing: T.Sp.s2) {
                        if signing { ProgressView() } else {
                            Image(systemName: FirmOwnerCheck.symbol)
                            Text(tr("firm.signoff.confirm", ["n": String(version.n)])).fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: T.touchMin)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(FirmColor.accent)
                .disabled(!ready || signing)
                .accessibilityIdentifier("firm.signoff.confirm")
                .padding(.horizontal, T.Sp.gutter).padding(.vertical, T.Sp.s3)
                .background(.bar)
            }
            .navigationTitle(tr("firm.signoff.title", ["n": String(version.n)]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("common.cancel")) { dismiss() } } }
        }
        .interactiveDismissDisabled(signing)
        .onAppear { if details.isEmpty { details = link?.savedDetails ?? [:] } }
    }

    private func detail(_ key: String, _ label: String, _ content: UITextContentType?) -> some View {
        TextField(label, text: Binding(get: { details[key] ?? "" }, set: { details[key] = $0 }))
            .textContentType(content).submitLabel(.done)
            .accessibilityIdentifier("firm.signoff." + key)
    }

    private func check(_ title: String, _ on: Binding<Bool>, id: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: T.Sp.s3) {
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on.wrappedValue ? FirmColor.accent : T.LD.fgFaint)
                Text(title).foregroundStyle(T.LD.fg)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: on.wrappedValue)
    }

    private func sign() async {
        guard ready, let signer, let link, let client = link.client else { return }
        signing = true; defer { signing = false }
        guard await FirmOwnerCheck.confirm(reason: tr("firm.signoff.reason")) else { return }
        do {
            let given = link.asksDetails ? details.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : [:]
            let pdf = try await client.signoff(matter.id, version: version.n, name: signer.name, details: given)
            if link.asksDetails { link.savedDetails = given }
            dismiss()
            onSigned(pdf.flatMap(URL.init(string:)))
        } catch let e as FirmPortalError where e.code == "version_changed" {
            error = e.errorDescription
            reviewed = false
            onStale()
        } catch {
            self.error = userFacingMessage(for: error)
        }
    }
}

/// Device-owner confirmation before an irreversible professional act. Falls back to the passcode;
/// a device without any owner authentication relies on the explicit confirmations alone.
enum FirmOwnerCheck {
    nonisolated(unsafe) static var override: ((String) async -> Bool)?
    /// The glyph for the check that will follow (Face ID, Touch ID, Optic ID, or the passcode).
    @MainActor static var symbol: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock"
        }
    }
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
                ToolbarItem(placement: .cancellationAction) { Button(tr("common.close")) { dismiss() }.accessibilityIdentifier("firm.pdf.close") }
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
                    Text(who(e)).font(T.F.nano()).foregroundStyle(e.role == "lawyer" ? FirmColor.accent : T.LD.fgFaint)
                    Text(FirmMarkdown.inline(e.content)).font(.callout).foregroundStyle(T.LD.fg)
                }
                .padding(.vertical, 2)
                .listRowBackground(T.LD.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden).background(T.LD.surface)
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
                // Every linked portal stays visible, including one that can't be reached right now, so it can be retried or removed.
                ForEach(portal.links.filter { $0.access != .none }, id: \.portalID) { l in
                    Section {
                        Text(Self.status(l)).accessibilityIdentifier("firm.join.status")
                        if l.access == .failed { Text(tr("firm.error.network")).foregroundStyle(FirmColor.urgent) }
                        if let until = l.me?.trialUntil { Text(tr("firm.trial.until", ["date": String(until.prefix(10))])).foregroundStyle(T.LD.fgMuted) }
                        if [.pending, .checking, .failed].contains(l.access) {
                            Button(tr("firm.status.check")) { Task { await l.check() } }
                        }
                        Button(tr("firm.leave"), role: .destructive) { portal.disconnect(l.portalID) }.accessibilityIdentifier("firm.leave")
                    }.listRowBackground(T.LD.surface)
                }
                Section {
                    Text(tr("firm.join.body")).foregroundStyle(T.LD.fgMuted)
                    TextField(tr("firm.join.link"), text: $link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("firm.join.link")
                    if showTrial {
                        SecureField(tr("firm.trial.code"), text: $trial).accessibilityIdentifier("firm.join.trial")
                    } else {
                        Button(tr("firm.trial.use")) { showTrial = true }.font(T.F.small())
                    }
                } header: {
                    if !portal.links.isEmpty { Text(tr("firm.join.title")) }
                }.listRowBackground(T.LD.surface)
                if let error { Section { Text(error).foregroundStyle(FirmColor.urgent).accessibilityIdentifier("firm.join.error") }.listRowBackground(T.LD.surface) }
                Section {
                    Button { Task { await join() } } label: { HStack { Spacer(); if working { ProgressView() } else { Text(tr("firm.join.connect")).fontWeight(.semibold) }; Spacer() } }
                        .disabled(working || link.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("firm.join.connect")
                }.listRowBackground(T.LD.surface)
            }
            .paperList()
            .navigationTitle(tr("firm.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("common.close")) { dismiss() }.accessibilityIdentifier("firm.join.close") } }
        }
    }

    static func status(_ l: FirmLink) -> String {
        switch l.access {
        case .pending, .checking: tr("firm.status.pending", ["firm": l.firmName])
        case .revoked: tr("firm.status.revoked", ["firm": l.firmName])
        case .failed, .none: l.firmName
        default: tr("firm.status.approved", ["firm": l.firmName])
        }
    }

    private func join() async {
        error = nil
        guard let id = FirmPortalLink.portal(from: link) else { error = tr("firm.join.badHost"); return }
        working = true; defer { working = false }
        if portal.scope == nil { await portal.restore(userID: nil) }
        error = await portal.connect(portal: id, trialCode: showTrial ? trial : nil)
        if error == nil { link = ""; trial = ""; showTrial = false }
    }
}
