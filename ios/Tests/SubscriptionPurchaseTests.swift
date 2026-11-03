// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class SubscriptionPurchaseTests: XCTestCase {
    func testProductsRouteSeparatelyFromConsumableCredits() {
        XCTAssertTrue(IAP.isSubscription(productId: "pro.monthly.cny.149"))
        XCTAssertFalse(IAP.isSubscription(productId: "credits.cny.50"))
        XCTAssertFalse(IAP.isSubscription(productId: "unknown.subscription"))
        XCTAssertFalse(ContractProducts.appstore.contains { IAP.isSubscription(productId: $0.productId) })
    }

    func testPrepareRequiresValidAccountToken() throws {
        let valid = Data(#"{"productId":"pro.monthly.cny.149","appAccountToken":"1D495761-A5F1-4DE4-9EB0-197225A06ABB"}"#.utf8)
        XCTAssertEqual(try API.decodeSubscriptionPurchase(status: 200, data: valid).productId, "pro.monthly.cny.149")
        XCTAssertThrowsError(try API.decodeSubscriptionPurchase(status: 200, data: Data(#"{"productId":"pro.monthly.cny.149","appAccountToken":"invalid"}"#.utf8)))
        XCTAssertThrowsError(try API.decodeSubscriptionPurchase(status: 200, data: Data(#"{"code":1,"message":"disabled"}"#.utf8)))
        XCTAssertThrowsError(try API.decodeSubscriptionPurchase(status: 401, data: valid))
    }

    func testOnlyExplicitConfirmationAllowsFinishing() throws {
        for status in ["PENDING", "REJECTED", "PAID", ""] {
            let data = try JSONSerialization.data(withJSONObject: ["status": status])
            XCTAssertFalse(try API.decodeSubscriptionConfirmation(status: 200, data: data).confirmed)
        }
        XCTAssertTrue(try API.decodeSubscriptionConfirmation(status: 200, data: Data(#"{"status":"CONFIRMED","subscription":{"active":true}}"#.utf8)).confirmed)
        XCTAssertThrowsError(try API.decodeSubscriptionConfirmation(status: 200, data: Data(#"{"code":1,"message":"not connected"}"#.utf8)))
        XCTAssertThrowsError(try API.decodeSubscriptionConfirmation(status: 503, data: Data(#"{"status":"CONFIRMED"}"#.utf8)))
    }
}
