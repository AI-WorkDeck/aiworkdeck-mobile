// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// One matter, in the order a partner reads it: the client's list for the lawyer, how the red flags were
/// settled, what changed, the document; the conversation is one tap away.
struct FirmMatterView: View {
    let id: String
    @State private var portal = FirmPortal.shared
    @State private var matter: FirmMatter?
    @State private var error: String?
    @State private var sheet: Sheet?
    @State private var toast: String?
    @State private var showConversation = false
    @State private var confirmSendBack = false
    @State private var busy = false

    enum Sheet: Identifiable {
        case reply, edit, signoff, pdf(URL)
        var id: String {
            switch self {
            case .reply: "reply"
            case .edit: "edit"
            case .signoff: "signoff"
            case .pdf(let u): "pdf:" + u.absoluteString
            }
        }
    }

    var body: some View {
        ScrollView {
            if let m = matter {
                VStack(alignment: .leading, spacing: T.Sp.s6) {
                    header(m)
                    forLawyer(m)
                    flags(m)
                    changes(m)
                    document(m)
                    Button { showConversation = true } label: {
                        HStack {
                            Text(tr("firm.matter.conversation", ["count": String(m.transcript.filter { $0.role != "event" }.count)]))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                        .font(T.F.body()).frame(minHeight: T.touchMin)
                    }
                    .accessibilityIdentifier("firm.conversation")
                }
                .padding(.horizontal, T.Sp.gutter).padding(.vertical, T.Sp.s4)
            } else if let error {
                Text(error).font(T.F.body()).foregroundStyle(FirmColor.urgent).padding(T.Sp.s8)
            } else {
                ProgressView().padding(T.Sp.s16)
            }
        }
        .background(FirmColor.background)
        .navigationTitle(matter?.template?.text ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if let m = matter, !["signed", "closed"].contains(m.status) { actionBar(m) } }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(T.F.small()).padding(.horizontal, T.Sp.s4).padding(.vertical, T.Sp.s2)
                    .background(.regularMaterial, in: Capsule()).padding(.top, T.Sp.s2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("firm.toast")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $sheet) { s in
            switch s {
            case .reply:
                if let m = matter { FirmReplySheet(matter: m) { text in await act { try await $0.message(m.id, text: text, lawyer: portal.lawyerName) } done: { show(tr("firm.reply.sent")) } } }
            case .edit:
                if let m = matter, let v = m.latest { FirmEditSheet(version: v) { md, note in await act { _ = try await $0.saveVersion(m.id, markdown: md, note: note, lawyer: portal.lawyerName) } } }
            case .signoff:
                if let m = matter, let v = m.latest { FirmSignoffSheet(matter: m, version: v, defaultName: portal.lawyerName, onSigned: { url in
                    Task { await load(); await portal.refresh() }
                    if let url { sheet = .pdf(url) }
                }, onStale: { Task { await load() } }) }
            case .pdf(let url):
                FirmPDFSheet(url: url)
            }
        }
        .sheet(isPresented: $showConversation) { if let m = matter { FirmConversationSheet(matter: m) } }
        .confirmationDialog(tr("firm.sendBack"), isPresented: $confirmSendBack, titleVisibility: .visible) {
            Button(tr("firm.sendBack")) { Task { await act { try await $0.setStatus(id, status: "awaiting_client") } } }
        } message: { Text(tr("firm.sendBack.confirm")) }
    }

    // MARK: Sections

    private func header(_ m: FirmMatter) -> some View {
        VStack(alignment: .leading, spacing: T.Sp.s2) {
            Text(FirmText.who(m.client, m.company)).font(T.F.title()).foregroundStyle(Color.primary)
            if let name = m.lawyerName, !name.isEmpty {
                Text(tr("firm.matter.requestedLawyer", ["name": name])).font(T.F.small()).foregroundStyle(Color.secondary)
            }
            if let c = m.consult, c.status == "requested" || c.status == "scheduled" {
                HStack(spacing: T.Sp.s2) {
                    Image(systemName: "phone")
                    Text(c.status == "scheduled" ? tr("firm.matter.callScheduled") : tr("firm.matter.call", ["times": c.times ?? ""]))
                }
                .font(T.F.small()).foregroundStyle(c.status == "requested" ? FirmColor.urgent : FirmColor.accent)
                .accessibilityIdentifier("firm.call")
            }
        }
    }

    private func forLawyer(_ m: FirmMatter) -> some View {
        let items = m.forLawyer ?? []
        return section(tr("firm.matter.forLawyer") + (items.isEmpty ? "" : " · \(items.count)")) {
            if items.isEmpty {
                Text(tr("firm.matter.forLawyerEmpty")).font(T.F.body()).foregroundStyle(Color.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, q in
                HStack(alignment: .firstTextBaseline, spacing: T.Sp.s3) {
                    Text("\(i + 1)").font(T.F.mono(T.Ty.small, .semibold)).foregroundStyle(FirmColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        if let s = FirmText.section(q.section), !q.text.hasPrefix(q.section ?? "") {
                            Text(s).font(T.F.small().weight(.semibold)).foregroundStyle(Color.secondary)
                        }
                        Text(q.text).font(.body).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(T.Sp.s3).frame(maxWidth: .infinity, alignment: .leading)
                .background(FirmColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityIdentifier("firm.forLawyer")
    }

    @ViewBuilder private func flags(_ m: FirmMatter) -> some View {
        if let v = m.latest, let flags = v.notes?.flags, !flags.isEmpty {
            section(tr("firm.matter.flags") + " · " + tr("firm.matter.version", ["n": String(v.n)])) {
                ForEach(flags) { f in
                    let s = m.settlement(of: f)
                    HStack(alignment: .firstTextBaseline, spacing: T.Sp.s3) {
                        Circle().fill(f.level == "high" ? FirmColor.urgent : FirmColor.waiting).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text([FirmText.section(f.section), f.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(T.F.body()).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: T.Sp.s2)
                        FirmChip(text: tr(Self.settlementKey(s)), color: s == "lawyer" ? FirmColor.waiting : s == nil ? Color(.tertiaryLabel) : FirmColor.accent)
                    }
                }
            }
            .accessibilityIdentifier("firm.flags")
        }
    }

    static func settlementKey(_ s: String?) -> String {
        switch s {
        case "noted": "firm.flag.noted"
        case "kept": "firm.flag.kept"
        case "lawyer": "firm.flag.lawyer"
        default: "firm.flag.open"
        }
    }

    @ViewBuilder private func changes(_ m: FirmMatter) -> some View {
        if let v = m.latest {
            section(tr("firm.matter.changes", ["n": String(v.n)])) {
                if let prev = m.previous {
                    let notes = v.notes?.changes ?? []
                    ForEach(notes, id: \.self) { Text("• " + $0).font(T.F.body()).foregroundStyle(Color.primary) }
                    let edits = FirmDiff.edits(from: prev.markdown, to: v.markdown)
                    ForEach(Array(edits.prefix(12).enumerated()), id: \.offset) { _, e in
                        switch e {
                        case .removed(let t): Text(FirmMarkdown.plain(t)).strikethrough().foregroundStyle(FirmColor.urgent).font(T.F.small())
                        case .added(let t): Text(FirmMarkdown.plain(t)).foregroundStyle(FirmColor.accent).font(T.F.small())
                        case .same: EmptyView()
                        }
                    }
                } else {
                    Text(tr("firm.matter.firstVersion")).font(T.F.body()).foregroundStyle(Color.secondary)
                }
            }
            .accessibilityIdentifier("firm.changes")
        }
    }

    @ViewBuilder private func document(_ m: FirmMatter) -> some View {
        if let v = m.latest {
            VStack(alignment: .leading, spacing: T.Sp.s3) {
                HStack {
                    Eyebrow(text: tr("firm.matter.document") + " · " + tr("firm.matter.version", ["n": String(v.n)]))
                    Spacer()
                    if let s = v.pdfUrl, let url = URL(string: s) {
                        Button(tr("firm.matter.pdf")) { sheet = .pdf(url) }.font(T.F.small()).accessibilityIdentifier("firm.pdf")
                    }
                }
                FirmMarkdownView(markdown: v.markdown)
                    .padding(T.Sp.s4)
                    .background(FirmColor.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator)))
            }
        } else {
            section(tr("firm.matter.document")) { Text(tr("firm.matter.noDraft")).foregroundStyle(Color.secondary) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: T.Sp.s3) {
            Eyebrow(text: title)
            content()
        }
    }

    // MARK: Actions

    private func actionBar(_ m: FirmMatter) -> some View {
        HStack(spacing: T.Sp.s3) {
            Button { sheet = .reply } label: { Label(tr("firm.action.reply"), systemImage: "arrowshape.turn.up.left").frame(maxWidth: .infinity, minHeight: T.touchMin) }
                .buttonStyle(.bordered).accessibilityIdentifier("firm.reply")
            Menu {
                if m.consult?.status == "requested" { Button(tr("firm.call.confirm"), systemImage: "phone.badge.checkmark") { Task { await act { try await $0.consult(id, status: "scheduled") } } } }
                if m.consult?.status == "scheduled" { Button(tr("firm.call.done"), systemImage: "checkmark") { Task { await act { try await $0.consult(id, status: "done") } } } }
                if m.latest != nil { Button(tr("firm.edit.title"), systemImage: "pencil") { sheet = .edit } }
                if m.status != "awaiting_client" { Button(tr("firm.sendBack"), systemImage: "arrow.uturn.backward") { confirmSendBack = true } }
            } label: { Label(tr("firm.action.more"), systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: T.touchMin, height: T.touchMin) }
                .buttonStyle(.bordered).accessibilityIdentifier("firm.more").accessibilityLabel(tr("firm.action.more"))
            Button { sheet = .signoff } label: { Text(tr("firm.action.signoff")).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: T.touchMin) }
                .buttonStyle(.borderedProminent).disabled(m.latest == nil).accessibilityIdentifier("firm.signoff")
        }
        .controlSize(.large)
        .disabled(busy)
        .padding(.horizontal, T.Sp.gutter).padding(.vertical, T.Sp.s3)
        .background(.bar)
    }

    private func load() async {
        guard let client = portal.client else { error = tr("firm.error.access"); return }
        do { matter = try await client.matter(id); error = nil }
        catch { self.error = error.localizedDescription }
    }

    /// Runs one portal action, then reloads the matter (fresh state before any next step) and the inbox.
    @discardableResult
    private func act(_ work: (FirmPortalClient) async throws -> Void, done: (() -> Void)? = nil) async -> Bool {
        guard let client = portal.client else { return false }
        busy = true; defer { busy = false }
        do {
            try await work(client)
            await load(); await portal.refresh()
            done?()
            return true
        } catch {
            show(error.localizedDescription)
            await load()
            return false
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task { try? await Task.sleep(for: .seconds(2.5)); withAnimation { toast = nil } }
    }
}

// MARK: - Markdown (readable on a phone; headings, lists and emphasis)

enum FirmMarkdown {
    static func plain(_ block: String) -> String {
        block.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
    }
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct FirmMarkdownView: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: T.Sp.s3) {
            ForEach(Array(FirmDiff.paragraphs(markdown).enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("#") {
                    let level = block.prefix { $0 == "#" }.count
                    Text(FirmMarkdown.inline(String(block.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                        .font(level <= 1 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, T.Sp.s2)
                } else {
                    Text(FirmMarkdown.inline(block)).font(.body).lineSpacing(3)
                }
            }
        }
        .foregroundStyle(Color.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("firm.document")
    }
}
