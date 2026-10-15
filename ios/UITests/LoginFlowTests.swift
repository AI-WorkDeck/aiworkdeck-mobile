import XCTest

/// UI-only, synthetic input. This never submits a password or requests a code.
final class LoginFlowTests: XCTestCase {
    @MainActor
    func testPasswordEntryAndReviewSwitch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AWDLoginUITest"]
        app.launch()
        let identity = app.textFields["login.identity"]
        let password = app.secureTextFields["login.password"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        XCTAssertTrue(password.exists)
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        XCTAssertTrue(app.buttons["login.register"].exists)
        XCTAssertTrue(app.buttons["login.reset"].exists)
        password.tap()
        password.typeText("synthetic-password")
        app.swipeUp()
        let review = app.buttons["login.review"]
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        review.tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Password login and account setup entries"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
