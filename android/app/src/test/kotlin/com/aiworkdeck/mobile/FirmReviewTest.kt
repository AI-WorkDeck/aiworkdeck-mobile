// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile

import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.services.firm.*
import com.aiworkdeck.mobile.services.firm.FirmDiff.Change.Added
import com.aiworkdeck.mobile.services.firm.FirmDiff.Change.Removed
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Instant

/** Mirrors ios/Tests/FirmReviewTests.swift for the pure logic (docs/specs/2026-11-19-firm-review.md). */
class FirmReviewTest {
    private var savedLocale = ""
    @Before fun saveLocale() { savedLocale = L10n.locale }
    @After fun restoreLocale() { L10n.locale = savedLocale }

    private fun summary(id: String, status: String, attention: String? = null, consult: String? = null) =
        FirmMatterSummary(id = id, status = status, updatedAt = "2026-11-19T08:00:00.000Z", template = FirmName(en = "SAFE", zh = "SAFE"),
            client = "Ada", company = "Acme", versions = 1, consult = consult?.let { FirmConsult(status = it) }, forLawyerCount = 2,
            wantsCall = false, attention = attention)

    private inline fun <reified T> decode(json: String): T = FirmJson.decodeFromString(json)

    @Test fun inboxPutsWhatNeedsTheLawyerFirst() {
        val list = listOf(
            summary("signed", "signed"), summary("waiting", "awaiting_client"), summary("call", "in_review", consult = "requested"),
            summary("review", "review"), summary("replied", "awaiting_client", attention = "client_replied"), summary("drafted", "drafted"),
        )
        val groups = FirmInbox.grouped(list)
        assertEquals(listOf(FirmInbox.Group.needsYou, FirmInbox.Group.waiting, FirmInbox.Group.inProgress, FirmInbox.Group.done), groups.map { it.first })
        assertEquals(listOf("call", "review", "replied"), groups[0].second.map { it.id })
        assertEquals("call_requested", FirmInbox.reason(list[2]))
        assertEquals("review_requested", FirmInbox.reason(list[3]))
        assertEquals("client_replied", FirmInbox.reason(list[4]))
        assertNull(FirmInbox.reason(list[1]))
    }

    @Test fun portalAttentionFieldOverridesDerivation() {
        val m = summary("x", "review", attention = "")
        assertNull(FirmInbox.reason(m))
        assertEquals(FirmInbox.Group.inProgress, FirmInbox.group(m))
    }

    @Test fun inboxShowsLoadingBeforeTheFirstListAndEmptyOnlyAfterIt() {
        assertEquals(FirmInbox.Placeholder.loading, FirmInbox.placeholder(hasMatters = false, listed = false, failed = false))
        assertEquals(FirmInbox.Placeholder.empty, FirmInbox.placeholder(hasMatters = false, listed = true, failed = false))
        assertNull(FirmInbox.placeholder(hasMatters = false, listed = false, failed = true))
        assertNull(FirmInbox.placeholder(hasMatters = true, listed = true, failed = false))
    }

    @Test fun diffShowsOnlyChangedLines() {
        val old = "# SAFE\n\nThe valuation cap is \$8M.\n\nGoverning law: Delaware."
        val new = "# SAFE\n\nThe valuation cap is \$10M.\n\nGoverning law: Delaware.\n\nPro rata rights apply."
        assertEquals(listOf(Removed("The valuation cap is \$8M."), Added("The valuation cap is \$10M."), Added("Pro rata rights apply.")), FirmDiff.edits(old, new))
        assertEquals(emptyList<FirmDiff.Change>(), FirmDiff.edits(old, old))
        assertEquals(listOf(Added("A")), FirmDiff.edits("", "A"))
        assertEquals(emptyList<FirmDiff.Change>(), FirmDiff.edits("## 株式会社 章程（定款）\n**第1条** 商号", "株式会社 章程（定款）\n第1条  商号"))
        val art1 = "第23条（设立时发行的股份）\n每股发行价格为1日元。\n出资额1,000万日元。"
        val art2 = "第23条（设立时发行的股份）\n每股发行价格为1日元。\n出资额3,000万日元。"
        assertEquals(listOf(Removed("出资额1,000万日元。"), Added("出资额3,000万日元。")), FirmDiff.edits(art1, art2))
    }

    @Test fun underscoreBlanksAreContentInTheDiff() {
        assertTrue(FirmDiff.edits("金额：______元", "金额：____元").isNotEmpty())
        assertEquals(listOf(Added("________")), FirmDiff.edits("条款", "条款\n________"))
    }

