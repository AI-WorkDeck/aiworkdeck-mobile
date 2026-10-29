package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.model.RelayProject

/**
 * 账号区域（dev-board#837）：大陆站与国际站是两套独立账号体系，主机不同、账号不通。
 *
 * 区域只在未登录的登录页切换，登录后固定；换区 = 退出登录后在登录页重选。
 * 所有接口都打 [baseUrl]，Backend 每次发请求现取，不缓存。
 */
enum class AccountRegion(val raw: String, val baseUrl: String, val locale: String, val appLanguage: String) {
    cn("cn", "https://addin.aiworkdeck.com", "zh-Hans", "zh-CN"),
    intl("intl", "https://addin.workdeck.ai", "en", "en-US");

    // locale：界面语言跟着区域走（大陆版中文、海外版英文），见 L10n.follow。
    // appLanguage：请求头 X-App-Language 的值，后端据此选报错语言。

    /** 国际站没有短信通道（阿里云只有大陆签名），只能邮箱验证码登录。 */
    val allowsPhoneLogin: Boolean get() = this == cn

    /** 国际站计费未开通（dev-board#664）：余额行与充值入口都不出现。 */
    val showsBilling: Boolean get() = this == cn

    /** 开关翻到的另一边。 */
    val other: AccountRegion get() = if (this == cn) intl else cn

    /** 设置页「账号区域」行与登录页切换控件的文案键。 */
    val labelKey: String get() = "login.region.$raw"

    companion object {
        /**
         * 本机区域：存过就用存的，没存过（全新安装、或本功能上线前就登录着的老用户）走 flavor 缺省值
         * ——老用户因此零迁移，仍打原来那台主机。认不出的值同样退回缺省。
         */
        fun resolve(stored: String?, default: AccountRegion): AccountRegion =
            entries.firstOrNull { it.raw == stored } ?: default

        /** flavor 的 BuildConfig.DEFAULT_REGION → 枚举；认不出按大陆处理。 */
        fun ofDefault(raw: String): AccountRegion = resolve(raw, cn)
    }
}

/** 登录页翻区域时要一起改的本机偏好。[Prefs] 实现它；单测用内存假实现。 */
interface RegionPrefs {
    var accountRegion: AccountRegion
    var selectedProject: RelayProject?
}

/**
 * 登录页翻到另一区：记下新区；清掉存着的当前项目——那是另一站账号的桌面端项目，
 * 登进这一站后不能直接落到它上面；界面语言当场跟着换。返回新区。
 */
fun switchAccountRegion(prefs: RegionPrefs): AccountRegion {
    val next = prefs.accountRegion.other
    prefs.accountRegion = next
    prefs.selectedProject = null
    L10n.follow(next)
    return next
}

/** Play distribution never changes its payment policy when the account region changes. */
fun showsExternalRecharge(flavor: String, region: AccountRegion, channel: String): Boolean =
    (flavor != "intl" || ContractCapabilities.androidPlayRecharge) && region.showsBilling && channel != "false"

fun mobilePrivacyUrl(flavor: String): String = if (flavor == "intl")
    "https://workdeck.ai/mobile-account/en/privacy?site=intl"
else "https://www.aiworkdeck.com/zh/legal/mobile-privacy?site=cn"
