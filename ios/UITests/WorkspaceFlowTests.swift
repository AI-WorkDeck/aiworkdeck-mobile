import XCTest

final class WorkspaceFlowTests: XCTestCase {
    override func tearDown() async throws {
        // XCTest can abort a failing method before its Swift defer runs.
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        try await super.tearDown()
    }

    @MainActor
    func testCaptureLayoutSurvivesRepeatedRotationAndProjectEntry() {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest"]
        app.launch()
        openPersonalCapture(app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))
        let original = app.buttons["capture.shutter"].frame
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let portrait = orientation == .portrait
            guard waitForReadyOrientation(in: app, portrait: portrait, timeout: 5) else { return }
            let rotatedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            rotatedShot.name = "Before hit testing"; rotatedShot.lifetime = .keepAlways; add(rotatedShot)
            for id in ["capture.project", "capture.settings", "capture.mode.photo", "capture.mode.video", "capture.recordAudio", "capture.shutter", "capture.library", "capture.queue"] {
                let control = ReadyControl(element: app.buttons[id], identifier: id)
                guard let ready = waitForReadyControl(control, in: app, portrait: portrait, timeout: 5) else { return }
                if portrait && id == "capture.shutter" {
                    XCTAssertEqual(ready.control.frame.midX, original.midX, accuracy: 2)
                    XCTAssertEqual(ready.control.frame.midY, original.midY, accuracy: 2)
                }
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Capture rotation \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
        }
        openProjects(app)
        app.buttons["workspace.project.alpha"].tap()
        XCTAssertTrue(app.buttons["workspace.capture"].waitForExistence(timeout: 5))
        app.buttons["workspace.capture"].tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 5))
        let nestedOriginal = app.buttons["capture.shutter"].frame
        XCTAssertTrue(app.buttons["capture.close"].isHittable)
        continueAfterFailure = true
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let portrait = orientation == .portrait
            guard waitForReadyOrientation(in: app, portrait: portrait, timeout: 5) else { return }
            let shutter = ReadyControl(element: app.buttons["capture.shutter"], identifier: "capture.shutter")
            guard let ready = waitForReadyControl(shutter, in: app, portrait: portrait, timeout: 5) else { return }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Project capture rotation \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
            let geometry = XCTAttachment(string: "App: \(ready.window); shutter: \(ready.control.frame)")
            geometry.lifetime = .keepAlways; add(geometry)
            if portrait {
                XCTAssertEqual(ready.control.frame.midX, nestedOriginal.midX, accuracy: 2)
                XCTAssertEqual(ready.control.frame.midY, nestedOriginal.midY, accuracy: 2)
            }
        }
    }

    @MainActor
    private func openProjects(_ app: XCUIApplication) {
        openPersonalProjects(app)
    }

    @MainActor
    private func openDocuments(_ app: XCUIApplication) {
        let folder = app.buttons["workspace.folder.Documents"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
    }

    @MainActor
    func testFailedFirstConsentCanCloseWithoutBlockingCapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDConsentUITest", "-AWDConsentFailureUITest"]
        app.launch()
        let decline = app.buttons["backup.decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10)); decline.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        openPersonalCapture(app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 5))
        app.buttons["capture.settings"].tap()
        let backup = app.buttons["settings.backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        if !backup.isHittable { app.swipeUp() }
        backup.tap()
        XCTAssertTrue(decline.waitForExistence(timeout: 5), "A failed write must still be undecided when reopened")
    }

    @MainActor
    func testFirstLoginRequiresExplicitBackupDecisionThenShowsCapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDConsentUITest"]
        app.launch()
        let decline = app.buttons["backup.decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["backup.enable"].exists)
        decline.tap()
        openPersonalCapture(app)
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 5))
        XCTAssertFalse(decline.exists)
    }

    @MainActor
    func testDefaultCaptureFolderNavigationAndUnsupportedPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDFolderUITest"]
        app.launch()
        openProjects(app)
        app.buttons["workspace.project.alpha"].tap()
        openDocuments(app)
        let nested = app.buttons["workspace.folder.Documents/Nested"]
        XCTAssertTrue(nested.waitForExistence(timeout: 5)); nested.tap()
        let unsupported = app.buttons["workspace.file.unsupported"]
        XCTAssertTrue(unsupported.waitForExistence(timeout: 5)); unsupported.tap()
        XCTAssertTrue(app.staticTexts["workspace.unsupported"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.confirmDownload"].exists)
        app.buttons["Close"].firstMatch.tap()
        app.buttons["workspace.folderUp"].tap()
        XCTAssertTrue(nested.waitForExistence(timeout: 5))
        app.buttons["workspace.folderRoot"].tap()
        XCTAssertTrue(app.buttons["workspace.folder.Empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.capture"].tap()
        XCTAssertTrue(app.buttons["capture.mode.photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.shutter"].isHittable)
    }

    @MainActor
    func testCloudOnlyProjectHasWorkingFileEntryAndMixedProjectLocationPicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-AWDCloudCatalogUITest"]
        app.launch()
        openProjects(app)
        let cloud = app.buttons["workspace.project.cloud-only"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10)); cloud.tap()
        openDocuments(app)
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
        openDocuments(app)
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
        dismissEarlierRecordingNotice(in: app)
        let identity = app.textFields["login.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        identity.tap()
        identity.typeText("13800007301")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["login.scroll"]
        XCTAssertTrue(scroll.exists)
        // A full-screen flick skips the password between the short landscape viewport and keyboard.
        // The ScrollView frame includes the landscape safe area; derive the content gutter from the field.
        // This stays inside the safe area and outside segmented controls that consume vertical gestures.
        // Reverse if the target passed above the visible scroll area.
        func reveal(_ element: XCUIElement) {
            for _ in 0..<12 where !element.isHittable {
                let frame = scroll.frame
                let keyboard = app.keyboards.firstMatch
                let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
                let top = max(frame.minY, app.frame.minY) + 8
                let height = max(24, bottom - top - 8)
                let centerY = top + height / 2
                let direction: CGFloat = element.frame.maxY < top ? 1 : -1
                let gutterX = max(frame.minX + 8, identity.frame.minX - 8)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: gutterX, dy: centerY - direction * height * 0.15))
                let end = origin.withOffset(CGVector(dx: gutterX, dy: centerY + direction * height * 0.15))
                // The default 500 px/s release flings past the entire short form. Stop before lifting.
                start.press(forDuration: 0.15, thenDragTo: end,
                            withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 0.5)
            }
            if !element.isHittable {
                let geometry = XCTAttachment(string: "App: \(app.frame); scroll: \(scroll.frame); identity: \(identity.frame); keyboard: \(app.keyboards.firstMatch.frame); target: \(element.frame)")
                geometry.lifetime = .keepAlways
                add(geometry)
                let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                failure.name = "Unreachable landscape login control"
                failure.lifetime = .keepAlways
                add(failure)
            }
            XCTAssertTrue(element.isHittable)
        }
        let password = app.secureTextFields["login.password"]
        reveal(password)
        let visiblePassword = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        visiblePassword.name = "Landscape password reachable above keyboard"
        visiblePassword.lifetime = .keepAlways; add(visiblePassword)
        password.tap()
        password.typeText("synthetic-layout-password")
        let enteredPassword = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        enteredPassword.name = "Landscape password entered"
        enteredPassword.lifetime = .keepAlways; add(enteredPassword)
        for id in ["login.register", "login.reset"] {
            let entry = app.buttons[id]
            XCTAssertTrue(entry.exists)
            reveal(entry)
        }
        // No sign-in, code request, external navigation or real data is created.
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
        openProjects(app)
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        openDocuments(app)
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
        openProjects(app)
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
        // A landscape software keyboard can cover the entire result list.
        // Finish the query with its Search action before selecting the file.
        search.typeText("\n")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(file.isHittable)
        file.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
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
        openProjects(app)
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        XCTAssertTrue(app.textFields["workspace.fileSearch"].waitForExistence(timeout: 5))
        let beta = app.buttons["workspace.project.beta"]
        if !beta.isHittable {
            let back = app.navigationBars.buttons["Projects"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(beta.waitForExistence(timeout: 5)); beta.tap()
        openDocuments(app)
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
        openProjects(app)
        let alpha = app.buttons["workspace.project.alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.tap()
        XCTAssertTrue(app.staticTexts["Test desktop is offline"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Field records"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Audio"].waitForExistence(timeout: 5))
    }
}
