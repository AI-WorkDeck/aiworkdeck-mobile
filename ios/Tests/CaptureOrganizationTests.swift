// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class CaptureOrganizationTests: XCTestCase {
    func testConsentIsOffByDefaultAndIsolatedBySessionAndSite() throws {
        let nonce = UUID().uuidString
        let a = CaptureOrganizationStore.scope(baseURL: URL(string: "https://a.invalid")!, sessionID: nonce)!
        let b = CaptureOrganizationStore.scope(baseURL: URL(string: "https://b.invalid")!, sessionID: nonce)!
        let c = CaptureOrganizationStore.scope(baseURL: URL(string: "https://a.invalid")!, sessionID: nonce + "-new")!
        defer { CaptureOrganizationStore.setEnabled(false, scope: a) }
        XCTAssertFalse(CaptureOrganizationStore.enabled(scope: a))
        CaptureOrganizationStore.setEnabled(true, scope: a)
        XCTAssertTrue(CaptureOrganizationStore.enabled(scope: a))
        XCTAssertFalse(CaptureOrganizationStore.enabled(scope: b))
        XCTAssertFalse(CaptureOrganizationStore.enabled(scope: c))
        XCTAssertFalse(CaptureOrganizationStore.enabled(scope: nil))
        XCTAssertFalse(a.contains(nonce))
    }
    func testResultRoundTripPreservesOriginalAndArchiveNamesAndScope() throws {
        let scope = UUID().uuidString, id = UUID()
        let json = #"{"state":"ready","originalName":"original.jpg","fileName":"certificate.jpg","archiveName":"certificate-uuid.jpg","tags":["Certificate"],"fields":{"identifier":"TEST-1"}}"#
        let result = try JSONDecoder().decode(CaptureOrganization.self, from: Data(json.utf8))
        CaptureOrganizationStore.save(result, id: id, scope: scope)
        defer { UserDefaults.standard.removeObject(forKey: "captureOrganize.result." + scope + "." + id.uuidString.lowercased()) }
        let stored = try XCTUnwrap(CaptureOrganizationStore.result(id: id, scope: scope))
        XCTAssertEqual(stored.originalName, "original.jpg")
        XCTAssertEqual(stored.archiveName, "certificate-uuid.jpg")
        XCTAssertEqual(stored.tags, ["Certificate"])
        XCTAssertNil(CaptureOrganizationStore.result(id: id, scope: scope + "other"))
        CaptureOrganizationStore.removeResults(ids: [id])
        XCTAssertNil(CaptureOrganizationStore.result(id: id, scope: scope))
    }
}
