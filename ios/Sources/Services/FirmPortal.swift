// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CryptoKit
import Observation
import Security

// Firm review: a lawyer answers and signs off client matters from a firm's intake portal.
// Spec: docs/specs/2026-11-19-firm-review.md. The account session goes only to hosts in
// ContractCapabilities.firmPortals (host or host/office); a trial code (typed by the lawyer, never bundled) lives in the Keychain.

// MARK: - Wire models (lenient: the portal adds fields over time)

struct FirmMe: Decodable, Equatable {
    let kind: String
    let name: String?
    let status: String?
    let lawyerId: String?
    let trialUntil: String?
    let firm: FirmName?
    /// The firm's catalog name for this lawyer ({ en, zh }), set when the firm approves the account.
    let lawyerName: FirmName?
}

/// Text in several languages from the portal (`en`, `zh`, and optionally `zht`, `ja`, `ms`, ...).
/// Shown in the app language when present, else English, else Chinese, else anything.
struct FirmName: Decodable, Equatable, Hashable {
    let values: [String: String]
    init(en: String? = nil, zh: String? = nil) {
        values = [("en", en), ("zh", zh)].reduce(into: [:]) { if let v = $1.1 { $0[$1.0] = v } }
    }
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String?].self)
        values = raw.compactMapValues { $0 }.filter { !$0.value.isEmpty }
    }
    var en: String? { values["en"] }
    var zh: String? { values["zh"] }
    func text(locale: String) -> String {
        let keys: [String]
        switch locale {
        case "zh-Hant": keys = ["zht", "zh"]
        case let l where l.hasPrefix("zh"): keys = ["zh"]
        default: keys = [locale, String(locale.prefix(2))]
        }
        for k in keys + ["en", "zh"] { if let v = values[k] { return v } }
        return values.sorted { $0.key < $1.key }.first?.value ?? ""
    }
    var text: String { text(locale: L10n.locale) }
}

struct FirmConsult: Decodable, Equatable, Hashable {
    let status: String?
    let times: String?
    let note: String?
    let lawyerName: String?
}

struct FirmMatterSummary: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let status: String
    let updatedAt: String
    let template: FirmName?
    let client: String?
    let company: String?
    let versions: Int?
    let lawyerName: String?
    let consult: FirmConsult?
    let forLawyerCount: Int?
    let wantsCall: Bool?
    /// `review_requested` | `call_requested` | `client_replied`; older portals omit it (derived below).
    let attention: String?
}

struct FirmMatterList: Decodable {
    let serverTime: String?
    let matters: [FirmMatterSummary]
}

struct FirmFlag: Decodable, Equatable, Hashable, Identifiable {
    let id: String
    let level: String?
    let section: String?
    let title: String?
    let risk: String?
}

struct FirmVersionNotes: Decodable, Equatable, Hashable {
    let changes: [String]?
    let flags: [FirmFlag]?
}

struct FirmVersion: Decodable, Equatable, Hashable, Identifiable {
    let n: Int
    let markdown: String
    let by: String?
    let lawyer: String?
    let signed: Bool?
    let pdfUrl: String?
    let notes: FirmVersionNotes?
    var id: Int { n }
}

struct FirmForLawyer: Decodable, Equatable, Hashable {
    let text: String
    let section: String?
    let flag: String?
    let version: Int?
}

struct FirmTranscriptEntry: Decodable, Equatable, Hashable {
    let role: String
    let content: String
    let name: String?
    let at: String?
    let version: Int?
}

struct FirmSignoff: Decodable, Equatable, Hashable {
    let name: String?
    let version: Int?
    let at: String?
}

struct FirmMatter: Decodable, Equatable {
    let id: String
    let status: String
    let updatedAt: String
    let template: FirmName?
    let client: String?
    let company: String?
    let lawyerName: String?
    let consult: FirmConsult?
    let transcript: [FirmTranscriptEntry]
    let versions: [FirmVersion]
    let flagState: [String: [String: String]]?
    let forLawyer: [FirmForLawyer]?
    let signoff: FirmSignoff?

    var latest: FirmVersion? { versions.max { $0.n < $1.n } }
    var previous: FirmVersion? {
        guard let latest else { return nil }
        return versions.filter { $0.n < latest.n }.max { $0.n < $1.n }
    }
    /// How each red flag of the latest version was settled: `noted` (changed), `kept`, `lawyer`, or nil (open).
    func settlement(of flag: FirmFlag) -> String? {
        guard let latest else { return nil }
        return flagState?[String(latest.n)]?[flag.id]
    }
}

