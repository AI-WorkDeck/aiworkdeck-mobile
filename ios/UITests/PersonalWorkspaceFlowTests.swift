// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

final class PersonalWorkspaceFlowTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            XCUIApplication().terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testCaptureIsHomeAndProjectQueueAndAccountCanReturn() {
        let app = launch()
        XCTAssertFalse(app.buttons["capture.close"].exists, "The home tab must not display an inert close button")
        for tab in [PersonalTab.capture, .calendar, .assistant] {
            let entry = personalTab(app, tab)
            XCTAssertTrue(entry.isHittable, "Home must expose \(tab.rawValue)")
        }
        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 3)
        }
        for id in ["capture.project", "capture.settings", "capture.shutter", "capture.recordAudio", "capture.library", "capture.queue"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, "Home must expose \(id) without scrolling")
            XCTAssertTrue(app.frame.contains(button.frame), "Home control outside the visible window: \(id)")
        }
        XCTAssertFalse(app.buttons["capture.mode.audio"].exists)
        capture("Default capture home", app)

        app.buttons["capture.project"].tap()
        let alpha = app.buttons["projectPicker.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        XCTAssertEqual(app.staticTexts["capture.destination"].label, "Alpha project")
        app.buttons["capture.project"].tap()
        let none = app.buttons["projectPicker.none"]
        XCTAssertTrue(none.waitForExistence(timeout: 10)); none.tap()
        XCTAssertEqual(app.staticTexts["capture.destination"].label, "No project selected")
        app.buttons["capture.project"].tap()
        let back = app.buttons["projectPicker.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(app.buttons["capture.shutter"].isHittable)

        openPersonalProjects(app)
        XCTAssertTrue(app.buttons["workspace.project.alpha"].waitForExistence(timeout: 10))
        let closeWorkspace = app.buttons["workspace.close"]
        XCTAssertTrue(closeWorkspace.isHittable); closeWorkspace.tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))
        XCTAssertTrue(personalTab(app, .calendar).isHittable)

        app.buttons["capture.queue"].tap()
        let closeQueue = app.buttons["queue.close"]
        XCTAssertTrue(closeQueue.waitForExistence(timeout: 10)); closeQueue.tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))

        app.buttons["capture.settings"].tap()
        let account = app.descendants(matching: .any).matching(identifier: "settings.account").firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(account.isHittable)
        XCTAssertFalse(app.buttons["settings.switchProject"].exists)
        let closeSettings = app.buttons["settings.close"]
        XCTAssertTrue(closeSettings.isHittable); closeSettings.tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))
        XCTAssertTrue(personalTab(app, .assistant).isHittable)
        capture("Capture after all close and back actions", app)
    }

    @MainActor func testPersonalAssistantCalendarProjectsAndCaptureWithoutSelectingProject() {
        let app = launch()
        personalTab(app, .assistant).tap()
        let input = app.textFields["personal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 12))
        capture("Personal assistant empty input", app)
        input.tap(); input.typeText("What needs attention today?")
        capture("Personal assistant composed input", app)
        app.buttons["personal.send"].tap()
        XCTAssertTrue(app.staticTexts["Review the evidence checklist today. The source is Alpha project."].waitForExistence(timeout: 8))
        capture("Personal assistant", app)
        app.buttons["personal.settings"].tap()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 10))
        app.buttons["settings.close"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        personalTab(app, .calendar).tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        capture("Calendar", app)
        app.staticTexts["Review evidence checklist"].tap()
        XCTAssertTrue(app.staticTexts["evidence.pdf"].waitForExistence(timeout: 5))
        capture("Calendar event", app)
        app.buttons["Close"].firstMatch.tap()
        app.buttons["personal.settings"].tap()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 10))
        app.buttons["settings.close"].tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        openPersonalCapture(app)
        XCTAssertTrue(app.buttons["capture.shutter"].isHittable)
        XCTAssertFalse(app.buttons["capture.close"].exists)
        openPersonalProjects(app)
        XCTAssertTrue(app.buttons["workspace.project.alpha"].waitForExistence(timeout: 8))
        openPersonalCapture(app)
        XCTAssertTrue(app.buttons["capture.shutter"].isHittable)
        personalTab(app, .calendar).tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        personalTab(app, .assistant).tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Review the evidence checklist today. The source is Alpha project."].exists)
    }

    @MainActor func testOneTapUnassignedRecordingContinuesAcrossTabsAndSettings() {
        let app = launch()
        startAudioRecordingWithOneTap(app)
        let shutter = app.buttons["capture.shutter"]
        XCTAssertEqual(app.staticTexts["capture.destination"].label, "No project selected")
        XCTAssertFalse(app.buttons["capture.project"].isEnabled)
        let elapsedBefore = app.staticTexts["recording.elapsed"].label
        personalTab(app, .calendar).tap()
        XCTAssertTrue(app.staticTexts["Review evidence checklist"].waitForExistence(timeout: 8))
        openPersonalCapture(app)
        XCTAssertEqual(shutter.label, "Stop recording")
        XCTAssertEqual(app.staticTexts["capture.destination"].label, "No project selected")
        app.buttons["capture.settings"].tap()
        let closeSettings = app.buttons["settings.close"]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 10)); closeSettings.tap()
        XCTAssertEqual(shutter.label, "Stop recording")
        XCTAssertNotEqual(app.staticTexts["recording.elapsed"].label, elapsedBefore)
        shutter.tap()
        XCTAssertTrue(app.buttons["Recording saved · Open library to play"].waitForExistence(timeout: 15))
        app.buttons["capture.queue"].tap()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'queue.item.'"))
            .containing(NSPredicate(format: "identifier BEGINSWITH 'queue.project.' AND label == %@", "Unassigned")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertTrue(item.isHittable)
        XCTAssertEqual(app.staticTexts["queue.scope"].label, "All projects")
        let itemID = item.identifier
        capture("Unassigned recording in global queue", app)
        item.tap()
        let move = app.buttons["queue.move"]
        XCTAssertTrue(move.waitForExistence(timeout: 10)); move.tap()
        let alpha = app.buttons["projectPicker.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        let back = app.buttons["queue.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(app.buttons[itemID].waitForExistence(timeout: 10))
        app.buttons["queue.close"].tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["capture.destination"].label, "No project selected")
        app.buttons["capture.queue"].tap()
        XCTAssertTrue(app.buttons[itemID].waitForExistence(timeout: 10), "Global queue must retain the record after assigning another project")
        XCTAssertEqual(app.staticTexts["queue.scope"].label, "All projects")
        app.buttons[itemID].tap()
        let copy = app.buttons["queue.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10)); copy.tap()
        let beta = app.buttons["projectPicker.project.beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 10)); beta.tap()
        let originalDetailID = itemID.replacingOccurrences(of: "queue.item.", with: "queue.detail.")
        let copiedDetail = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@", "queue.detail.", originalDetailID)).firstMatch
        XCTAssertTrue(copiedDetail.waitForExistence(timeout: 15), "Copy must select a new queue record")
        let copiedDetailID = copiedDetail.identifier
        XCTAssertNotEqual(copiedDetailID, originalDetailID)
        let copiedItemID = copiedDetailID.replacingOccurrences(of: "queue.detail.", with: "queue.item.")
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: back)
        waitForExpectations(timeout: 10)
        capture("Copied recording selected in Beta project", app)
        back.tap()
        XCTAssertTrue(app.buttons[itemID].waitForExistence(timeout: 10), "Copy must preserve the original queue record")
        XCTAssertTrue(app.buttons[copiedItemID].waitForExistence(timeout: 10))
        let originalProjectID = itemID.replacingOccurrences(of: "queue.item.", with: "queue.project.")
        let copiedProjectID = copiedItemID.replacingOccurrences(of: "queue.item.", with: "queue.project.")
        XCTAssertEqual(app.staticTexts[originalProjectID].label, "Alpha project")
        XCTAssertEqual(app.staticTexts[copiedProjectID].label, "Beta project")
        XCTAssertEqual(app.staticTexts["queue.scope"].label, "All projects")
        capture("Global queue retains Alpha original and Beta copy", app)
        app.buttons["queue.close"].tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))
        XCTAssertTrue(personalTab(app, .assistant).isHittable)
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
