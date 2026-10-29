package com.aiworkdeck.mobile

import com.aiworkdeck.contract.ContractStrings
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.features.auth.accountFlowUrl
import com.aiworkdeck.mobile.features.auth.Method
import com.aiworkdeck.mobile.features.auth.defaultMethod
import com.aiworkdeck.mobile.features.auth.loginMethods
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.MemorySessionStore
import com.aiworkdeck.mobile.services.RegionPrefs
import com.aiworkdeck.mobile.services.switchAccountRegion
import com.aiworkdeck.mobile.services.showsExternalRecharge
import com.aiworkdeck.mobile.services.mobilePrivacyUrl
import com.aiworkdeck.mobile.model.RelayProject
import org.junit.Assert.assertNull
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** dev-board#837：账号区域的解析、主机映射、可用登录方式，以及 Backend 跟着区域换主机。 */
class AccountRegionTest {
    @After fun resetLocale() { L10n.locale = "zh-Hans" }

    @Test fun languageFollowsRegion() {
        L10n.follow(AccountRegion.intl)
        assertEquals("en", L10n.locale)
        assertEquals("Global", tr("login.region.intl"))
        assertEquals("Sign in", tr("login.title"))
        L10n.follow(AccountRegion.cn)
        assertEquals("zh-Hans", L10n.locale)
        assertEquals("大陆版", tr("login.region.cn"))
    }

    private class FakePrefs(
        override var accountRegion: AccountRegion,
        override var selectedProject: RelayProject?,
    ) : RegionPrefs

    @Test fun switchingRegionClearsSelectedProjectAndFollowsLanguage() {
        val prefs = FakePrefs(AccountRegion.cn, RelayProject("d1", "Mac", "k1", "项目"))
        assertEquals(AccountRegion.intl, switchAccountRegion(prefs))
        assertEquals(AccountRegion.intl, prefs.accountRegion)
        assertNull(prefs.selectedProject)
        assertEquals("en", L10n.locale)

        prefs.selectedProject = RelayProject("d2", "PC", "k2", "Project")
        assertEquals(AccountRegion.cn, switchAccountRegion(prefs))
        assertNull(prefs.selectedProject)
        assertEquals("zh-Hans", L10n.locale)
    }

    @Test fun toggleFlipsToOtherRegion() {
        assertEquals(AccountRegion.intl, AccountRegion.cn.other)
        assertEquals(AccountRegion.cn, AccountRegion.intl.other)
    }

