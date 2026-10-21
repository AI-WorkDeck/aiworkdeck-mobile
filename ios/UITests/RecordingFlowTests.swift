import XCTest

final class RecordingFlowTests: XCTestCase {
    private func allowMicrophoneIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            for label in ["Allow", "允许", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return
            }
        }
    }

    private func dismissEarlierRecordingNotice(in app: XCUIApplication) {
        let notice = app.alerts["Recording status"]
        if notice.waitForExistence(timeout: 2) { notice.buttons["Close"].tap() }
    }

    @MainActor
    func testSilenceReminderOffersSaveAndContinuesWithoutStopping() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDRecordingUITest", "-AWDSilenceReminderUITest"]
        app.launch()
        let alert = app.alerts["Stop recording?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertTrue(alert.buttons["Stop and save"].isHittable)
        XCTAssertTrue(alert.buttons["Keep recording"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        alert.buttons["Keep recording"].tap()
        XCTAssertFalse(alert.exists)
        XCTAssertEqual(app.buttons["capture.shutter"].label, "Stop recording")
    }

    @MainActor
    func testUnassignedRecordingSettingsBackAndMove() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-libraryViewMode", "grid"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        // The current app opens capture first; projects are reached via Back.
        let mode = app.buttons["capture.mode.audio"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        let shutter = app.buttons["capture.shutter"]
        shutter.tap()
        allowMicrophoneIfNeeded()
        expectation(for: NSPredicate(format: "label == %@", "Stop recording"), evaluatedWith: shutter)
        waitForExpectations(timeout: 30)
        let before = app.staticTexts["recording.elapsed"].label
        app.buttons["capture.settings"].tap()
        app.buttons["settings.switchProject"].tap()
        let back = app.buttons["projectPicker.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(app.buttons["projectPicker.project.alpha"].waitForExistence(timeout: 5))
        back.tap()
        app.buttons["settings.close"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "Stop recording")
        XCTAssertNotEqual(app.staticTexts["recording.elapsed"].label, before)
        shutter.tap()
        let saved = app.buttons["Recording saved · Open library to play"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        app.segmentedControls.buttons["Audio"].tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.item.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        app.buttons["Select"].tap()
        item.tap()
        item.press(forDuration: 1.2)
        app.buttons["Move to project"].tap()
        let alpha = app.buttons["projectPicker.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 5)); alpha.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha project")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Select"].exists)
        item.tap()
        let play = app.buttons["media.playback"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
        waitForExpectations(timeout: 30)
        play.tap(); XCTAssertTrue(play.label.contains("Pause"))
        play.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways; add(shot)
    }

    func testTerminatedRecordingReportsRecoveryWithoutRestarting() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDRecordingUITest"]
        app.launch()
        // Earlier crash-path runs deliberately retain failed drafts.
        let earlierNotice = app.alerts["Recording status"]
        if earlierNotice.waitForExistence(timeout: 2) { earlierNotice.buttons["Close"].tap() }
        let mode = app.buttons["capture.mode.audio"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.tap()
        let shutter = app.buttons["capture.shutter"]
        shutter.tap()
        allowMicrophoneIfNeeded()
        expectation(for: NSPredicate(format: "label == %@", "Stop recording"), evaluatedWith: shutter)
        waitForExpectations(timeout: 30)
        Thread.sleep(forTimeInterval: 3)
        app.terminate()
        app.launch()
        let notice = app.alerts["Recording status"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        let recovered = notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "previous recording did not end normally")).firstMatch
        let invalid = notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No valid audio could be read")).firstMatch
        XCTAssertTrue(recovered.exists || invalid.exists, "Relaunch must explicitly report recovered audio or an unsuccessful recording")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        notice.buttons["Close"].tap()
        XCTAssertFalse(app.buttons["capture.shutter"].label == "Stop recording")
    }

    func testBackgroundReturnStopAndPlayFromAudioLibrary() {
        defer { XCUIDevice.shared.orientation = .portrait }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AWDRecordingUITest"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        let mode = app.buttons["capture.mode.audio"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.tap()
        let shutter = app.buttons["capture.shutter"]
        shutter.tap()
        allowMicrophoneIfNeeded()
        XCTAssertTrue(app.staticTexts["recording.elapsed"].waitForExistence(timeout: 5))
        let stopped = NSPredicate(format: "label == %@", "Stop recording")
        expectation(for: stopped, evaluatedWith: shutter)
        waitForExpectations(timeout: 30)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: shutter)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertEqual(shutter.label, "Stop recording")
        XCTAssertTrue(shutter.isHittable)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: shutter)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(shutter.label, "Stop recording")
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertTrue(shutter.isHittable)
        let elapsed = app.staticTexts["recording.elapsed"]
        XCTAssertNotEqual(elapsed.label, "00:00")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: shutter)
        waitForExpectations(timeout: 5)
        XCTAssertLessThan(app.frame.width, app.frame.height)
        XCTAssertEqual(shutter.label, "Stop recording")
        XCTAssertTrue(shutter.isHittable)
        shutter.tap()
        let saved = app.buttons["Recording saved · Open library to play"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        app.segmentedControls.buttons["Audio"].tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.item.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let play = app.buttons["media.playback"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
        waitForExpectations(timeout: 30)
        play.tap()
        XCTAssertTrue(play.label.contains("Pause"))
        play.tap()
        XCTAssertTrue(play.label.contains("Play"))
    }
}
