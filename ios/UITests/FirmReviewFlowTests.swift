// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

/// Firm review end to end against a LOCAL copy of the portal server with synthetic matters
/// (docs/specs/2026-11-19-firm-review.md). Skipped unless AWD_FIRM_PORTAL_BASE and AWD_FIRM_TRIAL_CODE are set
/// for the test run, so CI without a local portal does not fail.
final class FirmReviewFlowTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    @MainActor private func launch() throws -> XCUIApplication {
        guard let base = env["AWD_FIRM_PORTAL_BASE"], env["AWD_FIRM_TRIAL_CODE"] != nil else {
            throw XCTSkip("Needs a local portal: set AWD_FIRM_PORTAL_BASE and AWD_FIRM_TRIAL_CODE")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest", "-AWDFirmUITest", "-AWDFirmPortalBase", base]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func shot(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["AWD_FIRM_SHOTS"] { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private var reviewsTab: (XCUIApplication) -> XCUIElement = { app in
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reviews"))
            .containing(NSPredicate(format: "identifier IN %@", ["signature"])).firstMatch
    }

    @MainActor private func join(_ app: XCUIApplication) {
        app.buttons["capture.settings"].tap()
        let row = app.buttons["settings.firm"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        while app.buttons["firm.leave"].waitForExistence(timeout: 3) { app.buttons["firm.leave"].firstMatch.tap() }
        let link = app.textFields["firm.join.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        shot("01-join", app)
        // A link from another host is refused before anything is sent.
        link.tap(); link.typeText("https://evil.example/sv/v2/")
        app.buttons["firm.join.connect"].tap()
        XCTAssertTrue(app.staticTexts["firm.join.error"].waitForExistence(timeout: 5))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        link.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        link.typeText("https://aifirm.aiworkdeck.com/sv/")
        app.buttons["Use a trial code"].tap()
        let code = app.secureTextFields["firm.join.trial"]
        XCTAssertTrue(code.waitForExistence(timeout: 5)); code.tap(); code.typeText(env["AWD_FIRM_TRIAL_CODE"]!)
        app.buttons["firm.join.connect"].tap()
        let status = app.staticTexts["firm.join.status"]
        if !status.waitForExistence(timeout: 15) { shot("02-missing", app) }
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.hasPrefix("Connected to"), status.label)
        shot("02-connected", app)
        app.buttons["firm.join.close"].tap()
        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
    }

    @MainActor func testLawyerReadsRepliesConfirmsCallAndSignsOff() throws {
        let app = try launch()
        join(app)

        // Inbox: the Reviews tab appears once the firm approves (trial code here); what needs the lawyer comes first.
        let tab = reviewsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        let review = app.buttons["firm.row.mtr-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Needs you"].exists)
        XCTAssertTrue(app.staticTexts["Finalised and closed"].exists)
        shot("03-inbox", app)

        // Matter: the client's list for the lawyer, red flags settled, what changed, the document.
        review.tap()
        XCTAssertTrue(app.staticTexts["Is a $10M post-money cap reasonable for a seed robotics company?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["For the lawyer · 2"].exists)
        shot("04-matter-top", app)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Changed"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Raised the valuation cap to $10M")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Raised the valuation cap to $10M")).firstMatch.exists)
        shot("05-matter-flags-changes", app)
        app.swipeUp()
        shot("06-matter-document", app)

        // Reply in one sentence.
        app.buttons["firm.reply"].tap()
        let text = app.textFields["firm.reply.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        app.buttons["Question"].tap()
        text.typeText("is the investor's address in Singapore?")
        shot("07-reply", app)
        app.buttons["firm.reply.send"].tap()
        XCTAssertTrue(app.staticTexts["firm.toast"].waitForExistence(timeout: 10))

        // Sign off: the signer is the connected identity (nothing to type); disabled until every confirmation.
        app.buttons["firm.signoff"].tap()
        let confirm = app.buttons["firm.signoff.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertEqual(app.textFields.count, 0, "Signing never asks the lawyer to type a name")
        XCTAssertTrue(app.descendants(matching: .any)["firm.signoff.signer"].exists)
        for id in ["firm.signoff.conflicts", "firm.signoff.engagement", "firm.signoff.reviewed"] {
            XCTAssertFalse(confirm.isEnabled, id)
            let row = app.buttons[id]; XCTAssertTrue(row.exists, id); row.tap()
        }
        shot("08-signoff", app)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        let closePDF = app.buttons["firm.pdf.close"]
        XCTAssertTrue(closePDF.waitForExistence(timeout: 20))
        sleep(2)
        shot("09-signed-pdf", app)
        closePDF.tap()
        XCTAssertFalse(app.buttons["firm.signoff"].waitForExistence(timeout: 3), "A signed matter has no action bar")

        // Call request: confirm it from More.
        // Back to the inbox with the system edge swipe (Duo has no classic navigation bar).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        let call = app.buttons["firm.row.mtr-call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10)); call.tap()
        XCTAssertTrue(app.staticTexts["Call requested · Tomorrow 10:00–11:00 PT"].waitForExistence(timeout: 10))
        app.buttons["firm.more"].tap()
        app.buttons["Confirm the call"].tap()
        XCTAssertTrue(app.staticTexts["Call confirmed"].waitForExistence(timeout: 10))
        shot("10-call-confirmed", app)
    }

    /// Live, read-only: links both partner-network offices with a trial code and checks that their demo matters
    /// share one inbox, labelled by firm. Opens the finalise sheet and cancels (nothing is written).
    /// Skipped unless AWD_FIRM_LIVE_TRIAL is set.
    @MainActor func testTwoPartnerOfficesShareOneInbox() throws {
        guard let code = env["AWD_FIRM_LIVE_TRIAL"] else { throw XCTSkip("Needs AWD_FIRM_LIVE_TRIAL") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest", "-AWDFirmUITest"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 15))

        app.buttons["capture.settings"].tap()
        let row = app.buttons["settings.firm"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        while app.buttons["firm.leave"].waitForExistence(timeout: 3) { app.buttons["firm.leave"].firstMatch.tap() }
        for office in ["sv", "tw"] {
            let link = app.textFields["firm.join.link"]
            XCTAssertTrue(link.waitForExistence(timeout: 10)); link.tap()
            link.typeText("https://ai-firm.aiworkdeck.com/\(office)/")
            app.buttons["Use a trial code"].tap()
            let field = app.secureTextFields["firm.join.trial"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(code)
            app.buttons["firm.join.connect"].tap()
            XCTAssertTrue(app.textFields["firm.join.link"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["firm.join.error"].exists)
        }
        let statuses = app.staticTexts.matching(identifier: "firm.join.status")
        XCTAssertTrue(statuses.element(boundBy: 1).waitForExistence(timeout: 15))
        XCTAssertEqual(statuses.count, 2)
        shot("live-01-two-firms", app)
        app.buttons["firm.join.close"].tap()
        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()

        let tab = reviewsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        let sv = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Venture AI · Silicon Valley")).firstMatch
        let tw = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Draft AI · Taipei")).firstMatch
        XCTAssertTrue(sv.waitForExistence(timeout: 20))
        XCTAssertTrue(tw.waitForExistence(timeout: 20))
        shot("live-02-inbox", app)

        tw.tap()
        let finalise = app.buttons["firm.signoff"]
        let found = finalise.waitForExistence(timeout: 15)
        if !found { shot("live-03-missing", app) }
        XCTAssertTrue(found)
        shot("live-03-matter", app)
        finalise.tap()
        XCTAssertTrue(app.descendants(matching: .any)["firm.signoff.signer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["firm.signoff.firm"].exists, "a trial code is no lawyer: no firm field")
        shot("live-04-finalise", app)
        app.buttons["Cancel"].tap()
    }
}
