// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

/// X24: screens show userFacingMessage(for:), never a raw system error. Mirrors Android's UserFacingMessage.kt.
final class UserFacingMessageTests: XCTestCase {
    func testAppErrorsKeepTheirOwnText() {
        XCTAssertEqual(userFacingMessage(for: APIError(message: "号码格式不对")), "号码格式不对")
        XCTAssertEqual(userFacingMessage(for: SessionSaveError(status: -25300)), tr("error.sessionSaveFailed"))
        XCTAssertEqual(userFacingMessage(for: FirmPortalError(code: "version_changed", status: 409)), tr("firm.error.versionChanged"))
    }

    func testSystemErrorsAreMappedToTheDictionary() {
        XCTAssertEqual(userFacingMessage(for: URLError(.cannotFindHost)), tr("error.unreachable"))
        XCTAssertEqual(userFacingMessage(for: URLError(.timedOut)), tr("error.network"))
        struct Probe: Decodable { let x: Int }
        do { _ = try JSONDecoder().decode(Probe.self, from: Data("{}".utf8)); XCTFail("expected a DecodingError") }
        catch { XCTAssertEqual(userFacingMessage(for: error), tr("error.badResponse")) }
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "The file “x” doesn’t exist."])
        XCTAssertEqual(userFacingMessage(for: cocoa), tr("error.network"))
        XCTAssertEqual(userFacingMessage(for: cocoa, fallback: tr("error.generic")), tr("error.generic"))
    }

    /// Source guard: no screen or the app model reads error.localizedDescription directly.
    func testScreensDoNotShowRawLocalizedDescription() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var offenders: [String] = []
        let roots = [sources.appendingPathComponent("Features"), sources.appendingPathComponent("App")]
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("error.localizedDescription") { offenders.append(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(offenders, [], "use userFacingMessage(for:) instead of error.localizedDescription")
    }
}
