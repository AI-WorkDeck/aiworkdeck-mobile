import XCTest

final class CrossScreenRotationTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            XCUIApplication().terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    @MainActor
    private func record(_ name: String, app: XCUIApplication, elements: [XCUIElement]) {
        let geometry = XCTAttachment(string: (["app=\(app.frame)"] + elements.map { element in
            guard let snapshot = try? element.snapshot() else { return "Element snapshot unavailable" }
            return "\(snapshot.identifier) \(snapshot.label): frame=\(snapshot.frame), hittable=\(element.isHittable)"
        }).joined(separator: "\n"))
        geometry.name = name + " geometry"; geometry.lifetime = .keepAlways; add(geometry)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    private func cycle(_ name: String, app: XCUIApplication, elements: [XCUIElement]) {
        Thread.sleep(forTimeInterval: 1)
        let before = elements.map(\.frame)
        record(name + " portrait before", app: app, elements: elements)
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in
                let frame = app.frame
                return (frame.height > frame.width) == (orientation == .portrait)
            }, evaluatedWith: app)
            waitForExpectations(timeout: 15)
            let portrait = orientation == .portrait
            let frame = app.frame
            XCTAssertEqual(frame.width < frame.height, portrait, name + " application orientation")
            // Wait for each control separately. Accessibility requests are
            // synchronous and must not consume another control's wait budget.
            for element in elements {
                expectation(for: NSPredicate { _, _ in
                    let window = app.frame.insetBy(dx: -1, dy: -1)
                    guard let snapshot = try? element.snapshot() else { return false }
                    let frame = snapshot.frame
                    return !frame.isEmpty && window.contains(frame) && element.isHittable
                }, evaluatedWith: element)
                waitForExpectations(timeout: 15)
            }
            record(name + " \(orientation.rawValue)", app: app, elements: elements)
            let window = app.frame.insetBy(dx: -1, dy: -1)
            for (index, element) in elements.enumerated() {
                guard let snapshot = try? element.snapshot() else {
                    XCTFail(name + " missing element snapshot")
                    return
                }
                XCTAssertTrue(element.exists, name + " missing " + snapshot.identifier)
                XCTAssertTrue(element.isHittable, name + " unreachable " + snapshot.identifier)
                XCTAssertTrue(window.contains(snapshot.frame), name + " outside window " + snapshot.identifier)
                if portrait {
                    let old = before[index], new = snapshot.frame
                    XCTAssertEqual(old.minX, new.minX, accuracy: 2, name + " x after returning")
                    XCTAssertEqual(old.minY, new.minY, accuracy: 2, name + " y after returning")
                    XCTAssertEqual(old.width, new.width, accuracy: 2, name + " width after returning")
                    XCTAssertEqual(old.height, new.height, accuracy: 2, name + " height after returning")
                }
            }
        }
    }

    @MainActor
    private func launchWorkspace() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AWDWorkspaceUITest", "-libraryViewMode", "grid"]
        app.launch()
        openPersonalProjects(app)
        XCTAssertTrue(app.buttons["workspace.project.alpha"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openFiles(_ app: XCUIApplication) {
        app.buttons["workspace.project.alpha"].tap()
        let documents = app.buttons["workspace.folder.Documents"]
        XCTAssertTrue(documents.waitForExistence(timeout: 10)); documents.tap()
        XCTAssertTrue(app.buttons["workspace.file.1"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func returnToFiles(_ app: XCUIApplication) {
        let closeCapture = app.buttons["capture.close"]
        XCTAssertTrue(closeCapture.waitForExistence(timeout: 10)); closeCapture.tap()
        let firstFile = app.buttons["workspace.file.1"]
        XCTAssertTrue(firstFile.waitForExistence(timeout: 10))
        record("Files after nested modals", app: app, elements: [firstFile, app.buttons["workspace.capture"]])
        XCTAssertTrue(firstFile.isHittable)
    }

    @MainActor
    func testProjectListSurvivesRepeatedRotation() {
        let app = launchWorkspace()
        let quickCapture = app.buttons["workspace.quickCapture"]
        let quickCaptureBefore = quickCapture.frame
        cycle("Project list", app: app, elements: [app.buttons["workspace.project.alpha"], quickCapture, app.buttons["workspace.library"]])
        XCTAssertTrue(quickCapture.isHittable)
        XCTAssertEqual(quickCapture.frame, quickCaptureBefore)
        openFiles(app)
    }

    @MainActor
    func testProjectFilesSurviveRepeatedRotation() {
        let app = launchWorkspace()
        openFiles(app)
        cycle("Project files", app: app, elements: [app.buttons["workspace.file.1"], app.buttons["workspace.capture"], app.textFields["workspace.fileSearch"]])
        app.buttons["workspace.capture"].tap()
        returnToFiles(app)
    }

    @MainActor
    func testSettingsSurviveRepeatedRotation() {
        let app = launchWorkspace()
        openFiles(app)
        app.buttons["workspace.capture"].tap()
        let settingsButtons = app.buttons.matching(identifier: "capture.settings")
        XCTAssertTrue(settingsButtons.firstMatch.waitForExistence(timeout: 10))
        let visibleSettings = settingsButtons.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(visibleSettings.count, 1, "Only the active capture page can accept a Settings tap")
        guard let settings = visibleSettings.first else { return }
        settings.tap()
        let closeSettings = app.buttons["settings.close"]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["capture.close"].isHittable, "Covered capture navigation must not accept taps")
        cycle("Settings", app: app, elements: [closeSettings, app.descendants(matching: .any).matching(identifier: "settings.account").firstMatch])
        closeSettings.tap()
        returnToFiles(app)
    }

    @MainActor
    func testLibrarySurvivesRepeatedRotation() {
        let app = launchWorkspace()
        openFiles(app)
        app.buttons["workspace.capture"].tap()
        let library = app.buttons["capture.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "capture.library").count, 1)
        XCTAssertFalse(app.buttons["workspace.capture"].exists, "Covered project navigation must not remain accessible")
        library.tap()
        let back = app.buttons["library.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let all = app.segmentedControls.buttons["All"]
        let audio = app.segmentedControls.buttons["Audio"]
        cycle("Library", app: app, elements: [back, all, audio])
        // Check both filter changes after all four rotations, then return to files.
        // The cycle checks each control's geometry and hittability at every turn.
        audio.tap()
        XCTAssertTrue(audio.isSelected, "Audio filter must respond after rotation")
        all.tap()
        XCTAssertTrue(all.isSelected, "All filter must respond after rotation")
        back.tap()
        returnToFiles(app)
    }
}
