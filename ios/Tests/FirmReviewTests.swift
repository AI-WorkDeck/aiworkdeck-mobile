// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

/// Firm review (docs/specs/2026-11-19-firm-review.md): grouping, diff, host allowlist, portal client, sign-off guard.
final class FirmReviewTests: XCTestCase {
    private func summary(_ id: String, status: String, attention: String? = nil, consult: String? = nil) -> FirmMatterSummary {
        FirmMatterSummary(id: id, status: status, updatedAt: "2026-11-19T08:00:00.000Z", template: FirmName(en: "SAFE", zh: "SAFE"),
                          client: "Ada", company: "Acme", versions: 1, lawyerName: nil,
                          consult: consult.map { FirmConsult(status: $0, times: nil, note: nil, lawyerName: nil) },
                          forLawyerCount: 2, wantsCall: false, attention: attention)
    }

    func testInboxPutsWhatNeedsTheLawyerFirst() {
        let list = [
            summary("signed", status: "signed"),
            summary("waiting", status: "awaiting_client"),
            summary("call", status: "in_review", consult: "requested"),
            summary("review", status: "review"),
            summary("replied", status: "awaiting_client", attention: "client_replied"),
            summary("drafted", status: "drafted"),
        ]
        let groups = FirmInbox.grouped(list)
        XCTAssertEqual(groups.map(\.0), [.needsYou, .waiting, .inProgress, .done])
        XCTAssertEqual(groups[0].1.map(\.id), ["call", "review", "replied"])
        XCTAssertEqual(FirmInbox.reason(list[2]), "call_requested")
        XCTAssertEqual(FirmInbox.reason(list[3]), "review_requested")
        XCTAssertEqual(FirmInbox.reason(list[4]), "client_replied")
        XCTAssertNil(FirmInbox.reason(list[1]))
    }

    func testPortalAttentionFieldOverridesDerivation() {
        // A portal that reports attention: "" (nothing pending) is trusted over the status-based guess.
        let m = summary("x", status: "review", attention: "")
        XCTAssertNil(FirmInbox.reason(m))
        XCTAssertEqual(FirmInbox.group(m), .inProgress)
    }

    func testDiffShowsOnlyChangedParagraphs() {
        let old = "# SAFE\n\nThe valuation cap is $8M.\n\nGoverning law: Delaware."
        let new = "# SAFE\n\nThe valuation cap is $10M.\n\nGoverning law: Delaware.\n\nPro rata rights apply."
        XCTAssertEqual(FirmDiff.edits(from: old, to: new), [
            .removed("The valuation cap is $8M."), .added("The valuation cap is $10M."), .added("Pro rata rights apply."),
        ])
        XCTAssertEqual(FirmDiff.edits(from: old, to: old), [])
        XCTAssertEqual(FirmDiff.edits(from: "", to: "A"), [.added("A")])
    }