    @Test fun onlyAllowlistedHttpsPortalsReceiveTheSession() {
        val allowed = listOf("aifirm.aiworkdeck.com/all", "aifirm.aiworkdeck.com/sv", "aifirm.aiworkdeck.com/tw")
        fun p(s: String) = FirmPortalLink.portal(s, allowed)
        assertEquals("aifirm.aiworkdeck.com/sv", p("https://aifirm.aiworkdeck.com/sv/"))
        assertEquals("aifirm.aiworkdeck.com/sv", p("https://aifirm.aiworkdeck.com/sv/v2/#m=abc"))
        assertEquals("aifirm.aiworkdeck.com/tw", p("https://aifirm.aiworkdeck.com/tw/"))
        assertEquals("aifirm.aiworkdeck.com/tw", p("https://aifirm.aiworkdeck.com/TW"))
        assertEquals("aifirm.aiworkdeck.com/all", p("https://aifirm.aiworkdeck.com/"))
        assertEquals("aifirm.aiworkdeck.com/all", p("aifirm.aiworkdeck.com"))
        assertEquals("aifirm.aiworkdeck.com/sv", p(" AIFIRM.aiworkdeck.com/sv "))
        assertNull(p("https://aifirm.aiworkdeck.com/twx/"))
        assertNull(p("https://aifirm.aiworkdeck.com/ces/"))
        assertNull(p("http://aifirm.aiworkdeck.com/sv/"))
        assertNull(p("https://aifirm.aiworkdeck.com.evil.example/sv/"))
        assertNull(p("https://evil.example/aifirm.aiworkdeck.com/tw"))
        assertNull(p("https://aifirm.aiworkdeck.com@evil.example/sv/"))
        assertNull(p(""))
        for (office in listOf("all", "sv", "tw", "jp", "sg")) assertTrue(office, "aifirm.aiworkdeck.com/$office" in ContractCapabilities.firmPortals)
        assertTrue(FirmPortalLink.isPortalUrl("https://aifirm.aiworkdeck.com/tw/m/abc/1.pdf"))
        assertFalse(FirmPortalLink.isPortalUrl("http://aifirm.aiworkdeck.com/m/abc/1.pdf"))
        assertFalse(FirmPortalLink.isPortalUrl("https://evil.example/m/abc/1.pdf"))
        assertFalse(FirmPortalLink.isPortalUrl("https://aifirm.aiworkdeck.com@evil.example/m/abc/1.pdf"))
    }

    @Test fun partnerNetworkOfficesAreAllowlistedWithoutARootPortal() {
        assertEquals("ai-firm.aiworkdeck.com/sv", FirmPortalLink.portal("https://ai-firm.aiworkdeck.com/sv/v2/"))
        assertEquals("ai-firm.aiworkdeck.com/tw", FirmPortalLink.portal("ai-firm.aiworkdeck.com/tw"))
        assertNull(FirmPortalLink.portal("https://ai-firm.aiworkdeck.com/"))
        assertNull(FirmPortalLink.portal("https://ai-firm.aiworkdeck.com/jp/"))
        assertTrue(FirmPortalLink.isPortalUrl("https://ai-firm.aiworkdeck.com/tw/m/abc/1.pdf"))
        assertEquals("ai-firm.aiworkdeck.com" to "/tw", FirmPortalLink.parts("ai-firm.aiworkdeck.com/tw"))
        assertEquals("host.example" to "", FirmPortalLink.parts("host.example"))
    }

