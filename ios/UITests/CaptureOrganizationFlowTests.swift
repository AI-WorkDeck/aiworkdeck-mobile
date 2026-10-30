// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

final class CaptureOrganizationFlowTests: XCTestCase {
    @MainActor func testDefaultOffCanEnableAndDisableFromCaptureSettings() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDOrganizeUITest"]
        app.launch()
        openPersonalCapture(app)
        let settings = app.buttons["capture.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let toggle = app.switches["settings.organizeCaptures"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["settings.close"].tap()
        settings.tap()
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
