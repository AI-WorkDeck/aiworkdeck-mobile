// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class PrivacyConsentTests: XCTestCase {
    private let suite = "PrivacyConsentTests"
    private var defaults: UserDefaults!
    override func setUp() { super.setUp(); defaults = UserDefaults(suiteName: suite); defaults.removePersistentDomain(forName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    func testConsentIsForTheCurrentPolicyVersionOnly() {
        XCTAssertFalse(PrivacyConsent.accepted(in: defaults))
        defaults.set("2020-01-01", forKey: PrivacyConsent.key)
        XCTAssertFalse(PrivacyConsent.accepted(in: defaults), "a new policy version asks again")
        PrivacyConsent.accept(in: defaults)
        XCTAssertTrue(PrivacyConsent.accepted(in: defaults))
        XCTAssertEqual(defaults.string(forKey: PrivacyConsent.key), ContractCapabilities.privacyPolicyVersion)
    }

    func testFirstLaunchShowsTheGateUnlessAutomationSkipsIt() {
        XCTAssertFalse(PrivacyConsent.initiallyAccepted(arguments: [], defaults: defaults))
        XCTAssertTrue(PrivacyConsent.initiallyAccepted(arguments: ["-AWDWorkspaceUITest"], defaults: defaults))
        XCTAssertFalse(PrivacyConsent.initiallyAccepted(arguments: ["-AWDLoginUITest", PrivacyConsent.forceArgument], defaults: defaults))
        PrivacyConsent.accept(in: defaults)
        XCTAssertTrue(PrivacyConsent.initiallyAccepted(arguments: [], defaults: defaults))
        XCTAssertFalse(PrivacyConsent.initiallyAccepted(arguments: [PrivacyConsent.forceArgument], defaults: defaults), "a test can always see the gate")
    }
}
