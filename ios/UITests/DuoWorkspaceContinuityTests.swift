import XCTest

/// Window poses are exercised in Device Hub. These tests verify the same reader
/// state while its list is hidden/shown and another full-screen flow covers it.
final class DuoWorkspaceContinuityTests: XCTestCase {
    @MainActor
    func testConfirmedDownloadSurvivesListNavigationAndCaptureCover() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDWorkspaceSlowDownload"]
        app.launch()
        let projects = app.buttons["capture.close"]
        XCTAssertTrue(projects.waitForExistence(timeout: 20)); projects.tap()
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 15)); alpha.tap()
        let documents = app.buttons["workspace.folder.Documents"]
        XCTAssertTrue(documents.waitForExistence(timeout: 15)); documents.tap()
        let file = app.buttons["workspace.file.2"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        let confirm = app.buttons["workspace.confirmDownload"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15)); confirm.tap()
        let list = app.buttons["workspace.toggleFileList"]
        list.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        list.tap()
        let preview = app.otherElements["workspace.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 60))
        XCTAssertFalse(confirm.exists)
        app.buttons["workspace.capture"].tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 15))
        app.buttons["capture.close"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertFalse(confirm.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Reader after capture cover"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["workspace.closeReading"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["workspace.folderUp"].exists)
    }
}
