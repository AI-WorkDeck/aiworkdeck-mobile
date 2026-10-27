// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest

extension XCTestCase {
    @MainActor func openPersonalCapture(_ app: XCUIApplication) {
        let entry = app.tabBars.buttons["Capture"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
    }
    @MainActor func openPersonalProjects(_ app: XCUIApplication) {
        let close = app.buttons["capture.close"]
        if close.exists && close.isHittable { close.tap(); return }
        let entry = app.tabBars.buttons["Projects"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
    }
}
