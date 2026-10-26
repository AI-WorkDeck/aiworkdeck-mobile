import { STRINGS, SUPPORTED_LOCALES, type LocaleMeta } from './contract/strings'

export type Locale =
  | 'zh-Hans'
  | 'zh-Hant'
  | 'en'
  | 'ja'
  | 'ko'
  | 'th'
  | 'ms'
  | 'id'
  | 'vi'
  | 'fr'
  | 'de'
  | 'es'
  | 'pt-BR'
  | 'it'
  | 'ru'
  | 'el'
  | 'tr'
  | 'nl'
  | 'hi'
  | 'ar'

export type LocalePreference = 'system' | Locale

export { SUPPORTED_LOCALES, type LocaleMeta }

const KEY_LOCALE = 'awd.locale'
const KNOWN_CODES = new Set<string>(SUPPORTED_LOCALES.map((l) => l.code))

/**
 * ISO 3166-1 alpha-2 country/region code -> default mobile `Locale`.
 * Used for Geo-IP / carrier / timezone default language routing when preference is `'system'`.
 */
export const COUNTRY_TO_LOCALE: Readonly<Record<string, Locale>> = {
  CN: 'zh-Hans',
  SG: 'zh-Hans',
  TW: 'zh-Hant',
  HK: 'zh-Hant',
  MO: 'zh-Hant',
  JP: 'ja',
  KR: 'ko',
  TH: 'th',
  MY: 'ms',
  BN: 'ms',
  ID: 'id',
  VN: 'vi',
  FR: 'fr',
  MC: 'fr',
  DE: 'de',
  AT: 'de',
  LI: 'de',
  ES: 'es',
  MX: 'es',
  AR: 'es',
  CO: 'es',
  CL: 'es',
  PE: 'es',
  BR: 'pt-BR',
  PT: 'pt-BR',
  IT: 'it',
  RU: 'ru',
  BY: 'ru',
  KZ: 'ru',
  GR: 'el',
  CY: 'el',
  TR: 'tr',
  NL: 'nl',
  IN: 'hi',
  SA: 'ar',
  AE: 'ar',
  EG: 'ar',
  QA: 'ar',
  KW: 'ar',
  BH: 'ar',
  OM: 'ar',
  JO: 'ar',
  MA: 'ar',
  US: 'en',
  GB: 'en',
  AU: 'en',
  CA: 'en',
  NZ: 'en',
  IE: 'en',
}

export function matchCountryToLocale(countryCode: string | null | undefined): Locale | null {
  if (!countryCode || typeof countryCode !== 'string') return null
  const code = countryCode.trim().toUpperCase()
  if (!/^[A-Z]{2}$/.test(code) || code === 'XX' || code === 'T1') return null
  return COUNTRY_TO_LOCALE[code] ?? null
}


let locale: Locale = 'zh-Hans'

export function normalizeLocale(raw: string | null | undefined, fallback: Locale = 'zh-Hans'): Locale {
  if (!raw || typeof raw !== 'string') return fallback
  const trimmed = raw.trim()
  if (!trimmed) return fallback
  if (KNOWN_CODES.has(trimmed)) return trimmed as Locale
  const norm = trimmed.replace(/_/g, '-').toLowerCase()
  for (const loc of SUPPORTED_LOCALES) {
    if (loc.code.toLowerCase() === norm || loc.wireCode.toLowerCase() === norm) {
      return loc.code as Locale
    }
  }
  if (norm.startsWith('zh-hant') || norm === 'zh-tw' || norm === 'zh-hk' || norm === 'zh-mo') {
    return 'zh-Hant'
  }
  if (norm.startsWith('zh')) {
    return 'zh-Hans'
  }
  if (norm.startsWith('pt')) {
    return 'pt-BR'
  }
  const primary = norm.split('-')[0]
  if (primary === 'in') return 'id'
  for (const loc of SUPPORTED_LOCALES) {
    if (loc.code.toLowerCase() === primary) {
      return loc.code as Locale
    }
  }
  return fallback
}