struct FirmSignoffResult: Decodable { let ok: Bool; let finalPdf: String? }
struct FirmVersionResult: Decodable { let ok: Bool; let n: Int }
struct FirmOK: Decodable { let ok: Bool }

// MARK: - Inbox grouping (pure, tested)

enum FirmInbox {
    enum Group: String, CaseIterable { case needsYou, waiting, inProgress, done }

    /// Why a matter needs the lawyer now, or nil.
    static func reason(_ m: FirmMatterSummary) -> String? {
        if let a = m.attention, ["review_requested", "call_requested", "client_replied"].contains(a) { return a }
        if m.attention == nil {
            if m.consult?.status == "requested" { return "call_requested" }
            if m.status == "review" { return "review_requested" }
        }
        return nil
    }

    static func group(_ m: FirmMatterSummary) -> Group {
        if ["signed", "closed"].contains(m.status) { return .done }
        if reason(m) != nil { return .needsYou }
        if m.status == "awaiting_client" { return .waiting }
        return .inProgress
    }

    static func grouped(_ list: [FirmMatterSummary]) -> [(Group, [FirmMatterSummary])] {
        Group.allCases.compactMap { g in
            let items = list.filter { group($0) == g }
            return items.isEmpty ? nil : (g, items)
        }
    }

    static func reasonKey(_ reason: String) -> String {
        switch reason {
        case "call_requested": "firm.reason.call"
        case "client_replied": "firm.reason.reply"
        default: "firm.reason.review"
        }
    }
}

// MARK: - Paragraph diff (pure, tested)

enum FirmDiff {
    enum Change: Equatable { case same(String), added(String), removed(String) }

    static func paragraphs(_ markdown: String) -> [String] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// LCS over paragraphs; returns the full edit script in document order.
    static func changes(from old: String, to new: String) -> [Change] {
        let a = paragraphs(old), b = paragraphs(new)
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [Change] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { out.append(.removed(a[i])); i += 1 }
            else { out.append(.added(b[j])); j += 1 }
        }
        while i < n { out.append(.removed(a[i])); i += 1 }
        while j < m { out.append(.added(b[j])); j += 1 }
        return out
    }

    /// Only what changed, with no unchanged paragraphs.
    static func edits(from old: String, to new: String) -> [Change] {
        changes(from: old, to: new).filter { if case .same = $0 { false } else { true } }
    }
}

// MARK: - Portal link

enum FirmPortalLink {
    /// A firm link (`https://host/office/...`) or a bare `host/office` → the allowlisted portal id (`host/office`).
    /// Only https; the office is the whole first path segment. A link to the site root resolves to `host/all`
    /// (all offices) when listed; any other unlisted segment (an event page, say) is refused.
    static func portal(from input: String, allowed: [String] = ContractCapabilities.firmPortals) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        if let first = url.path.split(separator: "/").first.map({ String($0).lowercased() }) {
            return allowed.contains(host + "/" + first) ? host + "/" + first : nil
        }
        if allowed.contains(host + "/all") { return host + "/all" }
        return allowed.contains(host) ? host : nil
    }

    /// Splits a portal id into its host and path prefix ("" or "/office").
    static func parts(_ portal: String) -> (host: String, prefix: String) {
        let p = portal.split(separator: "/", maxSplits: 1).map(String.init)
        return (p.first ?? "", p.count > 1 ? "/" + p[1] : "")
    }
}

extension FirmPortalLink {
    /// PDFs and other links from the portal open only when they point at an allowlisted https host.
    static func isPortalURL(_ url: URL) -> Bool {
#if DEBUG
        if let base = FirmUITestSeed.base, url.host == base.host, url.port == base.port { return true }
#endif
        return url.scheme == "https" && ContractCapabilities.firmPortals.map { parts($0).host }.contains(url.host ?? "")
    }
}

