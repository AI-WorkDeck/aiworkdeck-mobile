import { accountReferral } from '../../utils/account-flow'
import { getSession } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import { t, isRtl } from '../../utils/i18n'

interface AppGlobal { globalData: { metrics: Metrics } }
/** The website owns first verification and password creation, including WeChat referrals. */
Page({
  data: {
    metrics: {} as Metrics,
    title: '', hint: '', registerText: '', loginText: '', direction: 'ltr',
  },
  ref: '',
  onLoad(query: Record<string, string | undefined> = {}) {
    this.ref = accountReferral(query.ref)
    this.setData({ metrics: getApp<AppGlobal>().globalData.metrics })
  },
  onShow() {
    this.setData({ title: t('intro.title'), hint: t('intro.overview'), registerText: t('login.register'), loginText: t('login.title'), direction: isRtl() ? 'rtl' : 'ltr' })
  },
  onRegister() {
    const suffix = this.ref ? '&ref=' + encodeURIComponent(this.ref) : ''
    wx.navigateTo({ url: '/pages/account/account?flow=register' + suffix })
  },
  onEnterApp() {
    wx.reLaunch({ url: getSession() ? '/pages/index/index' : '/pages/login/login' })
  },
})
