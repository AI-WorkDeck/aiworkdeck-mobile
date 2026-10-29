// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

enum PersonalTab: String {
    case assistant = "Personal assistant", calendar = "Calendar", capture = "Capture"
    var icon: String {
        switch self {
        case .assistant: return "bubble.left.and.bubble.right"
        case .calendar: return "calendar"
        case .capture: return "camera"
        }
    }
}

extension XCTestCase {
    @MainActor func dismissEarlierRecordingNotice(in app: XCUIApplication) {
        // The crash-recovery test intentionally retains invalid drafts between runs.
        let notice = app.alerts.matching(NSPredicate(format: "label IN %@",
            ["Recording status", "录音状态", "錄音狀態"])).firstMatch
        if notice.waitForExistence(timeout: 2) {
            notice.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "關閉"])).firstMatch.tap()
        }
    }

    @MainActor func personalTab(_ app: XCUIApplication, _ tab: PersonalTab) -> XCUIElement {
        // iPhone exposes a TabBar; Duo exposes the same buttons in its side Toolbar.
        // Match the icon descendant: SwiftUI does not always forward its identifier
        // to the parent button after the app language changes. This also excludes
        // the assistant menu, whose label is identical but whose icon is different.
        app.buttons.matching(NSPredicate(format: "label == %@", tab.rawValue))
            .containing(NSPredicate(format: "identifier IN %@", [tab.icon, tab.icon + ".fill"]))
            .firstMatch
    }
    @MainActor func openPersonalCapture(_ app: XCUIApplication) {
        dismissEarlierRecordingNotice(in: app)
        let workspaceClose = app.buttons["workspace.close"]
        if workspaceClose.exists && workspaceClose.isHittable { workspaceClose.tap() }
        let entry = personalTab(app, .capture)
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        // A seeded recording alert can cover the already selected capture tab.
        if app.buttons["capture.shutter"].exists && !app.buttons["capture.close"].exists { return }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.buttons["capture.shutter"].waitForExistence(timeout: 10))
    }

    @MainActor func openPersonalProjects(_ app: XCUIApplication) {
        let close = app.buttons["capture.close"]
        if close.exists && close.isHittable { close.tap(); return }
        if app.buttons["workspace.close"].exists { return }
        openPersonalCapture(app)
        let project = app.buttons["capture.project"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertTrue(project.isHittable)
        project.tap()
        let browse = app.buttons["projectPicker.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(browse.isHittable)
        browse.tap()
        XCTAssertTrue(app.buttons["workspace.close"].waitForExistence(timeout: 10))
    }

    @MainActor func startAudioRecordingWithOneTap(_ app: XCUIApplication) {
        let start = app.buttons["capture.recordAudio"]
        let permissionAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        func allowVisiblePermission() {
            guard permissionAlert.exists else { return }
            for label in ["Allow", "允许", "OK"] where permissionAlert.buttons[label].exists {
                permissionAlert.buttons[label].tap()
                break
            }
        }
        expectation(for: NSPredicate { _, _ in
            allowVisiblePermission()
            return start.exists && start.isEnabled && start.isHittable
        }, evaluatedWith: start)
        waitForExpectations(timeout: 15)
        start.tap()
        let shutter = app.buttons["capture.shutter"]
        // Permission prompts may follow each other; never tap Record again to recover.
        expectation(for: NSPredicate { _, _ in
            allowVisiblePermission()
            return shutter.label == "Stop recording" && app.staticTexts["recording.elapsed"].exists
        }, evaluatedWith: shutter)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.buttons["capture.mode.audio"].exists)
    }
}
