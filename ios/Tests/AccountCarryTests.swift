// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

/// The carry file mirrors the Keychain so a future Team ID change doesn't sign users out (Q17, POLISH M23).
final class AccountCarryTests: XCTestCase {
    private var saved: URL!
    override func setUp() {
        super.setUp()
        saved = AccountCarry.directory
        AccountCarry.directory = FileManager.default.temporaryDirectory.appendingPathComponent("carry-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: AccountCarry.directory)
        AccountCarry.directory = saved
        super.tearDown()
    }

    func testMirrorsSessionAndFirmCodesAndDisappearsWhenEmpty() throws {
        XCTAssertNil(AccountCarry.read())
        AccountCarry.setSession("awdt_1")
        AccountCarry.setFirmTrial("TRIAL", scope: "scope|ai-firm.aiworkdeck.com/tw")
        XCTAssertEqual(AccountCarry.read(), .init(sessionId: "awdt_1", firmTrial: ["scope|ai-firm.aiworkdeck.com/tw": "TRIAL"]))
        AccountCarry.setSession(nil)
        XCTAssertEqual(AccountCarry.read()?.sessionId, nil, "sign-out removes the session copy")
        XCTAssertEqual(AccountCarry.read()?.firmTrial.count, 1)
        AccountCarry.setFirmTrial(nil, scope: "scope|ai-firm.aiworkdeck.com/tw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AccountCarry.fileURL.path), "nothing left: no file")
    }

    func testNeverGoesIntoBackups() throws {
        AccountCarry.setSession("awdt_1")
        let values = try AccountCarry.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let dir = try AccountCarry.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(dir.isExcludedFromBackup, true)
    }

    func testACorruptFileIsReplacedNotTrusted() throws {
        try FileManager.default.createDirectory(at: AccountCarry.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: AccountCarry.fileURL)
        XCTAssertNil(AccountCarry.read())
        AccountCarry.setSession("awdt_2")
        XCTAssertEqual(AccountCarry.read()?.sessionId, "awdt_2")
    }
}
