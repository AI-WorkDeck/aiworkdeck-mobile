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
    private func record(_ name: String, states: [ReadyControlSnapshot]) {
        let geometry = XCTAttachment(string: states.map {
            "window=\($0.window), label=\($0.control.label), frame=\($0.control.frame)"
        }.joined(separator: "\n"))
        geometry.name = name + " geometry"; geometry.lifetime = .keepAlways; add(geometry)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    private func cycle(_ name: String, app: XCUIApplication, controls: [ReadyControl]) {
        Thread.sleep(forTimeInterval: 1)
        guard let baseline = try? app.snapshot() else { XCTFail(name + " missing baseline snapshot"); return }
        let before = controls.map { $0.states(in: baseline) }
        guard before.allSatisfy({ $0.count == 1 }) else { XCTFail(name + " missing or ambiguous baseline controls"); return }
        record(name + " portrait before", states: before.map { ReadyControlSnapshot(window: baseline.frame, control: $0[0]) })
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let portrait = orientation == .portrait
            guard waitForReadyOrientation(in: app, portrait: portrait, timeout: 15) else { return }
            var states: [ReadyControlSnapshot] = []
            // Each control keeps its existing 15-second budget. Window, identity,
            // label and geometry are validated from one tree before live hit testing.
            for (index, control) in controls.enumerated() {
                guard let ready = waitForReadyControl(control, in: app, portrait: portrait, timeout: 15, boundsTolerance: 1) else { return }
                states.append(ready)
                if portrait {
                    let old = before[index][0].frame, new = ready.control.frame
                    XCTAssertEqual(old.minX, new.minX, accuracy: 2, name + " x after returning")
                    XCTAssertEqual(old.minY, new.minY, accuracy: 2, name + " y after returning")
                    XCTAssertEqual(old.width, new.width, accuracy: 2, name + " width after returning")
                    XCTAssertEqual(old.height, new.height, accuracy: 2, name + " height after returning")
                }
            }
            record(name + " \(orientation.rawValue)", states: states)
        }
    }

    func testReadinessRejectsStaleStateBeforeHitTesting() {
        let window = CGRect(x: 0, y: 0, width: 956, height: 440)
        let valid = ControlSnapshotState(frame: CGRect(x: 80, y: 120, width: 76, height: 76), label: "Stop recording", enabled: true)
        var calls = 0
        func ready(_ matches: [ControlSnapshotState], portrait: Bool = false, hit: Bool = true) -> Bool {
            ControlSnapshotState.isReady(window: window, matches: matches, portrait: portrait,
                                         label: "Stop recording") { calls += 1; return hit }
        }
        XCTAssertFalse(ready([], hit: true))
        XCTAssertFalse(ready([valid, valid]))
        XCTAssertFalse(ready([valid], portrait: true))
        XCTAssertFalse(ready([ControlSnapshotState(frame: .zero, label: valid.label, enabled: true)]))
        XCTAssertFalse(ready([ControlSnapshotState(frame: CGRect(x: 182, y: 694, width: 76, height: 76), label: valid.label, enabled: true)]))
        XCTAssertFalse(ready([ControlSnapshotState(frame: valid.frame, label: "Take photo", enabled: true)]))
        XCTAssertFalse(ready([ControlSnapshotState(frame: valid.frame, label: valid.label, enabled: false)]))
        XCTAssertEqual(calls, 0, "Stale or ambiguous states must not query hittability")
        XCTAssertFalse(ready([valid], hit: false))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(ready([valid]))
        XCTAssertEqual(calls, 2, "Each valid poll performs exactly one live hit query")
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
        guard let tree = try? app.snapshot() else { XCTFail("Missing returned file-page snapshot"); return }
        let states = [ReadyControl(element: firstFile, identifier: "workspace.file.1"),
                      ReadyControl(element: app.buttons["workspace.capture"], identifier: "workspace.capture")].map { $0.states(in: tree) }
        guard states.allSatisfy({ $0.count == 1 }) else { XCTFail("Returned file-page controls missing or ambiguous"); return }
        XCTAssertTrue(firstFile.isHittable)
        record("Files after nested modals", states: states.map { ReadyControlSnapshot(window: tree.frame, control: $0[0]) })
    }

    @MainActor
    func testProjectListSurvivesRepeatedRotation() {
        let app = launchWorkspace()
        let quickCapture = app.buttons["workspace.quickCapture"]
        let quickCaptureBefore = quickCapture.frame
        cycle("Project list", app: app, controls: [
            ReadyControl(element: app.buttons["workspace.project.alpha"], identifier: "workspace.project.alpha"),
            ReadyControl(element: quickCapture, identifier: "workspace.quickCapture"),
            ReadyControl(element: app.buttons["workspace.library"], identifier: "workspace.library")])
        XCTAssertTrue(quickCapture.isHittable)
        XCTAssertEqual(quickCapture.frame, quickCaptureBefore)
        openFiles(app)
    }

    @MainActor
    func testProjectFilesSurviveRepeatedRotation() {
        let app = launchWorkspace()
        openFiles(app)
        cycle("Project files", app: app, controls: [
            ReadyControl(element: app.buttons["workspace.file.1"], identifier: "workspace.file.1"),
            ReadyControl(element: app.buttons["workspace.capture"], identifier: "workspace.capture"),
            ReadyControl(element: app.textFields["workspace.fileSearch"], identifier: "workspace.fileSearch", type: .textField)])
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
        let account = app.descendants(matching: .any).matching(identifier: "settings.account").firstMatch
        guard let accountIdentity = try? account.snapshot() else { XCTFail("Missing settings account identity"); return }
        cycle("Settings", app: app, controls: [
            ReadyControl(element: closeSettings, identifier: "settings.close"),
            ReadyControl(element: account, identifier: "settings.account", label: accountIdentity.label, type: accountIdentity.elementType)])
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
        cycle("Library", app: app, controls: [ReadyControl(element: back, identifier: "library.close"),
            ReadyControl(element: all, identifier: nil, label: "All"),
            ReadyControl(element: audio, identifier: nil, label: "Audio")])
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
