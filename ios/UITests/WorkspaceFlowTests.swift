import XCTest

final class WorkspaceFlowTests: XCTestCase {
    @MainActor
    func testCloudOnlyProjectHasWorkingFileEntryAndMixedProjectLocationPicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDCloudCatalogUITest"]
        app.launch()
        let cloud = app.buttons["workspace.project.cloud-only"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10)); cloud.tap()
        let file = app.buttons["workspace.file.1"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        let confirm = app.buttons["workspace.confirmDownload"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "Open cloud file")
        confirm.tap()
        XCTAssertTrue(app.otherElements["workspace.preview"].waitForExistence(timeout: 10))
        app.buttons["Close"].firstMatch.tap()
        let mixed = app.buttons["workspace.project.mixed"]
        if !mixed.isHittable { app.navigationBars.buttons["Projects"].tap() }
        XCTAssertTrue(mixed.waitForExistence(timeout: 5)); mixed.tap()
        let locations = app.buttons["workspace.storageLocation"]
        XCTAssertTrue(locations.waitForExistence(timeout: 5)); locations.tap()
        app.buttons["Cloud storage"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["cloud-archive-document-1.pdf"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Unified project cloud file location"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testLandscapeLoginControlsRemainReachableAfterShowingKeyboard() {
        defer { XCUIDevice.shared.orientation = .portrait }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-AWDLoginUITest", "-accountRegion", "cn"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        app.swipeDown()
        let region = app.buttons["切换大陆版或海外版账号"]
        XCTAssertTrue(region.waitForExistence(timeout: 5))
        XCTAssertTrue(region.isHittable)
        XCTAssertGreaterThanOrEqual(region.frame.minY, app.frame.minY)
        app.buttons["邮箱"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        app.textFields.firstMatch.tap()
        app.textFields.firstMatch.typeText("layout-test@example.invalid")
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "layout-test@example.invalid")
        app.swipeUp()
        let send = app.buttons["获取验证码"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isHittable)
        // No code request is sent; this only exercises form layout.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testLandscapeFilesAtAccessibilityTextSize() {
        defer { XCUIDevice.shared.orientation = .portrait }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        let file = app.buttons["workspace.file.1"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertTrue(file.isHittable)
        XCTAssertTrue(app.buttons["workspace.capture"].isHittable)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertGreaterThanOrEqual(file.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(file.frame.maxX, app.frame.maxX)
        let geometry = XCTAttachment(string: "App: \(app.frame); first file: \(file.frame)")
        geometry.lifetime = .keepAlways; add(geometry)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Landscape accessibility text"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testProjectFilesQuotePreviewAndRotationContinuity() {
        defer { XCUIDevice.shared.orientation = .portrait }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest"]
        app.launch()
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10))
        alpha.tap()
        let search = app.textFields["workspace.fileSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("document-12")
        let file = app.buttons["workspace.file.12"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "document-12")
        let wideShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); wideShot.name = "Workspace landscape"; wideShot.lifetime = .keepAlways; add(wideShot)
        file.tap()
        let confirm = app.buttons["workspace.confirmDownload"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["workspace.preview"].exists)
        confirm.tap()
        XCTAssertTrue(app.otherElements["workspace.preview"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "document-12")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testLateProjectResponseDoesNotReplaceCurrentFiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDWorkspaceDelayed"]
        app.launch()
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        XCTAssertTrue(app.textFields["workspace.fileSearch"].waitForExistence(timeout: 5))
        let beta = app.buttons["workspace.project.beta"]
        if !beta.isHittable {
            let back = app.navigationBars.buttons["Projects"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(beta.waitForExistence(timeout: 5)); beta.tap()
        XCTAssertTrue(app.staticTexts["beta-document-1.pdf"].waitForExistence(timeout: 5))
        // Allow the cancelled Alpha response to arrive after Beta has rendered.
        let late = expectation(description: "late LIST delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { late.fulfill() }
        wait(for: [late], timeout: 12)
        XCTAssertTrue(app.staticTexts["beta-document-1.pdf"].exists)
        XCTAssertFalse(app.staticTexts["alpha-document-1.pdf"].exists)
    }

    @MainActor
    func testOfflineFilesStillOfferLocalRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDWorkspaceOffline"]
        app.launch()
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        XCTAssertTrue(app.staticTexts["Test desktop is offline"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Field records"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Audio"].waitForExistence(timeout: 5))
    }
}
