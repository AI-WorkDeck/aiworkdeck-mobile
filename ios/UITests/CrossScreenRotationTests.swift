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
        let geometry = XCTAttachment(string: (["app=\(app.frame)"] + elements.map { "\($0.identifier) \($0.label): frame=\($0.frame), hittable=\($0.isHittable)" }).joined(separator: "\n"))
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
                (app.frame.height > app.frame.width) == (orientation == .portrait)
            }, evaluatedWith: app)
            waitForExpectations(timeout: 15)
            let portrait = orientation == .portrait
            XCTAssertEqual(app.frame.width < app.frame.height, portrait, name + " application orientation")
            for element in elements {
                expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
            }
            waitForExpectations(timeout: 15)
            record(name + " \(orientation.rawValue)", app: app, elements: elements)
            for (index, element) in elements.enumerated() {
                XCTAssertTrue(element.exists, name + " missing " + element.identifier)
                XCTAssertTrue(element.isHittable, name + " unreachable " + element.identifier)
                XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(element.frame), name + " outside window " + element.identifier)
                if portrait {
                    let old = before[index], new = element.frame
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
        cycle("Project list", app: app, elements: [app.buttons["workspace.project.alpha"]])
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
        let settings = app.buttons["capture.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let closeSettings = app.buttons["settings.close"]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 10))
        cycle("Settings", app: app, elements: [closeSettings, app.buttons["settings.switchProject"]])
        closeSettings.tap()
        returnToFiles(app)
    }

    @MainActor
    func testLibrarySurvivesRepeatedRotation() {
        let app = launchWorkspace()
        openFiles(app)
        app.buttons["workspace.capture"].tap()
        let library = app.buttons["capture.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        cycle("Library", app: app, elements: [back, app.segmentedControls.buttons["All"], app.segmentedControls.buttons["Audio"]])
        back.tap()
        returnToFiles(app)
    }
}
