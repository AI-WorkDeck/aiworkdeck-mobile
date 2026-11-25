// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A copy of the Keychain credentials (session, firm trial codes) in a protected, never-backed-up file.
///
/// Keychain items are bound to the Team ID. If the app is ever transferred to another developer team, the
/// first build signed by the new team can no longer read them and every user would be signed out. This
/// release only *writes* the copy; a later release (the first one signed by the new team) imports it.
/// Design: readiness/qa/Q17-publisher/ios-keychain-migration.md. The file always mirrors the Keychain:
/// it is updated on every save and clear, and removed when nothing is left in it.
enum AccountCarry {
    struct Payload: Codable, Equatable {
        var sessionId: String?
        var firmTrial: [String: String] = [:]
        var isEmpty: Bool { sessionId == nil && firmTrial.isEmpty }
    }

    /// Tests point this at a temporary directory.
    nonisolated(unsafe) static var directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AccountCarry", isDirectory: true)
    static var fileURL: URL { directory.appendingPathComponent("carry.json") }
    private static let lock = NSLock()

    static func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    static func setSession(_ value: String?) { update { $0.sessionId = value } }
    static func setFirmTrial(_ value: String?, scope: String) { update { $0.firmTrial[scope] = value } }

    /// Best effort: a failed write never blocks sign-in; the user is then just signed out once after a transfer.
    private static func update(_ change: (inout Payload) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var payload = read() ?? Payload()
        change(&payload)
        if payload.isEmpty { try? FileManager.default.removeItem(at: fileURL); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try JSONEncoder().encode(payload).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = fileURL
            try file.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
