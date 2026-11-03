// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

final class DefaultProjectFlowTests: XCTestCase {
    @MainActor func testTemporaryProjectOpensFilesAndReturnsToCaptureWithSameDestination() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest"]
        app.launch()
        defer { app.terminate() }
        dismissEarlierRecordingNotice(in: app)
        XCTAssertTrue(app.buttons["capture.project"].waitForExistence(timeout: 15))
        app.buttons["capture.project"].tap()
        XCTAssertTrue(app.buttons["projectPicker.none"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["projectPicker.browse"].exists)
        app.buttons["projectPicker.none"].tap()
        XCTAssertTrue(app.buttons["workspace.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["workspace.folder.Documents"].waitForExistence(timeout: 10))
        app.buttons["workspace.folder.Documents"].tap()
        XCTAssertTrue(app.buttons["workspace.file.1"].waitForExistence(timeout: 10))
        app.buttons["workspace.close"].tap()
        XCTAssertTrue(app.buttons["capture.project"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["capture.destination"].label, "Temporary project")
    }
    @MainActor func testCopyConversationFiltersDesktopTargetsAndKeepsOriginalMessages() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest", "-AWDCopyConversationUITest"]
        app.launch()
        defer { app.terminate() }
        dismissEarlierRecordingNotice(in: app)
        personalTab(app, .assistant).tap()
        let input = app.textFields["personal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap(); input.typeText("Keep this original conversation")
        app.buttons["personal.send"].tap()
        let answer = app.staticTexts["Review the evidence checklist today. The source is Alpha project."]
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == %@", "Personal assistant"))
            .containing(NSPredicate(format: "identifier == %@", "ellipsis.circle")).firstMatch.tap()
        app.buttons["personal.copyToProject"].tap()
        let target = app.buttons["projectPicker.project.12"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["projectPicker.project.999"].exists)
        target.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Keep this original conversation"].exists)
    }
    @MainActor func testDesktopConversationCopyShowsQueuedThenDelivered() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest", "-AWDDesktopCopyUITest"]
        app.launch()
        defer { app.terminate() }
        dismissEarlierRecordingNotice(in: app)
        personalTab(app, .assistant).tap()
        let input = app.textFields["personal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15)); input.tap(); input.typeText("Copy this to my computer")
        app.buttons["personal.send"].tap()
        XCTAssertTrue(app.staticTexts["Review the evidence checklist today. The source is Alpha project."].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == %@", "Personal assistant"))
            .containing(NSPredicate(format: "identifier == %@", "ellipsis.circle")).firstMatch.tap()
        app.buttons["personal.copyToProject"].tap()
        let target = app.buttons["personal.copy.desktop.mac-a.local-17"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["projectPicker.project.12"].exists)
        XCTAssertFalse(app.buttons["personal.copy.desktop.mac-old.old"].exists)
        XCTAssertTrue(app.staticTexts["Update the computer app, open the project and sync its directory before selecting it."].exists)
        target.tap()
        let status = app.staticTexts["personal.copyStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Queued — waiting for the computer to receive.")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["personal.copyRefresh"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Delivered to the computer. The original is kept."), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Copy this to my computer"].exists)
    }

}
