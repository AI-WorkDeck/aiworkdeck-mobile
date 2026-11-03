// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import StoreKitTest

/// Real local StoreKit purchases with an explicitly synthetic API transport; no real charge or account.
final class SubscriptionFlowTests: XCTestCase {
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
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        XCTAssertFalse(try XCTUnwrap(session.allTransactions().first).autoRenewingEnabled)
        try session.forceRenewalOfSubscription(productIdentifier: "pro.monthly.cny.149")
        XCTAssertGreaterThanOrEqual(session.allTransactions().count, 2)
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
