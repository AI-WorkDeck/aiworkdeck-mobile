// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

final class ModalDismissalTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            XCUIApplication().terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    @MainActor func testVisibleCloseControlsDismissAfterRotation() { exerciseDismissal(rotate: true) }

    @MainActor func testVisibleCloseControlsDismissInCurrentWindow() { exerciseDismissal(rotate: false) }

    @MainActor private func exerciseDismissal(rotate: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDPersonalUITest"]
        app.launch()
        dismissEarlierRecordingNotice(in: app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 20))
        for (entry, close) in [("capture.queue", "queue.close"), ("capture.project", "projectPicker.back"), ("capture.settings", "settings.close")] {
            app.buttons[entry].tap()
            assertDismisses(app, close: close, returningTo: "capture.shutter", rotate: rotate)
        }
        personalTab(app, .assistant).tap()
        app.buttons["personal.settings"].tap()
        assertDismisses(app, close: "settings.close", returningTo: "personal.settings", rotate: rotate)
    }

    @MainActor private func assertDismisses(_ app: XCUIApplication, close: String, returningTo: String, rotate: Bool) {
        let button = app.buttons[close]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for orientation: UIDeviceOrientation in (rotate ? [.landscapeLeft, .portrait] : []) {
            XCUIDevice.shared.orientation = orientation
            let portrait = orientation == .portrait
            expectation(for: NSPredicate { _, _ in
                (app.frame.height > app.frame.width) == portrait && button.isHittable
            }, evaluatedWith: button)
            waitForExpectations(timeout: 15)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = close + " before physical tap"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Coordinate tapping exercises the displayed hit region, not an accessibility action.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate { _, _ in !button.exists && app.buttons[returningTo].isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
    }
}
