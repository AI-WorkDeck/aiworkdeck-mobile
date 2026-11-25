// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// First-launch privacy consent, the same gate as Android's `PrivacyConsentScreen`: shown before the session is
/// restored or any permission is requested, and again whenever `privacyPolicyVersion` changes.
enum PrivacyConsent {
    static let key = "privacyConsentVersion"

    static func accepted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) == ContractCapabilities.privacyPolicyVersion
    }

    static func accept(in defaults: UserDefaults = .standard) {
        defaults.set(ContractCapabilities.privacyPolicyVersion, forKey: key)
    }

    /// Whether launch goes straight past the consent screen.
    static func initiallyAccepted(arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard) -> Bool {
#if DEBUG
        if arguments.contains(forceArgument) { return false }
#endif
        return accepted(in: defaults) || skipped(arguments: arguments)
    }

    /// UI tests and store screenshots start past the gate unless a test asks for it with `-AWDPrivacyConsentUITest`.
    /// Release builds never skip it.
    static func skipped(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
#if DEBUG
        if arguments.contains(forceArgument) { return false }
        return arguments.contains { $0.hasPrefix("-AWD") }
#else
        return false
#endif
    }

    static let forceArgument = "-AWDPrivacyConsentUITest"
}