    @Test fun matterDecodesPortalShapeAndSettlements() {
        val json = """
        {"id":"m1","status":"review","updatedAt":"2026-11-19T08:00:00.000Z","template":{"en":"Term sheet","zh":"投资条款清单"},
         "client":"Ada","company":"Acme","lawyerId":"l1","lawyerName":"Li","consult":null,"extra":42,
         "transcript":[{"role":"user","content":"Hi","at":"x"},{"role":"event","content":"draft","version":1}],
         "versions":[{"n":1,"markdown":"A","by":"ai","pdfUrl":"https://aifirm.aiworkdeck.com/m/t/1.pdf","notes":{"changes":[],"flags":[{"id":"f1","level":"high","section":"2","title":"Cap","risk":"r"},{"id":"f2","title":"Board"}]}},
                     {"n":2,"markdown":"B","by":"ai","notes":{"changes":["Raised the cap"],"flags":[{"id":"f1","level":"high","title":"Cap"},{"id":"f2","title":"Board"}],"summary":"s"}}],
         "flagState":{"2":{"f1":"noted","f2":"lawyer"}},"forLawyer":[{"text":"Is the cap market?","section":"2","flag":"f1","version":2,"at":"x"}],"signoff":null}
        """
        val m = decode<FirmMatter>(json)
        assertEquals(2, m.latest?.n); assertEquals(1, m.previous?.n)
        assertEquals(listOf("noted", "lawyer"), m.latest!!.notes!!.flags!!.map { m.settlement(it) })
        assertEquals("firm.flag.noted", FirmIdentity.settlementKey("noted"))
        assertEquals("firm.flag.open", FirmIdentity.settlementKey(null))
        assertEquals("Is the cap market?", m.forLawyer?.first()?.text)
        assertEquals("Li", m.lawyerDisplayName)
        val named = decode<FirmMatter>(json.replace("\"lawyerName\":\"Li\",", "\"lawyerName\":\"Morris Tu\",\"lawyerNames\":{\"en\":\"Morris Tu\",\"zh\":\"涂能谋\",\"zht\":\"涂能謀\"},"))
        L10n.locale = "zh-Hant"; assertEquals("涂能謀", named.lawyerDisplayName)
        L10n.locale = "zh-Hans"; assertEquals("涂能谋", named.lawyerDisplayName)
        L10n.locale = "en"; assertEquals("Morris Tu", named.lawyerDisplayName)
    }

    @Test fun portalTextFollowsAppLanguageWithEnglishFallback() {
        val n = decode<FirmName>("""{"en":"Tokyo","zh":"东京","zht":"東京","ja":"東京オフィス","ms":null,"de":""}""")
        assertEquals("Tokyo", n.text("en")); assertEquals("东京", n.text("zh-Hans")); assertEquals("東京", n.text("zh-Hant"))
        assertEquals("東京オフィス", n.text("ja")); assertEquals("Tokyo", n.text("ms")); assertEquals("Tokyo", n.text("de"))
        assertEquals("硅谷", FirmName(zh = "硅谷").text("fr"))
    }

    @Test fun flagsShowTheVersionWhereTheyWereSettled() {
        val m = decode<FirmMatter>("""
        {"id":"m","status":"review","updatedAt":"x","transcript":[],
         "versions":[{"n":1,"markdown":"A","notes":{"flags":[{"id":"f1","title":"Cap"},{"id":"f2","title":"Law"}]}},
                     {"n":2,"markdown":"B","notes":{"flags":[{"id":"f1","title":"New issue"}]}}],
         "flagState":{"1":{"f1":"noted","f2":"lawyer"}}}""")
        assertEquals(1, m.flagsVersion?.n)
        assertEquals(listOf("noted", "lawyer"), m.flagsVersion!!.notes!!.flags!!.map { m.settlement(it) })
        val fresh = decode<FirmMatter>("""{"id":"m","status":"review","updatedAt":"x","transcript":[],"versions":[{"n":1,"markdown":"A","notes":{"flags":[{"id":"f1"}]}}]}""")
        assertEquals(1, fresh.flagsVersion?.n)
        assertNull(fresh.settlement(FirmFlag("f1")))
    }

    @Test fun aNewerDraftsNewFlagsAreNotHiddenBehindSettledOnes() {
        val json = """
        {"id":"m","status":"review","updatedAt":"x","transcript":[],
         "versions":[{"n":2,"markdown":"A","notes":{"flags":[{"id":"f1","title":"Cap"},{"id":"f2","title":"Law"}]}},
                     {"n":3,"markdown":"B","notes":{"flags":[{"id":"f1","title":"Cap"},{"id":"f2","title":"Law"},{"id":"f3","title":"Board seat"}]}}],
         "flagState":{"2":{"f1":"noted","f2":"kept"}}}"""
        val m = decode<FirmMatter>(json)
        assertEquals(2, m.flagsVersion?.n)
        assertEquals(listOf("Board seat"), m.newFlags.map { it.title })
        val relisted = decode<FirmMatter>(json.replace("""{"id":"f3","title":"Board seat"}""", """{"id":"f3","title":"**Cap**"}"""))
        assertEquals(0, relisted.newFlags.size)
    }

    @Test fun relativeTimeNeverReadsAsFuture() {
        val now = Instant.parse("2026-11-24T00:00:00Z")
        assertEquals(now, FirmText.clampToNow("2026-11-24T00:00:05.000Z", now))
        assertEquals(Instant.parse("2026-11-23T00:00:00Z"), FirmText.clampToNow("2026-11-23T00:00:00Z", now))
        assertNull(FirmText.clampToNow("not a date", now))
        assertEquals("§2", FirmText.section("2")); assertEquals("Recitals", FirmText.section("Recitals")); assertNull(FirmText.section(""))
        assertEquals("Acme · Ada", FirmText.who("Ada", "Acme")); assertEquals("—", FirmText.who(null, ""))
    }

