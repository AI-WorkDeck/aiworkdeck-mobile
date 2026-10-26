import Foundation
import Observation

/// 当前界面语言，可观察：SwiftUI 的 body 里调 `tr()` 会读到它，语言一变所有可见界面自动重绘，
/// 不用逐页挂刷新。写入只在主线程（启动时、登录页或设置页切语言时）；读可以来自任何隔离域
/// （上传队列、API 的报错文案），所以标成 @unchecked Sendable。
@Observable
final class L10nState: @unchecked Sendable {
    var locale: String = "zh-Hans"
    var preference: String = "system"
}

enum L10n {
    static let defaultsKey = "appLocale"
    static let systemPreference = "system"
    static let state = L10nState()

    static var supportedLocales: [ContractLocale] {
        ContractStrings.supportedLocales
    }

    static var locale: String {
        get { state.locale }
        set { state.locale = newValue }
    }

    static var preference: String {
        get { state.preference }
        set { state.preference = newValue }
    }

    static func normalize(_ raw: String?, fallback: String = "zh-Hans") -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return fallback
        }
        if supportedLocales.contains(where: { $0.code == raw }) {
            return raw
        }
        let norm = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = supportedLocales.first(where: { $0.code.lowercased() == norm || $0.wireCode.lowercased() == norm }) {
            return exact.code
        }
        if norm.hasPrefix("zh-hant") || norm == "zh-tw" || norm == "zh-hk" || norm == "zh-mo" {
            return "zh-Hant"
        }
        if norm.hasPrefix("zh") {
            return "zh-Hans"
        }
        if norm.hasPrefix("pt") {
            return "pt-BR"
        }
        let primary = String(norm.split(separator: "-").first ?? "")
        if primary == "in" { return "id" }
        if let byPrimary = supportedLocales.first(where: { $0.code.lowercased() == primary }) {
            return byPrimary.code
        }
        return fallback
    }

    static func resolveSystemLocale(fallback: String = "zh-Hans") -> String {
        if let preferred = Locale.preferredLanguages.first {
            return normalize(preferred, fallback: fallback)
        }
        return fallback
    }

    static let countryToLocale: [String: String] = [
        "CN": "zh-Hans", "SG": "zh-Hans",
        "TW": "zh-Hant", "HK": "zh-Hant", "MO": "zh-Hant",
        "JP": "ja", "KR": "ko",
        "TH": "th", "MY": "ms", "BN": "ms", "ID": "id", "VN": "vi",
        "FR": "fr", "MC": "fr",
        "DE": "de", "AT": "de", "LI": "de",
        "ES": "es", "MX": "es", "AR": "es", "CO": "es", "CL": "es", "PE": "es",
        "BR": "pt-BR", "PT": "pt-BR",
        "IT": "it",
        "RU": "ru", "BY": "ru", "KZ": "ru",
        "GR": "el", "CY": "el",
        "TR": "tr", "NL": "nl", "IN": "hi",
        "SA": "ar", "AE": "ar", "EG": "ar", "QA": "ar", "KW": "ar", "MA": "ar",
        "US": "en", "GB": "en", "AU": "en", "CA": "en", "NZ": "en", "IE": "en"
    ]

    static func matchCountryToLocale(_ countryCode: String?) -> String? {
        guard let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 2 else { return nil }
        return countryToLocale[code]
    }

    static func loadPreference(from defaults: UserDefaults = .standard) -> String {
        guard let stored = defaults.string(forKey: defaultsKey), !stored.isEmpty else {
            return systemPreference
        }
        if stored == systemPreference { return systemPreference }
        if supportedLocales.contains(where: { $0.code == stored }) { return stored }
        return systemPreference
    }

    static func setPreference(_ newPref: String, regionFallback: String = "zh-Hans", defaults: UserDefaults = .standard) {
        let validPref: String
        if newPref == systemPreference {
            validPref = systemPreference
            defaults.removeObject(forKey: defaultsKey)
        } else {
            validPref = normalize(newPref, fallback: regionFallback)
            defaults.set(validPref, forKey: defaultsKey)
        }
        preference = validPref
        let nextLocale = validPref == systemPreference ? regionFallback : validPref
        if locale != nextLocale { locale = nextLocale }
    }

    static var wireCode: String {
        let cur = locale
        if let found = supportedLocales.first(where: { $0.code == cur }) {
            return found.wireCode
        }
        return cur == "en" ? "en-US" : "zh-CN"
    }

    static var isRTL: Bool {
        let cur = locale
        return supportedLocales.first(where: { $0.code == cur })?.dir == "rtl"
    }

    static var currentDisplayName: String {
        if preference == systemPreference {
            return tr("settings.languageFollowSystem")
        }
        return supportedLocales.first(where: { $0.code == preference })?.nativeName ?? preference
    }

    // 区域 → 语言的映射（locale(for:) / apply(region:)）写在 Backend.swift 的 extension 里：
    // 这份文件也编进 Live Activity 扩展，扩展里没有 AccountRegion。

    /// 日期格式化用的 Locale（月份名、日序跟着界面语言走，不跟设备）。
    static var formatLocale: Locale {
        Locale(identifier: wireCode.replacingOccurrences(of: "-", with: "_"))
    }
}

/// `locale` 缺省取当前界面语言；Live Activity 扩展是另一个进程，拿不到 App 的语言状态，
/// 由活动属性把开始录音那一刻的语言带过去再显式传进来。
/// 回退顺序：requested → (zh-Hant → zh-Hans) → en → zh-Hans → key。
func tr(_ key: String, _ vars: [String: String] = [:], locale: String? = nil) -> String {
    let entry = ContractStrings.table[key]
    let target = locale ?? L10n.locale
    var s: String?
    if let v = entry?[target], !v.isEmpty {
        s = v
    } else if target == "zh-Hant", let v = entry?["zh-Hans"], !v.isEmpty {
        s = v
    } else if let v = entry?["en"], !v.isEmpty {
        s = v
    } else if let v = entry?["zh-Hans"], !v.isEmpty {
        s = v
    }
    var out = s ?? key
    for (k, v) in vars { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
    return out
}