export function getLocalePreference(): LocalePreference {
  try {
    if (typeof wx !== 'undefined' && typeof wx.getStorageSync === 'function') {
      const stored = wx.getStorageSync(KEY_LOCALE)
      if (stored === 'system') return 'system'
      if (typeof stored === 'string' && KNOWN_CODES.has(stored)) {
        return stored as Locale
      }
    }
  } catch {
    // Ignore storage read errors in test / restricted environments
  }
  return 'system'
}

export function resolveSystemLocale(regionFallback: Locale = 'zh-Hans'): Locale {
  try {
    if (typeof wx !== 'undefined' && typeof wx.getSystemInfoSync === 'function') {
      const info = wx.getSystemInfoSync()
      if (info && typeof info.language === 'string' && info.language.trim()) {
        return normalizeLocale(info.language, regionFallback)
      }
    }
  } catch {
    // Ignore system info errors in test environments
  }
  return regionFallback
}

export function setLocale(next: Locale): void {
  locale = normalizeLocale(next, 'zh-Hans')
}

export function getLocale(): Locale {
  return locale
}

export function setLocalePreference(pref: LocalePreference, regionFallback: Locale = 'zh-Hans'): Locale {
  try {
    if (typeof wx !== 'undefined' && typeof wx.setStorageSync === 'function') {
      if (pref === 'system') {
        if (typeof wx.removeStorageSync === 'function') wx.removeStorageSync(KEY_LOCALE)
        else wx.setStorageSync(KEY_LOCALE, 'system')
      } else {
        wx.setStorageSync(KEY_LOCALE, pref)
      }
    }
  } catch {
    // Ignore storage write errors in test environments
  }
  locale = pref === 'system' ? resolveSystemLocale(regionFallback) : normalizeLocale(pref, regionFallback)
  return locale
}

export function applyRegionLocale(regionFallback: Locale): Locale {
  const pref = getLocalePreference()
  if (pref === 'system') {
    locale = regionFallback
  } else {
    locale = pref
  }
  return locale
}

export function initLocale(regionFallback: Locale = 'zh-Hans'): Locale {
  const pref = getLocalePreference()
  locale = pref === 'system' ? resolveSystemLocale(regionFallback) : pref
  return locale
}

export function wireCodeFor(loc: string = locale): string {
  const found = SUPPORTED_LOCALES.find((l) => l.code === loc)
  return found ? found.wireCode : 'zh-CN'
}

export function isRtl(loc: string = locale): boolean {
  const found = SUPPORTED_LOCALES.find((l) => l.code === loc)
  return found?.dir === 'rtl'
}

export function getCurrentLanguageLabel(): string {
  const pref = getLocalePreference()
  if (pref === 'system') return t('settings.languageFollowSystem')
  const found = SUPPORTED_LOCALES.find((l) => l.code === pref)
  return found ? found.nativeName : pref
}

export function getLanguagePickerOptions(): { code: LocalePreference; label: string }[] {
  return [
    { code: 'system', label: t('settings.languageFollowSystem') },
    ...SUPPORTED_LOCALES.map((l) => ({ code: l.code as Locale, label: l.nativeName })),
  ]
}

/**
 * 按当前语言取词典。
 * 回退顺序：requested → (zh-Hant → zh-Hans) → en → zh-Hans → key。
 */
export function t(key: string, vars: Record<string, string | number> = {}): string {
  const entry = STRINGS[key]
  let s: string | undefined
  if (entry) {
    s = entry[locale]
    if (!s && locale === 'zh-Hant') s = entry['zh-Hans']
    if (!s) s = entry.en
    if (!s) s = entry['zh-Hans']
  }
  let out = s ?? key
  for (const [k, v] of Object.entries(vars)) out = out.split(`{${k}}`).join(String(v))
  return out
}
