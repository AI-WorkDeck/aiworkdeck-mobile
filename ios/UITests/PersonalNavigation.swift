// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

enum PersonalTab: String {
    case assistant = "Personal assistant", calendar = "Calendar", projects = "Projects", capture = "Capture"
    var icon: String {
        switch self {
        case .assistant: return "bubble.left.and.bubble.right"
        case .calendar: return "calendar"
        case .projects: return "folder"
        case .capture: return "camera"
        }
    }
}

extension XCTestCase {
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
        let entry = personalTab(app, .capture)
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertTrue(entry.isHittable)
        entry.tap()
    }
    @MainActor func openPersonalProjects(_ app: XCUIApplication) {
        let close = app.buttons["capture.close"]
        if close.exists && close.isHittable { close.tap(); return }
        let entry = personalTab(app, .projects)
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertTrue(entry.isHittable)
        entry.tap()
    }
}
