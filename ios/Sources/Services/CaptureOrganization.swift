// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CryptoKit

struct CaptureOrganization: Codable, Sendable {
    let state: String
    var originalName: String? = nil
    var fileName: String? = nil
    var archiveName: String? = nil
    var tags: [String] = []
    var caption: String { tr("organize." + (state == "ready" ? "ready" : state == "needs_review" ? "review" : state == "unknown" ? "unknown" : "notApplied")) }
}

enum CaptureOrganizationStore {
    static func scope(baseURL: URL = Backend.baseURL, sessionID: String? = SessionStore.current) -> String? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AWDOrganizeUITest") { return "synthetic-ui-capture-organization" }
#endif
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return SHA256.hash(data: Data((baseURL.absoluteString + ":" + sessionID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func enabled(scope: String? = scope()) -> Bool {
        guard let scope else { return false }
        return UserDefaults.standard.bool(forKey: "captureOrganize.enabled." + scope)
    }
    static func setEnabled(_ enabled: Bool, scope: String? = scope()) {
        guard let scope else { return }
        UserDefaults.standard.set(enabled, forKey: "captureOrganize.enabled." + scope)
    }
    static func removeResults(ids: [UUID]) {
        let suffixes = ids.map { "." + $0.uuidString.lowercased() }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("captureOrganize.result.") && suffixes.contains(where: { key.hasSuffix($0) }) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    static func clear(scope: String?) {
        guard let scope else { return }
        UserDefaults.standard.removeObject(forKey: "captureOrganize.enabled." + scope)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("captureOrganize.result." + scope + ".") { UserDefaults.standard.removeObject(forKey: key) }
    }
    static func save(_ result: CaptureOrganization, id: UUID, scope: String?) {
        guard let scope, let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: "captureOrganize.result." + scope + "." + id.uuidString.lowercased())
    }
    static func result(id: UUID, scope: String? = scope()) -> CaptureOrganization? {
        guard let scope, let data = UserDefaults.standard.data(forKey: "captureOrganize.result." + scope + "." + id.uuidString.lowercased()) else { return nil }
        return try? JSONDecoder().decode(CaptureOrganization.self, from: data)
    }
}
