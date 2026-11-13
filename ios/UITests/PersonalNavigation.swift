// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

struct ControlSnapshotState {
    let frame: CGRect
    let label: String
    let enabled: Bool

    static func isReady(window: CGRect, matches: [Self], portrait: Bool?, label: String?,
                        hitTest: () -> Bool) -> Bool {
        guard !window.isEmpty, matches.count == 1,
              let state = matches.first, !state.frame.isEmpty, state.enabled,
              window.contains(state.frame),
              portrait.map({ (window.height > window.width) == $0 }) ?? true,
              label.map({ state.label == $0 }) ?? true else { return false }
        return hitTest()
    }
}

@MainActor
struct ReadyControl {
    let element: XCUIElement
    let identifier: String?
    var label: String? = nil
    var type: XCUIElement.ElementType = .button

    func states(in tree: XCUIElementSnapshot) -> [ControlSnapshotState] {
        var result: [ControlSnapshotState] = []
        func visit(_ node: XCUIElementSnapshot) {
            let identityMatches = identifier.map { node.identifier == $0 } ?? (label != nil)
            let labelMatches = label.map { node.label == $0 } ?? true
            if identityMatches && labelMatches && (type == .any || node.elementType == type) {
                result.append(ControlSnapshotState(frame: node.frame, label: node.label, enabled: node.isEnabled))
            }
            node.children.forEach(visit)
        }
        visit(tree)
        return result
    }
}

struct ReadyControlSnapshot {
    let window: CGRect
    let control: ControlSnapshotState
}

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
    @MainActor func waitForReadyOrientation(in app: XCUIApplication, portrait: Bool, timeout: TimeInterval,
                                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let condition = NSPredicate { _, _ in
            if self.allowVisibleRecordingPermission() { return false }
            guard let tree = try? app.snapshot(), !tree.frame.isEmpty else { return false }
            return (tree.frame.height > tree.frame.width) == portrait
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: app)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Application did not reach the requested orientation", file: file, line: line)
        return result == .completed
    }

    @MainActor func waitForReadyControl(_ target: ReadyControl, in app: XCUIApplication,
                                        portrait: Bool? = nil, timeout: TimeInterval,
                                        boundsTolerance: CGFloat = 0,
                                        file: StaticString = #filePath, line: UInt = #line) -> ReadyControlSnapshot? {
        var ready: ReadyControlSnapshot?
        var previousFrame: CGRect?
        let condition = NSPredicate { _, _ in
            // A permission tap ends this poll. Never mix its transition with app AX queries.
            if self.allowVisibleRecordingPermission() { return false }
            guard let tree = try? app.snapshot() else { return false }
            let matches = target.states(in: tree)
            let window = tree.frame.insetBy(dx: -boundsTolerance, dy: -boundsTolerance)
            // Only hit-test once the control has held the same frame for two polls. During a
            // rotation animation the live element can briefly have no valid activation point,
            // and XCTest records that as a hard failure instead of returning false.
            let frame = matches.count == 1 ? matches[0].frame : nil
            defer { previousFrame = frame }
            guard frame != nil, frame == previousFrame else { return false }
            guard !tree.frame.isEmpty,
                  ControlSnapshotState.isReady(window: window, matches: matches, portrait: portrait,
                                               label: target.label, hitTest: { target.element.isHittable }) else { return false }
            ready = ReadyControlSnapshot(window: tree.frame, control: matches[0])
            return true
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: app)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Control did not reach its current visible state: \(target.identifier ?? target.label ?? "unknown")", file: file, line: line)
        return result == .completed ? ready : nil
    }

    @MainActor func dismissEarlierRecordingNotice(in app: XCUIApplication) {
        // The crash-recovery test intentionally retains invalid drafts between runs.
        // Inspect one current tree before querying an optional alert. A nested query
        // for an absent alert can stall AX snapshot retries on the Duo runtime.
        guard let tree = try? app.snapshot() else {
            XCTFail("Could not inspect the current recording notice state"); return
        }
        let titles = ["Recording status", "录音状态", "錄音狀態"]
        func recordingAlert(in node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.elementType == .alert && titles.contains(node.label) { return node }
            for child in node.children {
                if let found = recordingAlert(in: child) { return found }
            }
            return nil
        }
        guard let alertTree = recordingAlert(in: tree) else { return }
        let notice = app.alerts[alertTree.label]
        guard let label = ["Close", "关闭", "關閉"].first(where: {
            !ReadyControl(element: notice.buttons[$0], identifier: nil, label: $0).states(in: alertTree).isEmpty
        }) else { XCTFail("Recording notice has no close control"); return }
        let close = notice.buttons[label]
        let target = ReadyControl(element: close, identifier: nil, label: label)
        let condition = NSPredicate { _, _ in
            guard let current = try? app.snapshot(), let alert = recordingAlert(in: current),
                  alert.label == alertTree.label else { return false }
            return ControlSnapshotState.isReady(window: current.frame, matches: target.states(in: alert),
                portrait: nil, label: label, hitTest: { close.isHittable })
        }
        let ready = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: app)], timeout: 5)
        XCTAssertEqual(ready, .completed, "Recording notice close control did not become ready")
        guard ready == .completed else { return }
        close.tap()
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
        let browse = app.buttons["projectPicker.none"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(browse.isHittable)
        browse.tap()
        XCTAssertTrue(app.buttons["workspace.close"].waitForExistence(timeout: 10))
        if !app.buttons["workspace.project.alpha"].isHittable {
            // Duo puts the native back control in its side toolbar, without a label.
            let sideBack = app.buttons["BackButton"]
            if sideBack.exists {
                sideBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Projects", "Back"])).firstMatch
                if back.exists { back.tap() }
            }
        }
    }

    @MainActor func allowVisibleRecordingPermission() -> Bool {
        let permissionAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard permissionAlert.exists else { return false }
        // iOS 27 的权限弹窗里同名按钮可能出现两次，按下标取会报「多个匹配」
        for label in ["Allow", "允许", "OK"] where permissionAlert.buttons[label].firstMatch.exists {
            permissionAlert.buttons[label].firstMatch.tap()
            return true
        }
        // An unrecognized system alert must also prevent querying covered app controls.
        return true
    }

    @MainActor func startAudioRecordingWithOneTap(_ app: XCUIApplication) {
        let start = app.buttons["capture.recordAudio"]
        guard waitForReadyControl(ReadyControl(element: start, identifier: "capture.recordAudio"),
                                  in: app, timeout: 15) != nil else { return }
        start.tap()
        let recording = ReadyControl(element: app.buttons["capture.shutter"], identifier: "capture.shutter", label: "Stop recording")
        let elapsed = ReadyControl(element: app.staticTexts["recording.elapsed"], identifier: "recording.elapsed", type: .staticText)
        // Permission prompts may follow each other; never tap Record again to recover.
        expectation(for: NSPredicate { _, _ in
            // Let the next poll recheck system prompts before querying the app
            // immediately after a permission transition.
            if self.allowVisibleRecordingPermission() { return false }
            guard let tree = try? app.snapshot() else { return false }
            guard ControlSnapshotState.isReady(window: tree.frame, matches: elapsed.states(in: tree),
                                               portrait: nil, label: nil, hitTest: { true }) else { return false }
            return ControlSnapshotState.isReady(window: tree.frame, matches: recording.states(in: tree),
                                                portrait: nil, label: recording.label, hitTest: { recording.element.isHittable })
        }, evaluatedWith: app)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.buttons["capture.mode.audio"].exists)
    }
}
