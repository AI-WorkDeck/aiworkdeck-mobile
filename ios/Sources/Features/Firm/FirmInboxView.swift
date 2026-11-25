// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Reviews tab: what needs the lawyer first, then what is waiting, in progress, and done.
struct FirmInboxView: View {
    @State private var portal = FirmPortal.shared
    @State private var path: [FirmMatterRef] = []
    /// Same account button as the Calendar and Assistant tabs, so firm links are managed without switching tabs (POLISH M20).
    @State private var showSettings = false
    @Environment(AppModel.self) private var account
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            List {
                switch FirmInbox.placeholder(hasMatters: !portal.matters.isEmpty, listed: portal.listed, failed: portal.loadError != nil) {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, T.Sp.s10)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("firm.inbox.loading")
                case .empty:
                    Text(tr("firm.inbox.empty"))
                        .font(T.F.body()).foregroundStyle(T.LD.fgMuted)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, T.Sp.s10)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("firm.inbox.empty")
                case nil:
                    EmptyView()
                }
                ForEach(FirmInbox.grouped(portal.matters), id: \.0) { group, items in
                    Section {
                        ForEach(items, id: \.uid) { m in
                            NavigationLink(value: FirmMatterRef(portal: m.linkID ?? "", id: m.id)) {
                                FirmMatterRow(matter: m, firm: portal.links.count > 1 ? portal.link(m.linkID)?.firmName : nil, heading: portal.link(m.linkID)?.headings[m.id])
                            }
                                .accessibilityIdentifier("firm.row." + m.id)
                                .listRowBackground(T.LD.surface)
                        }
                    } header: {
                        Text(tr(Self.titleKey(group)))
                    }
                }
                if let error = portal.loadError {
                    Text(error).font(T.F.small()).foregroundStyle(FirmColor.urgent).listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .paperList()
            .navigationTitle(tr("firm.tab"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { AccountAvatar() }
                        .accessibilityLabel(tr("home.settings"))
                        .accessibilityIdentifier("firm.settings")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await portal.refresh() } }) {
                SettingsView(onClose: { showSettings = false }).environment(account)
            }
            .navigationDestination(for: FirmMatterRef.self) { ref in FirmMatterView(ref: ref) }
            .refreshable { await portal.refresh() }
            // Polls while the tab is on screen; instant delivery needs the server push (see the spec).
            .task {
                while !Task.isCancelled {
                    await portal.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await portal.refresh() } } }
        }
        .tint(FirmColor.accent)
    }

    static func titleKey(_ g: FirmInbox.Group) -> String {
        switch g {
        case .needsYou: "firm.inbox.needsYou"
        case .waiting: "firm.inbox.waiting"
        case .inProgress: "firm.inbox.inProgress"
        case .done: "firm.inbox.done"
        }
    }
}

struct FirmMatterRow: View {
    let matter: FirmMatterSummary
    /// Which firm, shown only when more than one portal is linked.
    var firm: String? = nil
    /// The draft's first heading when the matter has no client, company or template (FirmLink.headings).
    var heading: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: T.Sp.s1) {
            if let firm { Text(firm).font(T.F.micro()).foregroundStyle(T.LD.fgMuted).lineLimit(1) }
            HStack(alignment: .firstTextBaseline) {
                Text(FirmText.title(matter.client, matter.company, matter.template?.text ?? heading))
                    .font(T.F.heading()).foregroundStyle(T.LD.fg).lineLimit(1)
                Spacer(minLength: T.Sp.s2)
                Text(FirmText.ago(matter.updatedAt)).font(T.F.micro()).foregroundStyle(T.LD.fgMuted)
            }
            if let doc = matter.template?.text, !doc.isEmpty {
                Text(doc).font(T.F.small()).foregroundStyle(T.LD.fgMuted).lineLimit(1)
            }
            HStack(spacing: T.Sp.s2) {
                if let reason = FirmInbox.reason(matter) {
                    FirmChip(text: tr(FirmInbox.reasonKey(reason)), color: reason == "call_requested" ? FirmColor.urgent : FirmColor.waiting)
                }
                if let n = matter.forLawyerCount, n > 0, FirmInbox.group(matter) != .done {
                    FirmChip(text: tr("firm.forLawyerCount", ["count": String(n)]), color: FirmColor.accent)
                }
            }
        }
        .padding(.vertical, T.Sp.s1)
        .accessibilityElement(children: .combine)
    }
}

struct FirmChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(T.F.nano()).foregroundStyle(color)
            .padding(.horizontal, T.Sp.s2).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}

enum FirmText {
    /// "2" → "§2"; named sections stay as they are.
    static func section(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.first?.isNumber == true ? "§" + s : s
    }

    /// Who the matter is for; with no client or company, the document's name, else "—" (Android FirmText.title).
    static func title(_ client: String?, _ company: String?, _ document: String?) -> String {
        let w = who(client, company)
        if w != "—" { return w }
        if let document, !document.trimmingCharacters(in: .whitespaces).isEmpty { return document }
        return "—"
    }

    /// No client, company or document name: [title] would be "—".
    static func unnamed(_ client: String?, _ company: String?, _ document: String?) -> Bool { title(client, company, document) == "—" }

    /// The call line: with the proposed times when the client gave some, without a dangling separator otherwise.
    static func callLine(_ times: String?) -> String {
        if let times, !times.trimmingCharacters(in: .whitespaces).isEmpty { return tr("firm.matter.call", ["times": times]) }
        return tr("firm.reason.call")
    }

    static func who(_ client: String?, _ company: String?) -> String {
        let parts = [company, client].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func ago(_ iso: String) -> String {
        guard let d = date(iso) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        f.locale = Locale(identifier: L10n.locale)
        // A server clock slightly ahead must not read "in 0 seconds".
        let now = Date()
        return f.localizedString(for: min(d, now), relativeTo: now)
    }
}

/// Colors that follow light and dark mode (the Reviews tab is used at night as often as by day).
enum FirmColor {
    static let accent = T.LD.accent
    static let waiting = T.LD.pair(T.S.waiting, T.S.waitingOnDark)
    static let urgent = T.LD.pair(T.S.failed, Color(hex: 0xE07A6E))
    static let card = T.LD.surface
    static let background = T.LD.groupedPage
    static let field = T.LD.field
}
