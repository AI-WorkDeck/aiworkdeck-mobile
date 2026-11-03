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
        openPersonalCapture(app)
        startAudioRecordingWithOneTap(app)
        let shutter = app.buttons["capture.shutter"]
        let destination = app.staticTexts["capture.destination"]
        XCTAssertEqual(destination.label, "华创科技 A 轮尽调")
        var elapsed = seconds(app.staticTexts["recording.elapsed"].label)
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            guard waitForReadyControl(ReadyControl(element: shutter, identifier: "capture.shutter", label: "Stop recording"),
                                      in: app, portrait: orientation == .portrait, timeout: 15) != nil else { return }
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
        guard waitForReadyControl(ReadyControl(element: shutter, identifier: "capture.shutter", label: "Resume audio"),
                                  in: app, portrait: false, timeout: 15) != nil else { return }
        XCTAssertEqual(app.staticTexts["recording.elapsed"].label, pausedElapsed)
        shutter.tap()
        XCTAssertEqual(shutter.label, "Stop recording")
        shutter.tap()
        let saved = app.buttons["Recording saved · Open library to play"]
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        XCTAssertEqual(destination.label, "华创科技 A 轮尽调")
    }

    private func seconds(_ label: String) -> Int {
        let parts = label.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }
}
