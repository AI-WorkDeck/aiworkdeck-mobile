// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct PostpaidState: Decodable, Sendable {
    let billing: PostpaidBilling
    let cloudAccess: CloudAccess
}
struct PostpaidBilling: Decodable, Sendable {
    let policyVersion: String
    let accepted: Bool
    let acceptEnabled: Bool
    let unit: String
    let cashCurrency: String
    let creditLimitCents: Int64
    let debtCents: Int64
    let reservedCreditCents: Int64
    let availableCreditCents: Int64
    let overLimitAt: String?
    let remindAt: String?
    let cleanupAt: String?
    let storagePrice: StoragePrice
    let egressPrice: EgressPrice?
    struct StoragePrice: Decodable, Sendable { let cashCentsPerGiBMonth: Int64; let cashCurrency: String; let periodSeconds: Int64; let gibBytes: Int64 }
    struct EgressPrice: Decodable, Sendable { let cashCentsPerGiB: Int64; let cashCurrency: String; let gibBytes: Int64 }
}
