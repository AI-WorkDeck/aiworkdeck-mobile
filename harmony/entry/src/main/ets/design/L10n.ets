import { ContractLocale, ContractStrings, SUPPORTED_LOCALES } from 'contract'

export const LOCALE_ZH: string = 'zh-Hans'
export const LOCALE_EN: string = 'en'
export const LOCALE_SYSTEM: string = 'system'

/**
 * 界面语言的可观察副本放在 AppStorage 的这个键下（ServiceLocator.applyRegion / applyLocale 写入）。
 * 语言一变要当场重绘的页面（登录页、设置页、首页）用 `@StorageProp('awdLocale')` 订阅并经 `trIn` 取文案。
 */
export const LOCALE_STORAGE_KEY: string = 'awdLocale'

/**
 * 当前界面语言与语言偏好。
 * 这里是纯 ArkTS（Node 侧单测直接跑），不碰 AppStorage；可观察那一半在 ServiceLocator。
 */
export class L10n {
  static locale: string = LOCALE_ZH
  static preference: string = LOCALE_SYSTEM

  static supportedLocales(): ContractLocale[] {
    return SUPPORTED_LOCALES
  }

  static normalize(raw: string | null, fallback: string = LOCALE_ZH): string {
    if (raw === null) return fallback
    const trimmed: string = raw.trim()
    if (trimmed.length === 0) return fallback
    for (let i: number = 0; i < SUPPORTED_LOCALES.length; i++) {
      if (SUPPORTED_LOCALES[i].code === trimmed) return SUPPORTED_LOCALES[i].code
    }
    const norm: string = trimmed.split('_').join('-').toLowerCase()
    for (let i: number = 0; i < SUPPORTED_LOCALES.length; i++) {
      const loc: ContractLocale = SUPPORTED_LOCALES[i]
      if (loc.code.toLowerCase() === norm || loc.wireCode.toLowerCase() === norm) {
        return loc.code
      }
    }
    if (norm.startsWith('zh-hant') || norm === 'zh-tw' || norm === 'zh-hk' || norm === 'zh-mo') {
      return 'zh-Hant'
    }
    if (norm.startsWith('zh')) return LOCALE_ZH
    if (norm.startsWith('pt')) return 'pt-BR'
    const parts: string[] = norm.split('-')
    const primary: string = parts.length > 0 ? parts[0] : ''
    if (primary === 'in') return 'id'
    for (let i: number = 0; i < SUPPORTED_LOCALES.length; i++) {
      if (SUPPORTED_LOCALES[i].code.toLowerCase() === primary) {
        return SUPPORTED_LOCALES[i].code
      }
    }
    return fallback
  }

  static wireCode(loc: string = L10n.locale): string {
    for (let i: number = 0; i < SUPPORTED_LOCALES.length; i++) {
      if (SUPPORTED_LOCALES[i].code === loc) return SUPPORTED_LOCALES[i].wireCode
    }
    return loc === LOCALE_EN ? 'en-US' : 'zh-CN'
  }

  static isRtl(loc: string = L10n.locale): boolean {
    for (let i: number = 0; i < SUPPORTED_LOCALES.length; i++) {
      if (SUPPORTED_LOCALES[i].code === loc) return SUPPORTED_LOCALES[i].dir === 'rtl'
    }
    return false
  }

  static displayName(pref: string = L10n.preference, activeLocale: string = L10n.locale): string {
    if (pref === LOCALE_SYSTEM) {
      return trIn(activeLocale, 'settings.languageFollowSystem')
    }
    for (let i: number = 0; i < SUPPORTED_LOCALES.length; i++) {
      if (SUPPORTED_LOCALES[i].code === pref) return SUPPORTED_LOCALES[i].nativeName
    }
    return pref
  }

  static matchCountryToLocale(countryCode: string | null): string | null {
    if (countryCode === null) return null
    const code: string = countryCode.trim().toUpperCase()
    if (code.length !== 2) return null
    const map: Record<string, string> = {
      'CN': 'zh-Hans', 'SG': 'zh-Hans',
      'TW': 'zh-Hant', 'HK': 'zh-Hant', 'MO': 'zh-Hant',
      'JP': 'ja', 'KR': 'ko',
      'TH': 'th', 'MY': 'ms', 'BN': 'ms', 'ID': 'id', 'VN': 'vi',
      'FR': 'fr', 'MC': 'fr',
      'DE': 'de', 'AT': 'de', 'LI': 'de',
      'ES': 'es', 'MX': 'es', 'AR': 'es', 'CO': 'es', 'CL': 'es', 'PE': 'es',
      'BR': 'pt-BR', 'PT': 'pt-BR',
      'IT': 'it',
      'RU': 'ru', 'BY': 'ru', 'KZ': 'ru',
      'GR': 'el', 'CY': 'el',
      'TR': 'tr', 'NL': 'nl', 'IN': 'hi',
      'SA': 'ar', 'AE': 'ar', 'EG': 'ar', 'QA': 'ar', 'KW': 'ar', 'MA': 'ar',
      'US': 'en', 'GB': 'en', 'AU': 'en', 'CA': 'en', 'NZ': 'en', 'IE': 'en',
    }
    return map[code] ?? null
  }
}

/**
 * 按指定语言查词典。
 * 回退顺序：requested → (zh-Hant → zh-Hans) → en → zh-Hans → key。
 * 占位形如 {n}，按 vars 的键逐个替换。
 */
export function trIn(locale: string, key: string, vars?: Record<string, string | number>): string {
  const entry: Record<string, string> | undefined = ContractStrings[key]
  let s: string = key
  if (entry !== undefined) {
    const hit: string | undefined = entry[locale]
    if (hit !== undefined && hit.length > 0) {
      s = hit
    } else if (locale === 'zh-Hant' && entry[LOCALE_ZH] !== undefined && entry[LOCALE_ZH].length > 0) {
      s = entry[LOCALE_ZH]
    } else if (entry[LOCALE_EN] !== undefined && entry[LOCALE_EN].length > 0) {
      s = entry[LOCALE_EN]
    } else if (entry[LOCALE_ZH] !== undefined && entry[LOCALE_ZH].length > 0) {
      s = entry[LOCALE_ZH]
    }
  }
  if (vars !== undefined) {
    const names: string[] = Object.keys(vars)
    for (let i: number = 0; i < names.length; i++) {
      const name: string = names[i]
      s = s.split('{' + name + '}').join(`${vars[name]}`)
    }
  }
  return s
}

/** 按当前界面语言查词典。 */
export function tr(key: string, vars?: Record<string, string | number>): string {
  return trIn(L10n.locale, key, vars)
}