    @Test fun onlyAnExplicitApprovalOpensTheReviewsTab() {
        assertEquals(FirmAccess.approved, FirmAccess.forStatus("approved"))
        assertEquals(FirmAccess.revoked, FirmAccess.forStatus("revoked"))
        for (s in listOf("pending", "rejected", null)) assertEquals(FirmAccess.pending, FirmAccess.forStatus(s))
    }

    @Test fun aNetworkErrorNeverUpgradesAccess() {
        assertEquals(FirmAccess.pending, FirmAccess.after("network", FirmAccess.pending))
        assertEquals(FirmAccess.revoked, FirmAccess.after("network", FirmAccess.revoked))
        assertEquals(FirmAccess.approved, FirmAccess.after("network", FirmAccess.approved))
        assertEquals(FirmAccess.failed, FirmAccess.after("network", FirmAccess.checking))
        assertEquals(FirmAccess.failed, FirmAccess.after("http_502", FirmAccess.none))
    }

    @Test fun expiredOrRejectedCredentialsCloseAnApprovedSession() {
        for (code in listOf("trial_expired", "unauthorized", "access_revoked")) assertEquals(code, FirmAccess.revoked, FirmAccess.after(code, FirmAccess.approved))
        assertEquals(FirmAccess.pending, FirmAccess.after("access_pending", FirmAccess.approved))
        assertEquals("firm.error.access", FirmPortalError("trial_expired", 401).messageKey)
        assertEquals("firm.error.versionChanged", FirmPortalError("version_changed", 409).messageKey)
        assertEquals("firm.error.network", FirmPortalError("http_500", 500).messageKey)
    }

    @Test fun oneApprovalAmongSeveralPortalsOpensTheTab() {
        assertEquals(FirmAccess.approved, FirmAccess.combined(listOf(FirmAccess.pending, FirmAccess.approved, FirmAccess.revoked)))
        assertEquals(FirmAccess.pending, FirmAccess.combined(listOf(FirmAccess.revoked, FirmAccess.pending)))
        assertEquals(FirmAccess.none, FirmAccess.combined(emptyList()))
        val a = summary("m1", "review").copy(linkID = "ai-firm.aiworkdeck.com/sv")
        val b = summary("m1", "review").copy(linkID = "ai-firm.aiworkdeck.com/tw")
        assertNotEquals("the same matter id in two portals stays two rows", a.uid, b.uid)
    }

    @Test fun headingFollowedByBodyOnTheNextLineRendersAsHeadingThenBody() {
        val b = FirmMarkdown.blocks("## 第1条（商号）\n当会社は…と称する。\n第二行\n\n正文段落")
        assertEquals(listOf(2, 0, 0), b.map { it.level })
        assertEquals(listOf("第1条（商号）", "当会社は…と称する。\n第二行", "正文段落"), b.map { it.text })
    }

    @Test fun signoffNeedsEveryConfirmationAndASigner() {
        val li = FirmSigner("Li", demo = false)
        assertTrue(FirmIdentity.signoffReady(true, true, true, li))
        assertFalse(FirmIdentity.signoffReady(true, true, true, null))
        assertFalse(FirmIdentity.signoffReady(false, true, true, li))
        assertFalse(FirmIdentity.signoffReady(true, false, true, li))
        assertFalse(FirmIdentity.signoffReady(true, true, false, li))
    }

    @Test fun signerComesFromIdentityNotTyping() {
        fun signer(kind: String?, demo: Boolean = false, roster: String? = null, account: String? = null, matter: String? = "Matter Lawyer") =
            FirmIdentity.signer(kind, demo, roster, "國際合夥人", "台北", account, matter, "Firm")
        assertEquals(FirmSigner("涂能謀", "國際合夥人 · 台北", demo = false), signer("lawyer", roster = "涂能謀", account = "morris"))
        assertEquals(FirmSigner("涂能謀", "國際合夥人 · 台北", demo = false), signer("lawyer", demo = true, roster = "涂能謀"))
        assertEquals(FirmSigner("Li Wei", demo = false), signer("lawyer", account = "Li Wei"))
        assertNull(signer("lawyer", account = ""))
        assertEquals(FirmSigner("Matter Lawyer", demo = true), signer("lawyer", demo = true, account = "App Review"))
        assertEquals(FirmSigner("Matter Lawyer", demo = true), signer("trial"))
        assertEquals(FirmSigner("Firm", demo = true), signer("trial", matter = null))
    }

