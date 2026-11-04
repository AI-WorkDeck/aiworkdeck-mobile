// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct CloudAccess: Decodable, Sendable {
    let canUse: Bool
    let canWrite: Bool
    let canRead: Bool
    let reason: String
    let epoch: Int64?
    let includedStorageBytes: Int64?
    let caseId: String?
    let cleanupEligible: Bool?
    let notificationStatus: String?
    let frozen: Bool?
    let cleanupState: String?
}
