import { accountLogin, verifyLoginCode } from '../../utils/api'
import type { ApiError } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import {
  t,
  applyRegionLocale,
  getLocalePreference,
  setLocalePreference,
  getCurrentLanguageLabel,
  getLanguagePickerOptions,
  isRtl,
} from '../../utils/i18n'
import { CAPS } from '../../utils/contract/capabilities'
import { localeFor, regionView, type LoginRegion } from '../../utils/region'

interface AppGlobal { globalData: { metrics: Metrics } }
function boundTexts(region: LoginRegion) {
  const options = getLanguagePickerOptions()
  const pref = getLocalePreference()
  const idx = Math.max(0, options.findIndex((o) => o.code === pref))
  return {
    dir: isRtl() ? 'rtl' : 'ltr',
    languageValue: getCurrentLanguageLabel(),
    languageOptions: options,
    languageIndex: idx,
    navTitle: t('login.title'), phoneLabel: t('login.phone'), phonePlaceholder: t('login.phonePlaceholder'),
    passwordLabel: t('login.password'), passwordPlaceholder: t('login.passwordPlaceholder'),
    submitText: t('login.title'), workingText: t('login.working'), hintText: t('login.passwordHint'),
    reviewText: t('login.review'), passwordModeText: t('login.passwordMode'), reviewCredential: t('login.reviewCredential'),
    registerText: t('login.register'), resetText: t('login.forgotPassword'), webHint: t('login.webHint'),
    regionCnText: t('login.region.cn'), regionIntlText: t('login.region.intl'),
    regionA11y: `${t('login.region.a11y')}: ${t(region === 'intl' ? 'login.region.intl' : 'login.region.cn')}`,
    getAppText: t('login.getApp'),
  }
}
Page({
  data: {
    reviewMode: false, metrics: {} as Metrics, phone: '', password: '', loggingIn: false, submitDisabled: true,
    region: 'cn' as LoginRegion, ...boundTexts('cn'), ...regionView('cn', CAPS.intlAccount),
  },
  onLoad() {
    applyRegionLocale(localeFor('cn'))
    this.setData({ metrics: getApp<AppGlobal>().globalData.metrics, ...boundTexts('cn'), ...regionView('cn', CAPS.intlAccount) })
  },
  onUnload() { applyRegionLocale(localeFor('cn')) },
  refreshButtons() {
    this.setData({ submitDisabled: this.data.loggingIn || this.data.phone.length !== 11 || !this.data.password })
  },
  onToggleRegion() {
    if (this.data.loggingIn) return
    const region: LoginRegion = this.data.region === 'cn' ? 'intl' : 'cn'
    applyRegionLocale(localeFor(region))
    this.setData({ region, reviewMode: false, phone: '', password: '', ...boundTexts(region), ...regionView(region, CAPS.intlAccount) }, () => this.refreshButtons())
  },
  onLanguageChange(e: { detail: { value: string | number } }) {
    if (this.data.loggingIn) return
    const idx = Number(e.detail.value)
    const option = this.data.languageOptions[idx]
    if (!option) return
    const region = this.data.region
    setLocalePreference(option.code, localeFor(region))
    this.setData({ ...boundTexts(region), ...regionView(region, CAPS.intlAccount) })
  },
  onGetApp() { wx.navigateTo({ url: '/pages/download/download' }) },
  onPhoneInput(e: { detail: { value: string } }) {
    if (this.data.loggingIn) return
    this.setData({ phone: e.detail.value.replace(/\D/g, '').slice(0, 11) }, () => this.refreshButtons())
  },
  onPasswordInput(e: { detail: { value: string } }) {
    if (this.data.loggingIn) return
    this.setData({ password: e.detail.value }, () => this.refreshButtons())
  },
  onReview() {
    if (this.data.loggingIn) return
    this.setData({ reviewMode: !this.data.reviewMode, password: '' }, () => this.refreshButtons())
  },
  onRegister() { this.openFlow('register') },
  onReset() { this.openFlow('reset') },
  openFlow(flow: 'register' | 'reset') {
    if (this.data.loggingIn) return
    this.setData({ password: '', reviewMode: false }, () => this.refreshButtons())
    wx.navigateTo({ url: `/pages/account/account?flow=${flow}` })
  },
  async onLogin() {
    if (this.data.submitDisabled || !this.data.showLogin) return
    this.setData({ loggingIn: true }, () => this.refreshButtons())
    try {
      if (this.data.reviewMode) await verifyLoginCode(this.data.phone, this.data.password)
      else await accountLogin(this.data.phone, this.data.password)
      this.setData({ password: '' })
      wx.reLaunch({ url: '/pages/personal/personal' })
    } catch (error) {
      wx.showToast({ icon: 'none', title: (error as ApiError).message })
    } finally {
      this.setData({ loggingIn: false }, () => this.refreshButtons())
    }
  },
})
