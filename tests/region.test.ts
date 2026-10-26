import { test, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { regionView, localeFor } from '../miniprogram/utils/region.ts'
import { CAPS } from '../miniprogram/utils/contract/capabilities.ts'
import {
  t,
  setLocale,
  getLocale,
  normalizeLocale,
  matchCountryToLocale,
  wireCodeFor,
  isRtl,
  SUPPORTED_LOCALES,
} from '../miniprogram/utils/i18n.ts'

// i18n 的语言是模块级状态，每条用例后复位，免得串到别的测试文件
afterEach(() => setLocale('zh-Hans'))

test('region: 大陆版默认可登录，无说明', () => {
  assert.equal(getLocale(), 'zh-Hans')
  assert.deepEqual(regionView('cn', CAPS.intlAccount), { showLogin: true, notice: '' })
})

test('region: 小程序选海外版 → 隐藏登录，给 intlAccount 的降级说明', () => {
  assert.equal(CAPS.intlAccount, false)
  const v = regionView('intl', CAPS.intlAccount)
  assert.equal(v.showLogin, false)
  assert.equal(v.notice, t('cap.noIntlAccount'))
  assert.notEqual(v.notice, 'cap.noIntlAccount') // 键在词典里，不是回显键名
})

test('region: 能力开关打开时海外版不拦（由 CAPS 驱动，不写死）', () => {
  assert.deepEqual(regionView('intl', true), { showLogin: true, notice: '' })
})

test('region: 语言跟随区域——海外版 en，大陆版 zh-Hans', () => {
  assert.equal(localeFor('intl'), 'en')
  assert.equal(localeFor('cn'), 'zh-Hans')

  setLocale(localeFor('intl'))
  assert.equal(getLocale(), 'en')
  assert.equal(t('login.region.intl'), 'Global')
  assert.equal(t('login.getApp'), 'Get the app')
  assert.equal(t('download.title'), 'Get the AI WorkDeck app')
  const v = regionView('intl', CAPS.intlAccount)
  assert.match(v.notice, /^The mini program supports China accounts only/)

  setLocale(localeFor('cn'))
  assert.equal(t('login.region.cn'), '大陆版')
  assert.equal(t('login.getApp'), '下载 App')
})

test('i18n: 英文下占位符替换照常，缺键仍回显键名', () => {
  setLocale('en')
  assert.equal(t('no.such.key'), 'no.such.key')
  assert.doesNotMatch(t('delete.title', { n: 3 }), /\{n\}/)
})

test('i18n: 20 语言目录、规范化、wireCode、RTL 与回退链', () => {
  assert.equal(SUPPORTED_LOCALES.length, 20)
  assert.equal(normalizeLocale('zh_TW'), 'zh-Hant')
  assert.equal(normalizeLocale('zh_HK'), 'zh-Hant')
  assert.equal(normalizeLocale('zh_CN'), 'zh-Hans')
  assert.equal(normalizeLocale('pt_PT'), 'pt-BR')
  assert.equal(normalizeLocale('ja-JP'), 'ja')
  assert.equal(normalizeLocale('ar-SA'), 'ar')
  assert.equal(wireCodeFor('zh-Hans'), 'zh-CN')
  assert.equal(wireCodeFor('zh-Hant'), 'zh-TW')
  assert.equal(wireCodeFor('ja'), 'ja-JP')
  assert.equal(isRtl('ar'), true)
  assert.equal(isRtl('en'), false)

  // 20 语种均提供本地化译文（未命中键时仍按 zh-Hant -> zh-Hans、其他 -> en 回落）
  setLocale('zh-Hant')
  assert.equal(t('login.region.cn'), '大陸版')
  setLocale('ja')
  assert.notEqual(t('login.region.cn'), 'login.region.cn')
  assert.equal(t('no.such.key'), 'no.such.key')

  // Geo-IP 国家/地区代码 -> 默认语言映射
  assert.equal(matchCountryToLocale('CN'), 'zh-Hans')
  assert.equal(matchCountryToLocale('TW'), 'zh-Hant')
  assert.equal(matchCountryToLocale('HK'), 'zh-Hant')
  assert.equal(matchCountryToLocale('JP'), 'ja')
  assert.equal(matchCountryToLocale('KR'), 'ko')
  assert.equal(matchCountryToLocale('SA'), 'ar')
  assert.equal(matchCountryToLocale('BR'), 'pt-BR')
  assert.equal(matchCountryToLocale('XX'), null)
})
