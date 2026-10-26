package com.aiworkdeck.mobile

import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.tr
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class L10nTest {
    @After fun resetLocale() { L10n.locale = "zh-Hans" }

    @Test fun substitutesPlaceholders() {
        assertEquals("未归类", tr("library.unknownProject"))
        assertEquals("9月2日 · 3 件", tr("library.dayTitle", mapOf("m" to 9, "d" to 2, "n" to 3)))
    }

    /**
     * 安卓还没接通支付通道（dev-board#428 等微信开放平台 APP 支付），契约把 recharge 记成
     * "external"：设置页放入口、点开只说明去哪儿充。这条测试钉住两件事——能力值没被悄悄改回
     * 支付通道（改回去界面就得真能下单了），以及那两句说明确实在词典里（缺键时 tr 会原样回显键名，
     * 界面上就是一行 "recharge.external.title"）。
     */
    @Test fun externalRechargeNoticeComesFromContract() {
        assertEquals("external", ContractCapabilities.recharge)
        assertEquals("App 内充值开通中", tr("recharge.external.title"))
        assertEquals("请先在微信小程序「AI WorkDeck」的「我的 → 充值」里充值，余额四端通用",
            tr("recharge.external.body"))
        L10n.locale = "en"
        assertEquals("In-app top-up coming soon", tr("recharge.external.title"))
    }

    @Test fun missingKeyEchoesKeyName() {
        assertEquals("no.such.key", tr("no.such.key"))
    }

    @Test fun localeSwitchesToEnglishAndBack() {
        L10n.locale = "en"
        assertEquals("Unassigned", tr("library.unknownProject"))
        L10n.locale = "zh-Hans"
        assertEquals("未归类", tr("library.unknownProject"))
    }

    @Test fun twentyLocalesNormalizationWireCodeRtlAndFallback() {
        assertEquals(20, L10n.supportedLocales.size)
        assertEquals("zh-Hant", L10n.normalize("zh_TW"))
        assertEquals("zh-Hans", L10n.normalize("zh_CN"))
        assertEquals("pt-BR", L10n.normalize("pt_PT"))
        assertEquals("ja", L10n.normalize("ja-JP"))
        L10n.locale = "ar"
        assertTrue(L10n.isRtl)
        assertEquals("ar-SA", L10n.wireCode)
        assertEquals("Unassigned", tr("library.unknownProject"))
        L10n.locale = "zh-Hant"
        assertFalse(L10n.isRtl)
        assertEquals("zh-TW", L10n.wireCode)
        assertEquals("未归类", tr("library.unknownProject"))
    }
}
