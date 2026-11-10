// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import StoreKitTest

/// Real local StoreKit purchases with an explicitly synthetic API transport; no real charge or account.
final class SubscriptionFlowTests: XCTestCase {
    /// Sales open but the Apple Account storefront has no product: name the region instead of a generic error.
    @MainActor
    func testMissingProductNamesAppStoreRegion() throws {
        let session = try SKTestSession(configurationFileNamed: "Workdeck")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.storefront = "HKG"
        session.locale = Locale(identifier: "zh_CN")
        let app = XCUIApplication()
        app.launchArguments = ["-AWDSubscriptionUITest", "-AWDSubscriptionMissingProduct"]
        app.launch()
        defer { app.terminate() }
        let message = app.staticTexts["subscription.unavailable"]
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        XCTAssertTrue(message.label.contains("HKG"), message.label)
        XCTAssertFalse(app.buttons["subscription.buy"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Subscription unavailable in App Store region"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMonthlyPurchaseAndRestore() throws {
        let session = try SKTestSession(configurationFileNamed: "Workdeck")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "CHN"
        session.locale = Locale(identifier: "zh_CN")
        defer { session.clearTransactions() }
        let app = XCUIApplication()
        app.launchArguments = ["-AWDSubscriptionUITest"]
        app.launch()
        defer { app.terminate() }
        let buy = app.buttons["subscription.buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 20))
        XCTAssertTrue(buy.isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists, "subscription fixture must not recover recording alerts")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Monthly subscription local StoreKit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        buy.tap()
        let result = app.staticTexts["subscription.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertEqual(result.label, "好")
        XCTAssertEqual(session.allTransactions().count, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["subscription.buy"].waitForExistence(timeout: 20))
        let restore = app.buttons["subscription.restore"]
        XCTAssertTrue(restore.isHittable)
        restore.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "好"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 20), .completed)
        XCTAssertEqual(session.allTransactions().count, 1)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        XCTAssertEqual(transaction.productIdentifier, "pro.monthly.cny.149")
        XCTAssertNotNil(transaction.expirationDate)
        XCTAssertTrue(transaction.autoRenewingEnabled)
        let originalIdentifier = transaction.identifier
        try session.forceRenewalOfSubscription(productIdentifier: "pro.monthly.cny.149")
        let renewed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            session.allTransactions().contains { $0.productIdentifier == transaction.productIdentifier
                && $0.identifier != originalIdentifier && $0.autoRenewingEnabled && $0.expirationDate != nil }
        }, object: nil)
        let renewalResult = XCTWaiter.wait(for: [renewed], timeout: 20)
        XCTAssertEqual(renewalResult, .completed, "Renewal must create a new subscription transaction")
        guard renewalResult == .completed else {
            let state = session.allTransactions().map {
                "\($0.productIdentifier): id=\($0.identifier), autoRenew=\($0.autoRenewingEnabled), expires=\(String(describing: $0.expirationDate))"
            }.joined(separator: "\n")
            let evidence = XCTAttachment(string: state)
            evidence.name = "Local StoreKit renewal state"
            evidence.lifetime = .keepAlways
            add(evidence)
            return
        }
        XCTAssertGreaterThanOrEqual(session.allTransactions().count, 2)
        let renewal = try XCTUnwrap(session.allTransactions().filter {
            $0.productIdentifier == transaction.productIdentifier && $0.identifier != originalIdentifier
        }.max { $0.purchaseDate < $1.purchaseDate })
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["subscription.buy"].waitForExistence(timeout: 20))
        app.buttons["subscription.restore"].tap()
        let restoredRenewal = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "好"), object: result)
        let restoredRenewalResult = XCTWaiter.wait(for: [restoredRenewal], timeout: 20)
        XCTAssertEqual(restoredRenewalResult, .completed)
        guard restoredRenewalResult == .completed else { return }
        try session.disableAutoRenewForTransaction(identifier: renewal.identifier)
        XCTAssertFalse(try XCTUnwrap(session.allTransactions().first {
            $0.identifier == renewal.identifier
        }).autoRenewingEnabled)
        try session.expireSubscription(productIdentifier: "pro.monthly.cny.149")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["subscription.buy"].waitForExistence(timeout: 20))
        app.buttons["subscription.restore"].tap()
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "没有未完成的购买"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 20), .completed)
    }

    @MainActor
    func testFailedConfirmationRemainsPendingAndCanRestoreAfterRestart() throws {
        let session = try SKTestSession(configurationFileNamed: "Workdeck")
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        session.storefront = "CHN"
        defer { session.clearTransactions() }
        let app = XCUIApplication()
        app.launchArguments = ["-AWDSubscriptionUITest", "-AWDSubscriptionConfirmFailure"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["subscription.buy"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["subscription.buy"].isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists, "subscription fixture must not recover recording alerts")
        app.buttons["subscription.buy"].tap()
        let result = app.staticTexts["subscription.result"]
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "购买已提交，正在确认到账…"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 20), .completed)
        XCTAssertEqual(session.allTransactions().count, 1)
        app.terminate()
        app.launchArguments = ["-AWDSubscriptionUITest"]
        app.launch()
        XCTAssertTrue(app.buttons["subscription.buy"].waitForExistence(timeout: 20))
        app.buttons["subscription.restore"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "好"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 20), .completed)
        XCTAssertEqual(session.allTransactions().count, 1)
    }
}
