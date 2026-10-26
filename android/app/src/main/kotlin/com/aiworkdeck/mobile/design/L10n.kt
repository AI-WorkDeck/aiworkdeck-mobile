package com.aiworkdeck.mobile.design

import androidx.compose.runtime.mutableStateOf
import com.aiworkdeck.contract.ContractLocale
import com.aiworkdeck.contract.ContractStrings
import com.aiworkdeck.mobile.services.AccountRegion

/**
 * 契约文案。默认跟随账号区域（大陆版 zh-Hans、海外版 en），当用户主动选了语言偏好时以偏好为准。
 *
 * locale 放在 Compose 快照状态里：界面里每处 tr() 都读了它，换语言时读过它的界面自动重绘，
 * 不用逐屏通知。非界面调用（通知、Worker）读到的就是当下的值。
 */
object L10n {
    const val SYSTEM_PREFERENCE = "system"
    private val state = mutableStateOf("zh-Hans")
    private val prefState = mutableStateOf(SYSTEM_PREFERENCE)

    val supportedLocales: List<ContractLocale>
        get() = ContractStrings.supportedLocales

    var locale: String
        get() = state.value
        set(value) { state.value = value }

    var preference: String
        get() = prefState.value
        set(value) { prefState.value = value }

    val wireCode: String
        get() {
            val cur = locale
            return supportedLocales.firstOrNull { it.code == cur }?.wireCode
                ?: if (cur == "en") "en-US" else "zh-CN"
        }

    val isRtl: Boolean
        get() = supportedLocales.firstOrNull { it.code == locale }?.dir == "rtl"

    val currentDisplayName: String
        get() = if (preference == SYSTEM_PREFERENCE) {
            tr("settings.languageFollowSystem")
        } else {
            supportedLocales.firstOrNull { it.code == preference }?.nativeName ?: preference
        }

    fun normalize(raw: String?, fallback: String = "zh-Hans"): String {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return fallback
        if (supportedLocales.any { it.code == trimmed }) return trimmed
        val norm = trimmed.replace('_', '-').lowercase()
        supportedLocales.firstOrNull {
            it.code.lowercase() == norm || it.wireCode.lowercase() == norm
        }?.let { return it.code }
        if (norm.startsWith("zh-hant") || norm == "zh-tw" || norm == "zh-hk" || norm == "zh-mo") {
            return "zh-Hant"
        }
        if (norm.startsWith("zh")) return "zh-Hans"
        if (norm.startsWith("pt")) return "pt-BR"
        val primary = norm.substringBefore('-')
        if (primary == "in") return "id"
        supportedLocales.firstOrNull { it.code.lowercase() == primary }?.let { return it.code }
        return fallback
    }

    fun resolveSystemLocale(fallback: String = "zh-Hans"): String {
        val tag = java.util.Locale.getDefault().toLanguageTag()
        return normalize(tag, fallback)
    }

    private val countryToLocale: Map<String, String> = mapOf(
        "CN" to "zh-Hans", "SG" to "zh-Hans",
        "TW" to "zh-Hant", "HK" to "zh-Hant", "MO" to "zh-Hant",
        "JP" to "ja", "KR" to "ko",
        "TH" to "th", "MY" to "ms", "BN" to "ms", "ID" to "id", "VN" to "vi",
        "FR" to "fr", "MC" to "fr",
        "DE" to "de", "AT" to "de", "LI" to "de",
        "ES" to "es", "MX" to "es", "AR" to "es", "CO" to "es", "CL" to "es", "PE" to "es",
        "BR" to "pt-BR", "PT" to "pt-BR",
        "IT" to "it",
        "RU" to "ru", "BY" to "ru", "KZ" to "ru",
        "GR" to "el", "CY" to "el",
        "TR" to "tr", "NL" to "nl", "IN" to "hi",
        "SA" to "ar", "AE" to "ar", "EG" to "ar", "QA" to "ar", "KW" to "ar", "MA" to "ar",
        "US" to "en", "GB" to "en", "AU" to "en", "CA" to "en", "NZ" to "en", "IE" to "en"
    )

    fun matchCountryToLocale(countryCode: String?): String? {
        val code = countryCode?.trim()?.uppercase().orEmpty()
        if (code.length != 2) return null
        return countryToLocale[code]
    }

    fun applyPreference(pref: String?, region: AccountRegion) {
        val valid = if (pref.isNullOrEmpty() || pref == SYSTEM_PREFERENCE) {
            SYSTEM_PREFERENCE
        } else {
            normalize(pref, region.locale)
        }
        preference = valid
        locale = if (valid == SYSTEM_PREFERENCE) region.locale else valid
    }

    /** 启动时与登录页切区域时调：当偏好为 system 时界面语言跟随区域。 */
    fun follow(region: AccountRegion) {
        locale = if (preference == SYSTEM_PREFERENCE) region.locale else normalize(preference, region.locale)
    }
}

/** 回退顺序：requested → (zh-Hant → zh-Hans) → en → zh-Hans → key。 */
fun tr(key: String, vars: Map<String, Any> = emptyMap()): String {
    val entry = ContractStrings.table[key]
    val target = L10n.locale
    var s = entry?.get(target)?.takeIf { it.isNotEmpty() }
    if (s == null && target == "zh-Hant") {
        s = entry?.get("zh-Hans")?.takeIf { it.isNotEmpty() }
    }
    if (s == null) {
        s = entry?.get("en")?.takeIf { it.isNotEmpty() }
    }
    if (s == null) {
        s = entry?.get("zh-Hans")?.takeIf { it.isNotEmpty() }
    }
    var out = s ?: key
    for ((k, v) in vars) out = out.replace("{$k}", v.toString())
    return out
}