    func testOnlyAllowlistedHttpsPortalsReceiveTheSession() {
        let allowed = ["aifirm.aiworkdeck.com/all", "aifirm.aiworkdeck.com/sv", "aifirm.aiworkdeck.com/tw"]
        XCTAssertEqual(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/sv/", allowed: allowed), "aifirm.aiworkdeck.com/sv")
        XCTAssertEqual(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/sv/v2/#m=abc", allowed: allowed), "aifirm.aiworkdeck.com/sv")
        XCTAssertEqual(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/tw/", allowed: allowed), "aifirm.aiworkdeck.com/tw")
        XCTAssertEqual(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/TW", allowed: allowed), "aifirm.aiworkdeck.com/tw")
        XCTAssertEqual(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/", allowed: allowed), "aifirm.aiworkdeck.com/all")
        XCTAssertEqual(FirmPortalLink.portal(from: "aifirm.aiworkdeck.com", allowed: allowed), "aifirm.aiworkdeck.com/all")
        XCTAssertEqual(FirmPortalLink.portal(from: " AIFIRM.aiworkdeck.com/sv ", allowed: allowed), "aifirm.aiworkdeck.com/sv")
        XCTAssertNil(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/twx/", allowed: allowed))
        XCTAssertNil(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com/ces/", allowed: allowed))
        XCTAssertNil(FirmPortalLink.portal(from: "http://aifirm.aiworkdeck.com/sv/", allowed: allowed))
        XCTAssertNil(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com.evil.example/sv/", allowed: allowed))
        XCTAssertNil(FirmPortalLink.portal(from: "https://evil.example/aifirm.aiworkdeck.com/tw", allowed: allowed))
        XCTAssertNil(FirmPortalLink.portal(from: "https://aifirm.aiworkdeck.com@evil.example/sv/", allowed: allowed))
        XCTAssertNil(FirmPortalLink.portal(from: "", allowed: allowed))
        for office in ["all", "sv", "tw", "jp", "sg"] {
            XCTAssertTrue(ContractCapabilities.firmPortals.contains("aifirm.aiworkdeck.com/" + office), office)
        }
        XCTAssertTrue(FirmPortalLink.isPortalURL(URL(string: "https://aifirm.aiworkdeck.com/tw/m/abc/1.pdf")!))
        XCTAssertFalse(FirmPortalLink.isPortalURL(URL(string: "http://aifirm.aiworkdeck.com/m/abc/1.pdf")!))
        XCTAssertFalse(FirmPortalLink.isPortalURL(URL(string: "https://evil.example/m/abc/1.pdf")!))
    }

    func testOfficePortalUsesItsPathPrefix() async throws {
        let t = RecordingTransport()
        t.next = (Data(#"{"kind":"lawyer","status":"approved","firm":{"en":"Taipei","zh":"台北"},"lawyerName":{"en":"Li Wei","zh":"李伟"}}"#.utf8), 200)
        let me = try await FirmPortalClient(portal: "aifirm.aiworkdeck.com/tw", credential: "awdt_test", transport: t).me()
        XCTAssertEqual(t.requests.last?.url?.absoluteString, "https://aifirm.aiworkdeck.com/tw/api/portal/me")
        XCTAssertEqual(me.lawyerName?.en, "Li Wei")
    }

    func testClientSendsBearerAndMapsPortalErrors() async throws {
        let t = RecordingTransport()
        let client = FirmPortalClient(portal: "aifirm.aiworkdeck.com/sv", credential: "awdt_test", transport: t)
        t.next = (Data(#"{"kind":"lawyer","name":"Li","status":"approved","lawyerId":"l1"}"#.utf8), 200)
        let me = try await client.me()
        XCTAssertEqual(me.name, "Li")
        let req = try XCTUnwrap(t.requests.last)
        XCTAssertEqual(req.url?.absoluteString, "https://aifirm.aiworkdeck.com/sv/api/portal/me")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer awdt_test")

        t.next = (Data(#"{"error":"version_changed"}"#.utf8), 409)
        do { _ = try await client.signoff("m1", version: 2, name: "Li"); XCTFail("expected an error") }
        catch let e as FirmPortalError { XCTAssertEqual(e.code, "version_changed"); XCTAssertEqual(e.status, 409) }
        let body = try XCTUnwrap(t.requests.last?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual(json["checks"] as? [String: Bool], ["conflicts": true, "engagement": true, "reviewed": true])
    }

    func testClientRefusesHostsOutsideTheContract() async {
        let t = RecordingTransport()
        let client = FirmPortalClient(portal: "evil.example", credential: "awdt_test", transport: t)
        do { _ = try await client.me(); XCTFail("expected refusal") }
        catch let e as FirmPortalError { XCTAssertEqual(e.code, "host_not_allowed") }
        catch { XCTFail("\(error)") }
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testMatterDecodesPortalShapeAndSettlements() throws {
        let json = #"""
        {"id":"m1","status":"review","updatedAt":"2026-11-19T08:00:00.000Z","template":{"en":"Term sheet","zh":"投资条款清单"},
         "client":"Ada","company":"Acme","lawyerId":"l1","lawyerName":"Li","consult":null,"extra":42,
         "transcript":[{"role":"user","content":"Hi","at":"x"},{"role":"event","content":"draft","version":1}],
         "versions":[{"n":1,"markdown":"A","by":"ai","pdfUrl":"https://aifirm.aiworkdeck.com/m/t/1.pdf","notes":{"changes":[],"flags":[{"id":"f1","level":"high","section":"2","title":"Cap","risk":"r"},{"id":"f2","title":"Board"}]}},
                     {"n":2,"markdown":"B","by":"ai","notes":{"changes":["Raised the cap"],"flags":[{"id":"f1","level":"high","title":"Cap"},{"id":"f2","title":"Board"}],"summary":"s"}}],
         "flagState":{"2":{"f1":"noted","f2":"lawyer"}},"forLawyer":[{"text":"Is the cap market?","section":"2","flag":"f1","version":2,"at":"x"}],"signoff":null}
        """#
        let m = try JSONDecoder().decode(FirmMatter.self, from: Data(json.utf8))
        XCTAssertEqual(m.latest?.n, 2)
        XCTAssertEqual(m.previous?.n, 1)
        let flags = try XCTUnwrap(m.latest?.notes?.flags)
        XCTAssertEqual(flags.map { m.settlement(of: $0) }, ["noted", "lawyer"])
        XCTAssertEqual(FirmMatterView.settlementKey("noted"), "firm.flag.noted")
        XCTAssertEqual(FirmMatterView.settlementKey(nil), "firm.flag.open")
        XCTAssertEqual(m.forLawyer?.first?.text, "Is the cap market?")
    }

    func testSignoffNeedsEveryConfirmationAndAName() {
        XCTAssertTrue(FirmSignoffSheet.ready(conflicts: true, engagement: true, reviewed: true, name: "Li"))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: true, engagement: true, reviewed: true, name: "  "))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: false, engagement: true, reviewed: true, name: "Li"))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: true, engagement: false, reviewed: true, name: "Li"))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: true, engagement: true, reviewed: false, name: "Li"))
    }

    func testAccountScopeSeparatesAccountsAndRegions() {
        let cn = URL(string: "https://addin.aiworkdeck.com")!, intl = URL(string: "https://addin.workdeck.ai")!
        XCTAssertNotEqual(FirmPortal.accountScope(userID: 1, base: cn), FirmPortal.accountScope(userID: 2, base: cn))
        XCTAssertNotEqual(FirmPortal.accountScope(userID: 1, base: cn), FirmPortal.accountScope(userID: 1, base: intl))
        XCTAssertEqual(FirmPortal.accountScope(userID: 1, base: cn), FirmPortal.accountScope(userID: 1, base: cn))
    }

    func testEveryFirmStringExistsInAllLocales() {
        let keys = ContractStrings.table.keys.filter { $0.hasPrefix("firm.") }
        XCTAssertGreaterThan(keys.count, 60)
        for k in keys { XCTAssertEqual(ContractStrings.table[k]?.count, 20, k) }
    }
}

private final class RecordingTransport: FirmTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var next: (Data, Int) = (Data("{}".utf8), 200)
    func send(_ request: URLRequest) async throws -> (Data, Int) { requests.append(request); return next }
}