    @Test fun accountScopeSeparatesAccountsAndRegionsAndMatchesIos() {
        val cn = "https://addin.aiworkdeck.com"; val intl = "https://addin.workdeck.ai"
        assertNotEquals(FirmIdentity.accountScope(1, cn), FirmIdentity.accountScope(2, cn))
        assertNotEquals(FirmIdentity.accountScope(1, cn), FirmIdentity.accountScope(1, intl))
        assertEquals(FirmIdentity.accountScope(1, cn), FirmIdentity.accountScope(1, cn))
        assertEquals(64, FirmIdentity.accountScope(1, cn).length)
        assertEquals("s|p", FirmIdentity.trialAccount("s", "p"))
        assertEquals("firm.own.s|p.", FirmIdentity.detailsKey("s", "p"))
    }

    @Test fun statusTextForLinkedPortalsAndSettings() {
        assertEquals("firm.status.pending" to mapOf<String, Any>("firm" to "Draft AI"), FirmStatus.link(FirmAccess.checking, "Draft AI"))
        assertEquals("firm.status.revoked", FirmStatus.link(FirmAccess.revoked, "X")!!.first)
        assertEquals("firm.status.approved", FirmStatus.link(FirmAccess.approved, "X")!!.first)
        assertNull("unreachable: just the firm name", FirmStatus.link(FirmAccess.failed, "X"))
        assertEquals(FirmStatus.SettingsValue.Text("Venture AI, Draft AI"),
            FirmStatus.settings(listOf(FirmAccess.approved to "Venture AI", FirmAccess.pending to "KWM", FirmAccess.approved to "Draft AI")))
        assertEquals(FirmStatus.SettingsValue.Key("firm.status.pending", mapOf("firm" to "KWM")), FirmStatus.settings(listOf(FirmAccess.pending to "KWM")))
        assertNull(FirmStatus.settings(listOf(FirmAccess.revoked to "KWM")))
        assertNull(FirmStatus.settings(emptyList()))
    }

    @Test fun losingFirmAccessLeavesTheReviewsTab() {
        assertEquals("capture", FirmTabs.keep("firm", "firm", "capture", firmVisible = false))
        assertEquals("firm", FirmTabs.keep("firm", "firm", "capture", firmVisible = true))
        assertEquals("assistant", FirmTabs.keep("assistant", "firm", "capture", firmVisible = false))
        assertEquals(MainTab.capture, FirmTabs.keep(MainTab.firm, MainTab.firm, MainTab.capture, false))
    }

    @Test fun relativeTimeUsesContractStringsAndNeverTheFuture() {
        val now = Instant.parse("2026-11-24T12:00:00Z")
        assertEquals("time.secondsAgo" to 0L, FirmTabs.agoKey(Instant.parse("2026-11-24T12:00:05Z"), now))
        assertEquals("time.minutesAgo" to 3L, FirmTabs.agoKey(Instant.parse("2026-11-24T11:57:00Z"), now))
        assertEquals("time.hoursAgo" to 2L, FirmTabs.agoKey(Instant.parse("2026-11-24T10:00:00Z"), now))
        assertEquals("time.daysAgo" to 3L, FirmTabs.agoKey(Instant.parse("2026-11-21T12:00:00Z"), now))
    }

    @Test fun everyFirmStringKeyUsedHereExists() {
        val keys = FirmInbox.Group.entries.map(FirmInbox::titleKey) +
            listOf("call_requested", "client_replied", "review_requested").map(FirmInbox::reasonKey) +
            listOf("noted", "kept", "lawyer", null).map(FirmIdentity::settlementKey) +
            listOf("version_changed", "already_signed", "unauthorized", "x").map { FirmPortalError(it, 0).messageKey } +
            FirmAccess.entries.mapNotNull { FirmStatus.link(it, "f")?.first } +
            listOf("firm.settings.title", "firm.join.title", "firm.join.body", "firm.join.link", "firm.join.badHost", "firm.join.connect",
                "firm.trial.use", "firm.trial.code", "firm.trial.until", "firm.trial.invalid", "firm.status.check", "firm.leave", "error.sessionSaveFailed",
                "firm.tab", "firm.inbox.empty", "firm.forLawyerCount", "time.secondsAgo", "time.minutesAgo", "time.hoursAgo", "time.daysAgo")
        for (k in keys) assertTrue(k, com.aiworkdeck.contract.ContractStrings.table.containsKey(k))
    }
}
