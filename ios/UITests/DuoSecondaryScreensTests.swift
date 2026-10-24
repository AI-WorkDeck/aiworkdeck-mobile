import XCTest

/// Run on the device's actual current posture. Device Hub owns Duo's hinge and
/// orientation; XCUIDevice.orientation does not drive those on the 27.1 runtime.
final class DuoSecondaryScreensTests: XCTestCase {
    @MainActor
    private func launch(screen: Int) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDScreenshotMode", "-AWDScreenshotScreen", String(screen), "-libraryViewMode", "grid"]
        app.launch()
        return app
    }

    @MainActor
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLibrarySelectionDetailsAndFocusInCurrentWindow() {
        let app = launch(screen: 4)
        defer { app.terminate() }
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15))
        item.tap()
        let details = app.buttons["viewer.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        keepScreenshot("Library selected record")
        let focus = app.buttons["viewer.focus"]
        if focus.exists {
            XCTAssertTrue(item.isHittable)
            XCTAssertLessThanOrEqual(item.frame.maxX, details.frame.minX)
            XCTAssertTrue(focus.isHittable)
            focus.tap()
            XCTAssertTrue(details.isHittable)
            XCTAssertFalse(item.isHittable)
            focus.tap()
            XCTAssertTrue(item.isHittable)
        } else {
            XCTAssertFalse(focus.exists)
            XCTAssertFalse(item.isHittable)
        }
        details.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '9f3c1a77b204'")).firstMatch.waitForExistence(timeout: 10))
        keepScreenshot("Library record metadata")
    }

    @MainActor
    func testQueueSelectedTaskCanReturnToList() {
        let app = launch(screen: 3)
        defer { app.terminate() }
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'queue.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15))
        let id = item.identifier.replacingOccurrences(of: "queue.item.", with: "queue.detail.")
        item.tap()
        let detail = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        keepScreenshot("Queue selected task")
        if item.isHittable {
            XCTAssertLessThanOrEqual(item.frame.maxX, app.staticTexts["queue.selectedStatus"].frame.minX)
        } else {
            XCTAssertFalse(item.isHittable)
        }
        XCTAssertTrue(app.buttons["queue.back"].isHittable)
        app.buttons["queue.back"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertTrue(item.isHittable)
    }

    @MainActor
    func testSettingsShowsCategoriesOrCompleteForm() {
        let app = launch(screen: 7)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 15))
        let category = app.buttons["settings.category.settings.about"]
        if category.isHittable {
            XCTAssertTrue(category.waitForExistence(timeout: 15))
            category.tap()
            XCTAssertFalse(app.buttons["settings.switchProject"].exists)
            XCTAssertTrue(app.staticTexts["hi@aiworkdeck.com"].exists)
            app.buttons["settings.category.settings.archiveTarget"].tap()
            XCTAssertTrue(app.buttons["settings.switchProject"].isHittable)
        } else {
            XCTAssertFalse(category.isHittable)
            XCTAssertTrue(app.buttons["settings.switchProject"].exists)
        }
        XCTAssertTrue(app.buttons["settings.close"].isHittable)
        keepScreenshot("Settings current window")
    }
}
