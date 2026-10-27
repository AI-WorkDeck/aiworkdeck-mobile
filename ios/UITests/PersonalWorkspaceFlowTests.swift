// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

final class PersonalWorkspaceFlowTests: XCTestCase {
    @MainActor func testPersonalAssistantCalendarProjectsAndCaptureWithoutSelectingProject() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest"]
        app.launch()
        let input = app.textFields["personal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 12))
        XCTAssertTrue(app.tabBars.buttons["Calendar"].exists)
        input.tap(); input.typeText("What needs attention today?")
        app.buttons["personal.send"].tap()
        XCTAssertTrue(app.staticTexts["Review the evidence checklist today. The source is Alpha project."].waitForExistence(timeout: 8))
        capture("Personal assistant", app)
        app.tabBars.buttons["Calendar"].tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        capture("Calendar", app)
        app.staticTexts["Review evidence checklist"].tap()
        XCTAssertTrue(app.staticTexts["evidence.pdf"].waitForExistence(timeout: 5))
        capture("Calendar event", app)
        app.buttons["Close"].firstMatch.tap()
        app.tabBars.buttons["Projects"].tap()
        XCTAssertTrue(app.buttons["workspace.project.alpha"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Capture"].tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 8))
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
