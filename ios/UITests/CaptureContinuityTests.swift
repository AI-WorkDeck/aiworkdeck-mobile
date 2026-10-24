import XCTest

final class CaptureContinuityTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            XCUIApplication().terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    @MainActor
    func testAudioKeepsDestinationAndElapsedTimeThroughRotation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDRecordingUITest"]
        app.launch()
        allowPermissionPrompts()
        let audio = app.buttons["capture.mode.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10)); audio.tap()
        let shutter = app.buttons["capture.shutter"]
        shutter.tap()
        allowPermissionPrompts()
        expectation(for: NSPredicate(format: "label == %@", "Stop recording"), evaluatedWith: shutter)
        waitForExpectations(timeout: 30)
        let destination = app.staticTexts["capture.destination"]
        XCTAssertEqual(destination.label, "华创科技 A 轮尽调")
        var elapsed = seconds(app.staticTexts["recording.elapsed"].label)
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                (app.frame.height > app.frame.width) == (orientation == .portrait)
            }, evaluatedWith: app)
            waitForExpectations(timeout: 15)
            XCTAssertEqual(shutter.label, "Stop recording")
            XCTAssertTrue(shutter.isHittable)
            XCTAssertEqual(destination.label, "华创科技 A 轮尽调")
            let next = seconds(app.staticTexts["recording.elapsed"].label)
            XCTAssertGreaterThanOrEqual(next, elapsed)
            elapsed = next
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Audio capture \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertGreaterThan(elapsed, 0)
        app.buttons["capture.pause"].tap()
        XCTAssertEqual(shutter.label, "Resume audio")
        let pausedElapsed = app.staticTexts["recording.elapsed"].label
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(shutter.isHittable)
        XCTAssertEqual(app.staticTexts["recording.elapsed"].label, pausedElapsed)
        shutter.tap()
        XCTAssertEqual(shutter.label, "Stop recording")
        shutter.tap()
        let saved = app.buttons["Recording saved · Open library to play"]
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        XCTAssertEqual(destination.label, "华创科技 A 轮尽调")
    }

    @MainActor
    private func allowPermissionPrompts() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        // Fresh simulators ask for both microphone and silent-reminder alerts.
        for _ in 0..<3 {
            guard alert.waitForExistence(timeout: 3) else { break }
            for label in ["Allow", "允许", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
    }

    private func seconds(_ label: String) -> Int {
        let parts = label.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }
}
