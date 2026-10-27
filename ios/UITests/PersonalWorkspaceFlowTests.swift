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
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Personal navigation hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        capture("Personal navigation", app)
        XCTAssertTrue(personalTab(app, .calendar).isHittable)
        input.tap(); input.typeText("What needs attention today?")
        app.buttons["personal.send"].tap()
        XCTAssertTrue(app.staticTexts["Review the evidence checklist today. The source is Alpha project."].waitForExistence(timeout: 8))
        capture("Personal assistant", app)
        personalTab(app, .calendar).tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        capture("Calendar", app)
        app.staticTexts["Review evidence checklist"].tap()
        XCTAssertTrue(app.staticTexts["evidence.pdf"].waitForExistence(timeout: 5))
        capture("Calendar event", app)
        app.buttons["Close"].firstMatch.tap()
        openPersonalProjects(app)
        XCTAssertTrue(app.buttons["workspace.project.alpha"].waitForExistence(timeout: 8))
        openPersonalCapture(app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 8))
        app.buttons["capture.close"].tap()
        XCTAssertTrue(app.buttons["workspace.project.alpha"].waitForExistence(timeout: 8))
        let calendar = personalTab(app, .calendar)
        XCTAssertTrue(calendar.isHittable)
        calendar.tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        let assistant = personalTab(app, .assistant)
        XCTAssertTrue(assistant.isHittable)
        assistant.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
