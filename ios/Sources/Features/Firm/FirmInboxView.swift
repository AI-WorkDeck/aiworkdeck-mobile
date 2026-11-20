// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Reviews tab: what needs the lawyer first, then what is waiting, in progress, and done.
struct FirmInboxView: View {
    @State private var portal = FirmPortal.shared
    @State private var path: [String] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if portal.matters.isEmpty {
                    Text(tr("firm.inbox.empty"))
                        .font(T.F.body()).foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, T.Sp.s10)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("firm.inbox.empty")
                }
                ForEach(FirmInbox.grouped(portal.matters), id: \.0) { group, items in
                    Section {
                        ForEach(items) { m in
                            NavigationLink(value: m.id) { FirmMatterRow(matter: m) }
                                .accessibilityIdentifier("firm.row." + m.id)
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
            .navigationTitle(tr("firm.tab"))
            .navigationDestination(for: String.self) { id in FirmMatterView(id: id) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: T.Sp.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(FirmText.who(matter.client, matter.company))
                    .font(T.F.heading()).foregroundStyle(Color.primary).lineLimit(1)
                Spacer(minLength: T.Sp.s2)
                Text(FirmText.ago(matter.updatedAt)).font(T.F.micro()).foregroundStyle(Color(.tertiaryLabel))
            }
            if let doc = matter.template?.text, !doc.isEmpty {
                Text(doc).font(T.F.small()).foregroundStyle(Color.secondary).lineLimit(1)
            }
            HStack(spacing: T.Sp.s2) {
                if let reason = FirmInbox.reason(matter) {
                    FirmChip(text: tr(FirmInbox.reasonKey(reason)), color: reason == "call_requested" ? FirmColor.urgent : FirmColor.waiting)
                }
                if let n = matter.forLawyerCount, n > 0 {
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
    private static func adaptive(_ light: Color, _ dark: Color) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
    static let accent = adaptive(T.L.accent, T.S.arrivedOnDark)
    static let waiting = adaptive(T.S.waiting, T.S.waitingOnDark)
    static let urgent = adaptive(T.S.failed, Color(hex: 0xE07A6E))
    static let card = Color(.secondarySystemGroupedBackground)
    static let background = Color(.systemGroupedBackground)
    static let field = Color(.tertiarySystemFill)
}
