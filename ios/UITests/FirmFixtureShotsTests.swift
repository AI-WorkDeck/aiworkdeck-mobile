// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

/// Reviews tab screenshots for design review, with the in-process fixture (`-AWDFirmFixture`: a fictional firm,
/// synthetic matters, no server). The full journey against a real local portal is FirmReviewFlowTests.
final class FirmFixtureShotsTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    @MainActor private func shot(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The system appearance is set by the workflow (`simctl ui <device> appearance`), which passes it as
    /// AWD_APPEARANCE; XCUIDevice.appearance did not change the CI simulator (X review of #200).
    private var mode: String { ProcessInfo.processInfo.environment["AWD_APPEARANCE"] ?? "light" }

    @MainActor func testReviewsInboxAndMatter() throws {
        let app = try launchJoined()
        let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reviews"))
            .containing(NSPredicate(format: "identifier IN %@", ["signature"])).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        let review = app.buttons["firm.row.mtr-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        shot("Firm inbox \(mode)", app)

        review.tap()
        XCTAssertTrue(app.staticTexts["Is a $10M post-money cap reasonable for a seed robotics company?"].waitForExistence(timeout: 10))
        shot("Firm matter \(mode)", app)
        app.swipeUp()
        shot("Firm matter flags and changes \(mode)", app)
    }

    /// POLISH M42: Capture is dark by function; Calendar, Assistant and Reviews follow the system appearance.
    @MainActor func testPersonalTabsFollowTheSystemExceptCapture() throws {
        do {
            let app = try launchJoined()
            let reviews = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reviews"))
                .containing(NSPredicate(format: "identifier IN %@", ["signature"])).firstMatch
            for (name, tab) in [("Calendar", personalTab(app, .calendar)), ("Assistant", personalTab(app, .assistant)),
                                ("Reviews", reviews), ("Capture", personalTab(app, .capture))] {
                XCTAssertTrue(tab.waitForExistence(timeout: 15), name); tab.tap()
                Thread.sleep(forTimeInterval: 1)
                shot("Tab \(name) \(mode)", app)
            }
            // The switch out of the dark viewfinder and back: right after the tap, then settled.
            personalTab(app, .assistant).tap()
            shot("Switch Capture to Assistant \(mode) immediate", app)
            Thread.sleep(forTimeInterval: 1)
            shot("Switch Capture to Assistant \(mode) settled", app)
            personalTab(app, .capture).tap()
            shot("Switch Assistant to Capture \(mode) immediate", app)
            Thread.sleep(forTimeInterval: 1)
            shot("Switch Assistant to Capture \(mode) settled", app)
            app.terminate()
        }
    }

    @MainActor private func launchJoined() throws -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest", "-AWDFirmUITest", "-AWDFirmFixture"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 15))

        app.buttons["capture.settings"].tap()
        let row = app.buttons["settings.firm"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        while app.buttons["firm.leave"].waitForExistence(timeout: 3) { app.buttons["firm.leave"].firstMatch.tap() }
        let link = app.textFields["firm.join.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap(); link.typeText("https://aifirm.aiworkdeck.com/all")
        app.buttons["firm.join.connect"].tap()
        let status = app.staticTexts["firm.join.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.hasPrefix("Connected to"), status.label)
        app.buttons["firm.join.close"].tap()
        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        return app
    }
}
