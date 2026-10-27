// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CryptoKit

struct SavedPersonalConversation: Codable {
    let conversationId: String?
    let pending: PendingPersonalQuestion?
}
/// Only the latest conversation reference and an unacknowledged question are stored locally.
/// Hashing the account scope avoids copying credentials into ordinary preferences.
enum PersonalConversationStore {
    static var scope: String? {
        guard let token = SessionStore.current else { return nil }
        return SHA256.hash(data: Data((Backend.baseURL.absoluteString + ":" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(scope expected: String?) -> SavedPersonalConversation? {
        guard let expected, expected == scope, let data = UserDefaults.standard.data(forKey: "personal.conversation." + expected) else { return nil }
        return try? JSONDecoder().decode(SavedPersonalConversation.self, from: data)
    }
    static func write(_ saved: SavedPersonalConversation, scope expected: String?) {
        guard let expected, expected == scope, let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: "personal.conversation." + expected)
    }
    static func clear() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("personal.conversation.") { UserDefaults.standard.removeObject(forKey: key) }
    }
}