/// Keychain storage for a typed trial code, scoped per account. Never synced to iCloud.
enum FirmTrialStore {
    private static let service = "com.aiworkdeck.mobile.firm-trial"
#if DEBUG
    /// UI-test builds run unsigned, without a usable Keychain.
    nonisolated(unsafe) private static var memory: [String: String] = [:]
#endif
    static func read(scope: String) -> String? {
#if DEBUG
        if FirmUITestSeed.isOn { return memory[scope] }
#endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: scope, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, scope: String) -> Bool {
#if DEBUG
        if FirmUITestSeed.isOn { memory[scope] = value; return true }
#endif
        clear(scope: scope)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: scope, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func clear(scope: String) {
#if DEBUG
        if FirmUITestSeed.isOn { memory[scope] = nil; return }
#endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: scope]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Portal client

struct FirmPortalError: LocalizedError, Equatable {
    let code: String
    let status: Int
    var errorDescription: String? {
        switch code {
        case "version_changed": tr("firm.error.versionChanged")
        case "already_signed": tr("firm.error.alreadySigned")
        case "access_pending", "access_revoked", "unauthorized", "trial_expired": tr("firm.error.access")
        default: tr("firm.error.network")
        }
    }
}

/// Transport, injectable for tests and UI fixtures.
protocol FirmTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
struct URLSessionFirmTransport: FirmTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct FirmPortalClient: Sendable {
    /// Portal id from the contract: `host` or `host/office`.
    let portal: String
    let credential: String
    var transport: any FirmTransport = URLSessionFirmTransport()

    func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard ContractCapabilities.firmPortals.contains(portal) else { throw FirmPortalError(code: "host_not_allowed", status: 0) }
        let (host, prefix) = FirmPortalLink.parts(portal)
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = host; comps.path = prefix + "/api/portal/" + path
#if DEBUG
        if let base = FirmUITestSeed.base { comps.scheme = base.scheme; comps.host = base.host; comps.port = base.port }
#endif
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw FirmPortalError(code: "bad_url", status: 0) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, status): (Data, Int)
        do { (data, status) = try await transport.send(req) }
        catch { throw FirmPortalError(code: "network", status: 0) }
        guard (200..<300).contains(status) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw FirmPortalError(code: code ?? "http_\(status)", status: status)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw FirmPortalError(code: "bad_response", status: status) }
    }

    func me() async throws -> FirmMe { try await request("me") }
    func matters() async throws -> FirmMatterList { try await request("matters") }
    func matter(_ id: String) async throws -> FirmMatter { try await request("matter", query: [URLQueryItem(name: "id", value: id)]) }
    func message(_ id: String, text: String, lawyer: String) async throws {
        let _: FirmOK = try await request("matter/message", method: "POST", body: ["id": id, "text": text, "lawyer": lawyer])
    }
    func consult(_ id: String, status: String) async throws {
        let _: FirmOK = try await request("matter/consult", method: "POST", body: ["id": id, "status": status])
    }
    func setStatus(_ id: String, status: String) async throws {
        let _: FirmOK = try await request("matter/update", method: "POST", body: ["id": id, "status": status])
    }
    func saveVersion(_ id: String, markdown: String, note: String, lawyer: String) async throws -> Int {
        let r: FirmVersionResult = try await request("matter/version", method: "POST", body: ["id": id, "markdown": markdown, "note": note, "lawyer": lawyer])
        return r.n
    }
    func signoff(_ id: String, version: Int, name: String) async throws -> String? {
        let body: [String: Any] = ["id": id, "version": version, "name": name,
                                   "checks": ["conflicts": true, "engagement": true, "reviewed": true]]
        let r: FirmSignoffResult = try await request("matter/signoff", method: "POST", body: body)
        return r.finalPdf
    }
}

// MARK: - Connection state (per signed-in account)

@MainActor @Observable
final class FirmPortal {
    static let shared = FirmPortal()

    enum Access: Equatable { case none, checking, pending, approved, revoked, failed }
    private(set) var access: Access = .none
    /// Joined portal id (`host` or `host/office`).
    private(set) var portalID: String?
    private(set) var me: FirmMe?
    private(set) var matters: [FirmMatterSummary] = []
    private(set) var loadError: String?
    /// Portal error code of the last failed access check (e.g. `unauthorized`, `network`).
    private(set) var lastErrorCode: String?
    var transport: any FirmTransport = URLSessionFirmTransport()

