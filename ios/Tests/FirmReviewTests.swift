// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

/// Firm review (docs/specs/2026-11-19-firm-review.md): grouping, diff, host allowlist, portal client, sign-off guard.
final class FirmReviewTests: XCTestCase {
    // Some tests switch the app language; the rest of the suite expects it unchanged.
    private var savedLocale = ""
    override func setUp() { super.setUp(); savedLocale = L10n.locale }
    override func tearDown() { L10n.locale = savedLocale; super.tearDown() }

    private func summary(_ id: String, status: String, attention: String? = nil, consult: String? = nil) -> FirmMatterSummary {
        FirmMatterSummary(id: id, status: status, updatedAt: "2026-11-19T08:00:00.000Z", template: FirmName(en: "SAFE", zh: "SAFE"),
                          client: "Ada", company: "Acme", versions: 1, lawyerName: nil, lawyerNames: nil,
                          consult: consult.map { FirmConsult(status: $0, times: nil, note: nil, lawyerName: nil, lawyerNames: nil) },
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
        // Formatting only (heading mark, bold, spacing) is not a change.
        XCTAssertEqual(FirmDiff.edits(from: "## 株式会社 章程（定款）\n**第1条** 商号", to: "株式会社 章程（定款）\n第1条  商号"), [])
        // One changed line inside a multi-line article shows only that line.
        let art1 = "第23条（设立时发行的股份）\n每股发行价格为1日元。\n出资额1,000万日元。"
        let art2 = "第23条（设立时发行的股份）\n每股发行价格为1日元。\n出资额3,000万日元。"
        XCTAssertEqual(FirmDiff.edits(from: art1, to: art2), [.removed("出资额1,000万日元。"), .added("出资额3,000万日元。")])
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
        XCTAssertEqual(m.lawyerDisplayName, "Li")  // English-only portals still show a name
        let named = try JSONDecoder().decode(FirmMatter.self, from: Data(json.replacingOccurrences(of: #""lawyerName":"Li","#, with: #""lawyerName":"Morris Tu","lawyerNames":{"en":"Morris Tu","zh":"涂能谋","zht":"涂能謀"},"#).utf8))
        L10n.locale = "zh-Hant"; XCTAssertEqual(named.lawyerDisplayName, "涂能謀")
        L10n.locale = "zh-Hans"; XCTAssertEqual(named.lawyerDisplayName, "涂能谋")
        L10n.locale = "en"; XCTAssertEqual(named.lawyerDisplayName, "Morris Tu")
    }

    func testPortalTextFollowsAppLanguageWithEnglishFallback() throws {
        let n = try JSONDecoder().decode(FirmName.self, from: Data(#"{"en":"Tokyo","zh":"东京","zht":"東京","ja":"東京オフィス","ms":null}"#.utf8))
        XCTAssertEqual(n.text(locale: "en"), "Tokyo")
        XCTAssertEqual(n.text(locale: "zh-Hans"), "东京")
        XCTAssertEqual(n.text(locale: "zh-Hant"), "東京")
        XCTAssertEqual(n.text(locale: "ja"), "東京オフィス")
        XCTAssertEqual(n.text(locale: "ms"), "Tokyo")
        XCTAssertEqual(n.text(locale: "de"), "Tokyo")
        XCTAssertEqual(FirmName(en: nil, zh: "硅谷").text(locale: "fr"), "硅谷")
    }

    func testFlagsShowTheVersionWhereTheyWereSettled() throws {
        let json = #"""
        {"id":"m","status":"review","updatedAt":"x","transcript":[],
         "versions":[{"n":1,"markdown":"A","notes":{"flags":[{"id":"f1","title":"Cap"},{"id":"f2","title":"Law"}]}},
                     {"n":2,"markdown":"B","notes":{"flags":[{"id":"f1","title":"New issue"}]}}],
         "flagState":{"1":{"f1":"noted","f2":"lawyer"}}}
        """#
        let m = try JSONDecoder().decode(FirmMatter.self, from: Data(json.utf8))
        XCTAssertEqual(m.flagsVersion?.n, 1)
        XCTAssertEqual(m.flagsVersion?.notes?.flags?.map { m.settlement(of: $0) }, ["noted", "lawyer"])
        let fresh = try JSONDecoder().decode(FirmMatter.self, from: Data(#"{"id":"m","status":"review","updatedAt":"x","transcript":[],"versions":[{"n":1,"markdown":"A","notes":{"flags":[{"id":"f1"}]}}]}"#.utf8))
        XCTAssertEqual(fresh.flagsVersion?.n, 1)
        XCTAssertNil(fresh.settlement(of: FirmFlag(id: "f1", level: nil, section: nil, title: nil, risk: nil)))
    }

    func testRelativeTimeNeverReadsAsFuture() {
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5))
        L10n.locale = "en"
        XCTAssertFalse(FirmText.ago(soon).lowercased().hasPrefix("in "), FirmText.ago(soon))
    }

    // MARK: Regressions from the bug hunt (2026-11-19)

    @MainActor func testOnlyAnExplicitApprovalOpensTheReviewsTab() {
        XCTAssertEqual(FirmPortal.access(forStatus: "approved"), .approved)
        XCTAssertEqual(FirmPortal.access(forStatus: "revoked"), .revoked)
        XCTAssertEqual(FirmPortal.access(forStatus: "pending"), .pending)
        XCTAssertEqual(FirmPortal.access(forStatus: "rejected"), .pending)
        XCTAssertEqual(FirmPortal.access(forStatus: nil), .pending)
    }

    @MainActor func testANetworkErrorNeverUpgradesAccess() {
        let offline = FirmPortalError(code: "network", status: 0)
        XCTAssertEqual(FirmPortal.access(after: offline, previous: .pending), .pending)
        XCTAssertEqual(FirmPortal.access(after: offline, previous: .revoked), .revoked)
        XCTAssertEqual(FirmPortal.access(after: offline, previous: .approved), .approved)
        XCTAssertEqual(FirmPortal.access(after: offline, previous: .checking), .failed)
        XCTAssertEqual(FirmPortal.access(after: FirmPortalError(code: "http_502", status: 502), previous: .none), .failed)
    }

    @MainActor func testExpiredOrRejectedCredentialsCloseAnApprovedSession() {
        for code in ["trial_expired", "unauthorized", "access_revoked"] {
            XCTAssertEqual(FirmPortal.access(after: FirmPortalError(code: code, status: 401), previous: .approved), .revoked, code)
        }
        XCTAssertEqual(FirmPortal.access(after: FirmPortalError(code: "access_pending", status: 403), previous: .approved), .pending)
    }

    func testANewerDraftsNewFlagsAreNotHiddenBehindSettledOnes() throws {
        let json = #"""
        {"id":"m","status":"review","updatedAt":"x","transcript":[],
         "versions":[{"n":2,"markdown":"A","notes":{"flags":[{"id":"f1","title":"Cap"},{"id":"f2","title":"Law"}]}},
                     {"n":3,"markdown":"B","notes":{"flags":[{"id":"f1","title":"Cap"},{"id":"f2","title":"Law"},{"id":"f3","title":"Board seat"}]}}],
         "flagState":{"2":{"f1":"noted","f2":"kept"}}}
        """#
        let m = try JSONDecoder().decode(FirmMatter.self, from: Data(json.utf8))
        XCTAssertEqual(m.flagsVersion?.n, 2)
        XCTAssertEqual(m.newFlags.map(\.title), ["Board seat"])
        // Re-listed flags with fresh ids but the same titles are not "new".
        let relisted = try JSONDecoder().decode(FirmMatter.self, from: Data(json.replacingOccurrences(of: #"{"id":"f3","title":"Board seat"}"#, with: #"{"id":"f3","title":"**Cap**"}"#).utf8))
        XCTAssertEqual(relisted.newFlags.count, 0)
    }

    func testHeadingFollowedByBodyOnTheNextLineRendersAsHeadingThenBody() {
        let b = FirmMarkdown.blocks("## 第1条（商号）\n当会社は…と称する。\n第二行\n\n正文段落")
        XCTAssertEqual(b.map(\.level), [2, 0, 0])
        XCTAssertEqual(b.map(\.text), ["第1条（商号）", "当会社は…と称する。\n第二行", "正文段落"])
    }

    func testUnderscoreBlanksAreContentInTheDiff() {
        XCTAssertFalse(FirmDiff.edits(from: "金额：______元", to: "金额：____元").isEmpty)
        XCTAssertEqual(FirmDiff.edits(from: "条款", to: "条款\n________"), [.added("________")])
    }

    func testSignoffNeedsEveryConfirmationAndASigner() {
        let li = FirmPortal.Signer(name: "Li", demo: false)
        XCTAssertTrue(FirmSignoffSheet.ready(conflicts: true, engagement: true, reviewed: true, signer: li))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: true, engagement: true, reviewed: true, signer: nil))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: false, engagement: true, reviewed: true, signer: li))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: true, engagement: false, reviewed: true, signer: li))
        XCTAssertFalse(FirmSignoffSheet.ready(conflicts: true, engagement: true, reviewed: false, signer: li))
    }

    /// The signature is the signed-in identity, never typed, and matches what the portal records:
    /// a roster lawyer signs as themself; a trial code or an unlinked demo account as the matter's lawyer, marked demo.
    func testSignerComesFromIdentityNotTyping() {
        func signer(_ kind: String?, demo: Bool = false, roster: String? = nil, account: String? = nil, matter: String? = "Matter Lawyer") -> FirmPortal.Signer? {
            FirmPortal.signer(kind: kind, demo: demo, rosterName: roster, title: "國際合夥人", office: "台北",
                              accountName: account, matterLawyer: matter, firmName: "Firm")
        }
        XCTAssertEqual(signer("lawyer", roster: "涂能謀", account: "morris"),
                       FirmPortal.Signer(name: "涂能謀", detail: "國際合夥人 · 台北", demo: false))
        XCTAssertEqual(signer("lawyer", demo: true, roster: "涂能謀"), FirmPortal.Signer(name: "涂能謀", detail: "國際合夥人 · 台北", demo: false))
        XCTAssertEqual(signer("lawyer", account: "Li Wei"), FirmPortal.Signer(name: "Li Wei", demo: false),
                       "An unlinked full account signs under its own name, never another lawyer's")
        XCTAssertNil(signer("lawyer", account: ""))
        XCTAssertEqual(signer("lawyer", demo: true, account: "App Review"), FirmPortal.Signer(name: "Matter Lawyer", demo: true))
        XCTAssertEqual(signer("trial"), FirmPortal.Signer(name: "Matter Lawyer", demo: true))
        XCTAssertEqual(signer("trial", matter: nil), FirmPortal.Signer(name: "Firm", demo: true))
    }

    func testAccountScopeSeparatesAccountsAndRegions() {
        let cn = URL(string: "https://addin.aiworkdeck.com")!, intl = URL(string: "https://addin.workdeck.ai")!
        XCTAssertNotEqual(FirmPortal.accountScope(userID: 1, base: cn), FirmPortal.accountScope(userID: 2, base: cn))
        XCTAssertNotEqual(FirmPortal.accountScope(userID: 1, base: cn), FirmPortal.accountScope(userID: 1, base: intl))
        XCTAssertEqual(FirmPortal.accountScope(userID: 1, base: cn), FirmPortal.accountScope(userID: 1, base: cn))
    }

    func testPartnerNetworkOfficesAreAllowlistedWithoutARootPortal() {
        XCTAssertEqual(FirmPortalLink.portal(from: "https://ai-firm.aiworkdeck.com/sv/v2/"), "ai-firm.aiworkdeck.com/sv")
        XCTAssertEqual(FirmPortalLink.portal(from: "ai-firm.aiworkdeck.com/tw"), "ai-firm.aiworkdeck.com/tw")
        XCTAssertNil(FirmPortalLink.portal(from: "https://ai-firm.aiworkdeck.com/"), "the host has no all-offices portal")
        XCTAssertNil(FirmPortalLink.portal(from: "https://ai-firm.aiworkdeck.com/jp/"))
        XCTAssertTrue(FirmPortalLink.isPortalURL(URL(string: "https://ai-firm.aiworkdeck.com/tw/m/abc/1.pdf")!))
    }

    func testFinaliseSendsTheLawyersOwnDetailsOnlyWhenGiven() async throws {
        let t = RecordingTransport()
        t.next = (Data(#"{"ok":true,"finalPdf":null}"#.utf8), 200)
        let client = FirmPortalClient(portal: "ai-firm.aiworkdeck.com/tw", credential: "awdt_test", transport: t)
        func body() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(t.requests.last?.httpBody)) as? [String: Any])
        }
        _ = try await client.signoff("m1", version: 1, name: "Han", details: ["firm": "Han & Partners", "title": "Partner", "admission": "Beijing"])
        XCTAssertEqual(try body()["firm"] as? String, "Han & Partners")
        XCTAssertEqual(try body()["title"] as? String, "Partner")
        XCTAssertEqual(try body()["admission"] as? String, "Beijing")
        _ = try await client.signoff("m1", version: 1, name: "Han", details: ["firm": "", "title": "Partner", "admission": ""])
        XCTAssertNil(try body()["firm"])
        XCTAssertNil(try body()["admission"])
        XCTAssertEqual(try body()["title"] as? String, "Partner")
        _ = try await client.signoff("m1", version: 1, name: "Han")
        XCTAssertNil(try body()["firm"])
    }

    @MainActor func testLinkedPortalsKeepTheirMattersApartAndOneApprovalOpensTheTab() async {
        let t = RoutingTransport()
        t.routes["/sv/api/portal/me"] = #"{"kind":"lawyer","name":"Han","status":"approved","firm":{"en":"Venture AI · Silicon Valley"}}"#
        t.routes["/tw/api/portal/me"] = #"{"kind":"lawyer","name":"Han","status":"approved","firm":{"en":"Draft AI · Taipei"}}"#
        let matters = #"{"matters":[{"id":"m1","status":"review","updatedAt":"2026-11-21T00:00:00Z"}]}"#
        t.routes["/sv/api/portal/matters"] = matters
        t.routes["/tw/api/portal/matters"] = matters
        let sv = FirmLink(portalID: "ai-firm.aiworkdeck.com/sv", trialCode: nil, session: { "s" }, transport: { t })
        let tw = FirmLink(portalID: "ai-firm.aiworkdeck.com/tw", trialCode: nil, session: { "s" }, transport: { t })
        await sv.check(); await tw.check()
        let all = sv.matters + tw.matters
        XCTAssertEqual(all.map(\.linkID), ["ai-firm.aiworkdeck.com/sv", "ai-firm.aiworkdeck.com/tw"])
        XCTAssertEqual(Set(all.map(\.uid)).count, 2, "the same matter id in two portals stays two rows")
        XCTAssertEqual(tw.firmName, "Draft AI · Taipei")
        XCTAssertTrue(tw.asksDetails, "no roster: the lawyer may add title, firm and admission")
        XCTAssertEqual(tw.signer(for: try! JSONDecoder().decode(FirmMatter.self, from: Data(#"{"id":"m1","status":"review","updatedAt":"2026-11-21T00:00:00Z","transcript":[],"versions":[]}"#.utf8)))?.name, "Han")

        XCTAssertEqual(FirmPortal.combined([.pending, .approved, .revoked]), .approved)
        XCTAssertEqual(FirmPortal.combined([.revoked, .pending]), .pending)
        XCTAssertEqual(FirmPortal.combined([]), .none)
    }

    func testEveryFirmStringExistsInAllLocales() {
        let keys = ContractStrings.table.keys.filter { $0.hasPrefix("firm.") }
        XCTAssertGreaterThan(keys.count, 60)
        for k in keys { XCTAssertEqual(ContractStrings.table[k]?.count, 20, k) }
    }
}

private final class RoutingTransport: FirmTransport, @unchecked Sendable {
    var routes: [String: String] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let body = routes[request.url?.path ?? ""] else { return (Data(#"{"error":"not_found"}"#.utf8), 404) }
        return (Data(body.utf8), 200)
    }
}

private final class RecordingTransport: FirmTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var next: (Data, Int) = (Data("{}".utf8), 200)
    func send(_ request: URLRequest) async throws -> (Data, Int) { requests.append(request); return next }
}
