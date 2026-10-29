import XCTest

final class RecordingFlowTests: XCTestCase {
    private func dismissEarlierRecordingNotice(in app: XCUIApplication) {
        let notice = app.alerts["Recording status"]
        if notice.waitForExistence(timeout: 2) { notice.buttons["Close"].tap() }
    }

    @MainActor
    func testPausedAudioIsObviousAndCanResumeAndPauseAgain() {
        checkPausedCapture(argument: "-AWDPauseRecordingUITest", resume: "Resume audio", stop: "Stop recording")
    }

    @MainActor
    func testPausedVideoIsObviousAndCanResumeAndPauseAgain() {
        checkPausedCapture(argument: "-AWDPausedVideoUITest", resume: "Resume video", stop: "Stop recording")
    }

    @MainActor
    private func checkPausedCapture(argument: String, resume: String, stop: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDRecordingUITest", argument]
        app.launch()
        openPersonalCapture(app)
        let paused = app.staticTexts["recording.paused"]
        XCTAssertTrue(paused.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["capture.stopPaused"].isHittable)
        XCTAssertEqual(app.buttons["capture.shutter"].label, resume)
        let controls = [paused, app.buttons["capture.shutter"], app.buttons["capture.stopPaused"], app.buttons["capture.resume"]]
        let geometry = XCTAttachment(string: (["app=\(app.frame)"] + controls.map { "\($0.identifier): \($0.frame), hittable=\($0.isHittable)" }).joined(separator: "\n"))
        geometry.name = argument + " geometry"; geometry.lifetime = .keepAlways; add(geometry)
        for control in controls {
            XCTAssertTrue(control.isHittable)
            XCTAssertTrue(app.frame.contains(control.frame), "Paused controls must remain visible")
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = argument
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["capture.resume"].tap()
        XCTAssertFalse(paused.exists)
        XCTAssertEqual(app.buttons["capture.shutter"].label, stop)
        app.buttons["capture.pause"].tap()
        XCTAssertTrue(paused.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["capture.shutter"].label, resume)
    }

    @MainActor
    func testSilenceReminderOffersSaveAndContinuesWithoutStopping() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDRecordingUITest", "-AWDSilenceReminderUITest"]
        app.launch()
        openPersonalCapture(app)
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
        openPersonalCapture(app)
        startAudioRecordingWithOneTap(app)
        let shutter = app.buttons["capture.shutter"]
        let before = app.staticTexts["recording.elapsed"].label
        app.buttons["capture.settings"].tap()
        XCTAssertFalse(app.buttons["settings.switchProject"].exists)
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.close"].isHittable)
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

    @MainActor
    func testTerminatedRecordingReportsRecoveryWithoutRestarting() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDRecordingUITest"]
        app.launch()
        // Earlier crash-path runs deliberately retain failed drafts.
        let earlierNotice = app.alerts["Recording status"]
        if earlierNotice.waitForExistence(timeout: 2) { earlierNotice.buttons["Close"].tap() }
        openPersonalCapture(app)
        startAudioRecordingWithOneTap(app)
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
        openPersonalCapture(app)
        XCTAssertFalse(app.buttons["capture.shutter"].label == "Stop recording")
    }

    @MainActor
    func testBackgroundReturnStopAndPlayFromAudioLibrary() {
        defer { XCUIDevice.shared.orientation = .portrait }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AWDRecordingUITest"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        openPersonalCapture(app)
        startAudioRecordingWithOneTap(app)
        let shutter = app.buttons["capture.shutter"]
        XCTAssertTrue(app.staticTexts["recording.elapsed"].waitForExistence(timeout: 5))
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