    var firmName: String { me?.firm.map(\.text).flatMap { $0.isEmpty ? nil : $0 } ?? portalID ?? "" }
    var lawyerName: String {
        guard me?.kind == "lawyer" else { return "" }
        if let n = me?.lawyerName?.text, !n.isEmpty { return n }
        return me?.name ?? ""
    }
    var needsYouCount: Int { matters.filter { FirmInbox.group($0) == .needsYou }.count }
    var isTrial: Bool { me?.kind == "trial" }

    /// Account scope (region host + user id): a link or trial code saved by one account is never used by another.
    private(set) var scope: String?
    nonisolated static func accountScope(userID: Int, base: URL) -> String {
        SHA256.hash(data: Data((base.absoluteString + "#" + String(userID)).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var linkKey: String? { scope.map { "firm.link." + $0 } }

    private var session: String? {
#if DEBUG
        if FirmUITestSeed.isOn { return FirmUITestSeed.session }
#endif
        return SessionStore.current
    }

    var client: FirmPortalClient? {
        guard let portalID, let scope, let session else { return nil }
        return FirmPortalClient(portal: portalID, credential: FirmTrialStore.read(scope: scope) ?? session, transport: transport)
    }

    /// Restores the saved link for the current account and checks access. Offline at launch: stays hidden,
    /// retried on the next foreground.
    func restore(userID: Int?) async {
        reset()
        guard let session else { return }
        let base = Backend.baseURL
        var id = userID ?? 0
#if DEBUG
        if FirmUITestSeed.isOn { id = FirmUITestSeed.userID }
#endif
        // A restored session starts with a placeholder id 0, which must never become a scope
        // (it would be shared by every account on the device): ask the account server who this is.
        if id <= 0 { id = (try? await API.shared.verifiedAccount(sessionID: session, baseURL: base).id) ?? 0 }
        guard id > 0, self.session == session, Backend.baseURL == base else { return }
        scope = Self.accountScope(userID: id, base: base)
        guard let key = linkKey, let saved = UserDefaults.standard.string(forKey: key),
              ContractCapabilities.firmPortals.contains(saved) else { return }
        portalID = saved
        await check()
    }

    /// Joins a portal. Returns nil on success, otherwise the message to show.
    func connect(portal: String, trialCode: String? = nil) async -> String? {
        guard let key = linkKey, let scope else { return tr("firm.error.network") }
        lastErrorCode = nil
        if let code = trialCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            // Never fall back to sending the account session when the code could not be stored.
            guard FirmTrialStore.save(code, scope: scope) else { return tr("error.sessionSaveFailed") }
        } else {
            FirmTrialStore.clear(scope: scope)
        }
        portalID = portal
        UserDefaults.standard.set(portal, forKey: key)
        await check()
        if access == .failed || access == .none {
            let usedTrial = trialCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let message = usedTrial && ["unauthorized", "trial_expired"].contains(lastErrorCode ?? "") ? tr("firm.trial.invalid") : (loadError ?? tr("firm.error.network"))
            disconnect()
            return message
        }
        return nil
    }

    func check() async {
        guard let client else { access = .none; return }
        if access != .approved { access = .checking }
        do {
            let me = try await client.me()
            self.me = me
            switch me.status {
            case "revoked": access = .revoked
            case "pending": access = .pending
            default: access = .approved
            }
            if access == .approved { await refresh() } else { matters = [] }
        } catch let e as FirmPortalError {
            lastErrorCode = e.code
            if e.code == "access_revoked" { access = .revoked }
            else if e.code == "access_pending" { access = .pending }
            else if access == .checking { access = e.status == 0 && me != nil ? .approved : .failed }
            loadError = e.errorDescription
        } catch { access = .failed }
    }

    func refresh() async {
        guard access == .approved, let client else { return }
        do {
            matters = try await client.matters().matters
            loadError = nil
        } catch let e as FirmPortalError {
            if e.code == "access_revoked" { access = .revoked; matters = [] }
            loadError = e.errorDescription
        } catch { loadError = tr("firm.error.network") }
    }

    func disconnect() {
        if let key = linkKey { UserDefaults.standard.removeObject(forKey: key) }
        if let scope { FirmTrialStore.clear(scope: scope) }
        let keep = scope
        reset()
        scope = keep
    }

    /// Called on sign-out and account switch: forget in-memory state (stored links are account-scoped).
    func reset() {
        scope = nil; portalID = nil; me = nil; matters = []; access = .none; loadError = nil
    }
}
