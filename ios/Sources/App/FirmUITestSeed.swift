// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
#if DEBUG
import Foundation

/// Debug-only: drives firm review against a local copy of the portal server (never production).
/// Launch with `-AWDFirmUITest -AWDFirmPortalBase http://127.0.0.1:<port>` plus the workspace seeds.
enum FirmUITestSeed {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-AWDFirmUITest") }
    static let session = "synthetic-firm-account"
    static let userID = 1778
    /// Where requests for an allowlisted portal host really go (local server).
    static var base: URL? {
        guard isOn, let s = UserDefaults.standard.string(forKey: "AWDFirmPortalBase"), let u = URL(string: s),
              ["127.0.0.1", "localhost"].contains(u.host ?? "") else { return nil }
        return u
    }
}
#endif