    @Test fun appLanguageHeaderSentPerRequest() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            var region = AccountRegion.intl
            val backend = Backend(
                baseUrlProvider = { server.url("/").toString().trimEnd('/') },
                session = MemorySessionStore(),
                languageProvider = { region.appLanguage },
            )
            server.enqueue(MockResponse().setBody("""{"code":0}"""))
            server.enqueue(MockResponse().setBody("""{"code":0}"""))
            backend.sendMailLoginCode("x@example.com")
            region = AccountRegion.cn
            backend.sendMailLoginCode("x@example.com")
            assertEquals("en-US", server.takeRequest().getHeader("X-App-Language"))
            assertEquals("zh-CN", server.takeRequest().getHeader("X-App-Language"))
        } finally {
            server.shutdown()
        }
    }

    @Test fun httpErrorUsesDictionaryInCurrentLanguage() = runTest {
        val server = MockWebServer().apply { start() }
        try {
            val backend = Backend(server.url("/").toString().trimEnd('/'), MemorySessionStore())
            server.enqueue(MockResponse().setResponseCode(502))
            L10n.follow(AccountRegion.intl)
            val e = runCatching { backend.sendMailLoginCode("x@example.com") }.exceptionOrNull()
            assertEquals("Server error (502). Try again shortly.", e?.message)
        } finally {
            server.shutdown()
        }
    }

    @Test fun hostMapping() {
        assertEquals("https://addin.aiworkdeck.com", AccountRegion.cn.baseUrl)
        assertEquals("https://addin.workdeck.ai", AccountRegion.intl.baseUrl)
    }

    @Test fun missingKeyFallsBackToFlavorDefault() {
        // 老用户/全新安装没有 accountRegion 键：走 flavor 缺省值，零迁移
        assertEquals(AccountRegion.cn, AccountRegion.resolve(null, AccountRegion.cn))
        assertEquals(AccountRegion.intl, AccountRegion.resolve(null, AccountRegion.intl))
    }

    @Test fun storedValueWinsOverDefault() {
        assertEquals(AccountRegion.intl, AccountRegion.resolve("intl", AccountRegion.cn))
        assertEquals(AccountRegion.cn, AccountRegion.resolve("cn", AccountRegion.intl))
    }

    @Test fun unknownStoredValueFallsBackToDefault() {
        assertEquals(AccountRegion.intl, AccountRegion.resolve("eu", AccountRegion.intl))
        assertEquals(AccountRegion.cn, AccountRegion.resolve("", AccountRegion.cn))
    }

    @Test fun flavorDefaultParsing() {
        assertEquals(AccountRegion.cn, AccountRegion.ofDefault("cn"))
        assertEquals(AccountRegion.intl, AccountRegion.ofDefault("intl"))
        assertEquals(AccountRegion.cn, AccountRegion.ofDefault("garbage"))
    }

    @Test fun currentFlavorDefaultMatchesSpec() {
        // intl flavor → intl，cn flavor → cn
        val expected = if (BuildConfig.FLAVOR == "intl") AccountRegion.intl else AccountRegion.cn
        assertEquals(expected, AccountRegion.ofDefault(BuildConfig.DEFAULT_REGION))
    }

    @Test fun websiteFlowPreservesLegacyEmailIntentWithoutIdentityInUrl() {
        for (flow in listOf("register", "reset")) {
            assertEquals("https://aiworkdeck.com/zh/account?flow=$flow&legacyEmail=1&site=cn", accountFlowUrl(AccountRegion.cn, Method.Email, flow, "cn"))
            assertEquals("https://aiworkdeck.com/zh/account?flow=$flow&site=cn", accountFlowUrl(AccountRegion.cn, Method.Phone, flow, "cn"))
            assertEquals("https://workdeck.ai/en/account?flow=$flow&site=intl", accountFlowUrl(AccountRegion.intl, Method.Email, flow, "cn"))
        }
        assertEquals("https://aiworkdeck.com/zh/account?flow=register&legacyEmail=1&site=cn",
            accountFlowUrl(AccountRegion.cn, Method.Email, "reset&email=private@example.invalid", "cn"))
    }

    @Test fun loginMethodsPerRegion() {
        assertEquals(listOf(Method.Phone, Method.Email), loginMethods(AccountRegion.cn))
        assertEquals(listOf(Method.Email), loginMethods(AccountRegion.intl))
        assertEquals(Method.Phone, defaultMethod(AccountRegion.cn))
        assertEquals(Method.Email, defaultMethod(AccountRegion.intl))
    }

    @Test fun billingOnlyInMainland() {
        assertTrue(AccountRegion.cn.showsBilling)
        assertFalse(AccountRegion.intl.showsBilling)
    }

    @Test fun playRechargeStaysHiddenAfterSwitchingToMainlandAccount() {
        for (region in AccountRegion.entries) {
            assertFalse(showsExternalRecharge("intl", region, "external"))
        }
        assertTrue(showsExternalRecharge("cn", AccountRegion.cn, "external"))
        assertFalse(showsExternalRecharge("cn", AccountRegion.intl, "external"))
        assertFalse(showsExternalRecharge("cn", AccountRegion.cn, "false"))
    }

    @Test fun privacyPolicyMatchesDistributionPublisher() {
        assertEquals("https://workdeck.ai/mobile-account/en/privacy?site=intl", mobilePrivacyUrl("intl"))
        assertEquals("https://www.aiworkdeck.com/zh/legal/mobile-privacy?site=cn", mobilePrivacyUrl("cn"))
    }

    @Test fun labelKeysExistInContract() {
        for (r in AccountRegion.entries) assertTrue(r.labelKey, ContractStrings.table.containsKey(r.labelKey))
    }

    @Test fun backendReadsHostPerRequest() = runTest {
        val a = MockWebServer().apply { start() }
        val b = MockWebServer().apply { start() }
        try {
            var host = a.url("/").toString().trimEnd('/')
            val backend = Backend({ host }, MemorySessionStore())
            a.enqueue(MockResponse().setBody("""{"code":0}"""))
            b.enqueue(MockResponse().setBody("""{"code":0}"""))

            backend.sendMailLoginCode("x@example.com")
            host = b.url("/").toString().trimEnd('/')
            backend.sendMailLoginCode("x@example.com")

            assertEquals(1, a.requestCount)
            assertEquals(1, b.requestCount)
            assertEquals("/api/auth/mail-login/send-code", b.takeRequest().path)
        } finally {
            a.shutdown(); b.shutdown()
        }
    }
    @Test fun `Play account flows stay on a page without payment promotion in either region`() {
        for (flow in listOf("register", "reset")) {
            assertEquals("https://workdeck.ai/mobile-account/en?flow=$flow&site=intl", accountFlowUrl(AccountRegion.intl, Method.Email, flow, "intl"))
            assertEquals("https://www.aiworkdeck.com/mobile-account/zh?flow=$flow&legacyEmail=1&site=cn", accountFlowUrl(AccountRegion.cn, Method.Email, flow, "intl"))
        }
    }
}
