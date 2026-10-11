import { sendLoginCode, verifyLoginCode, wxPhoneLogin } from '../../utils/api'
import type { ApiError } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import { t, setLocale } from '../../utils/i18n'
import { CAPS } from '../../utils/contract/capabilities'
import { localeFor, regionView, type LoginRegion } from '../../utils/region'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

const COUNTDOWN_SECONDS = 60

/**
 * 本页所有经 data 绑定的契约文案。切区域会改语言（海外版 → en），改完要整组重新 setData，
 * 界面才会跟着换——t() 只在调用时取词，不会自己触发重绘。
 */
function boundTexts(region: LoginRegion) {
  const regionLabel = t(region === 'intl' ? 'login.region.intl' : 'login.region.cn')
  return {
    navTitle: t('login.title'),
    phoneLabel: t('login.phone'),
    codeLabel: t('login.codeTitle'),
    submitText: t('login.title'),
    wxPhoneText: t('login.wxPhone'),
    useSmsText: t('login.useSms'),
    regionCnText: t('login.region.cn'),
    regionIntlText: t('login.region.intl'),
    // 小程序没有 aria-value，把当前值拼进标签里读出来
    regionA11y: `${t('login.region.a11y')}: ${regionLabel}`,
    getAppText: t('login.getApp'),
  }
}

Page({
  data: {
    metrics: {} as Metrics,
    phone: '',
    code: '',
    sendingCode: false,
    loggingIn: false,
    countdown: 0,
    codeButtonText: t('login.sendCode'),
    sendDisabled: true,
    submitDisabled: true,
    /** 一键登录是首屏；短信表单默认折叠，用户点开或一键登录走不通时才展开 */
    smsOpen: false,
    wxLoggingIn: false,
    /** 账号区域（dev-board#839）：大陆版默认，行为与原登录页一致；
     *  海外版在小程序里不可登录（CAPS.intlAccount），换成英文说明 + 下载 App 入口 */
    region: 'cn' as LoginRegion,
    ...boundTexts('cn'),
    ...regionView('cn', CAPS.intlAccount),
  },

  timer: null as ReturnType<typeof setInterval> | null,

  onLoad() {
    const app = getApp<AppGlobal>()
    // 每次进登录页都从大陆版起步，语言跟着复位（上一次停在海外版时模块级语言还是 en）
    setLocale(localeFor('cn'))
    this.setData({
      metrics: app.globalData.metrics,
      region: 'cn',
      ...boundTexts('cn'),
      ...regionView('cn', CAPS.intlAccount),
    })
  },

  onUnload() {
    if (this.timer) clearInterval(this.timer)
    // 其余页面只有中文界面：离开登录页时把语言还回去
    setLocale(localeFor('cn'))
  },

  /** 手机号 / 验证码 / 倒计时 / 请求中任一变化后，统一重算两个按钮的态。 */
  refreshButtons() {
    const { phone, code, sendingCode, loggingIn, countdown } = this.data
    const phoneValid = phone.length === 11
    const codeValid = code.length === 6
    this.setData({
      sendDisabled: !phoneValid || sendingCode || countdown > 0,
      submitDisabled: !phoneValid || !codeValid || loggingIn,
      codeButtonText: sendingCode
        ? '发送中…'
        : countdown > 0
          ? `${countdown}s 后重新获取`
          : t('login.sendCode'),
    })
  },

  /** 胶囊开关：点任意位置翻到另一边，语言随区域立即切换，整组文案重绑。 */
  onToggleRegion() {
    const region: LoginRegion = this.data.region === 'cn' ? 'intl' : 'cn'
    setLocale(localeFor(region))
    this.setData({ region, ...boundTexts(region), ...regionView(region, CAPS.intlAccount) }, () =>
      this.refreshButtons(),
    )
  },

  onGetApp() {
    wx.navigateTo({ url: '/pages/download/download' })
  },

  onOpenSms() {
    this.setData({ smsOpen: true })
  },

  /**
   * 微信手机号一键登录（dev-board#534，规格 docs/specs/2026-09-09-miniprogram-entry-and-wx-login.md §2）。
   *
   * 三条分支，缺一不可：
   *  - 用户点了拒绝：**不报错**，只把短信表单展开——拒绝授权是正常选择，不是故障；
   *  - 拿到 code 但服务端不给过（本服务器没开通 / 授权过期 / 非大陆号，一律 code 1）：
   *    toast 服务端的 message 并展开短信表单；
   *  - 成功：与 verifyLoginCode 同一条路（会话已在 api 层存好），进项目页。
   */
  onGetPhone(e: WechatMiniprogram.ButtonGetPhoneNumber) {
    const detail = e.detail || {}
    if (!detail.code) {
      // 拒绝授权 / 取消 / 没拿到凭证：都不弹错误，把短信表单展开就是最直接的下一步
      this.setData({ smsOpen: true })
      return
    }

    this.setData({ wxLoggingIn: true })
    wxPhoneLogin(detail.code)
      .then(() => {
        wx.reLaunch({ url: '/pages/index/index' })
      })
      .catch((err: ApiError) => {
        this.setData({ wxLoggingIn: false, smsOpen: true })
        wx.showToast({ icon: 'none', title: err.message })
      })
  },

  onPhoneInput(e: { detail: { value: string } }) {
    this.setData({ phone: e.detail.value.slice(0, 11) }, () => this.refreshButtons())
  },

  onCodeInput(e: { detail: { value: string } }) {
    this.setData({ code: e.detail.value.slice(0, 6) }, () => this.refreshButtons())
  },

  onSendCode() {
    if (this.data.sendDisabled) return
    this.setData({ sendingCode: true }, () => this.refreshButtons())
    sendLoginCode(this.data.phone)
      .then(() => {
        this.setData({ sendingCode: false, countdown: COUNTDOWN_SECONDS }, () => {
          this.refreshButtons()
          this.startCountdown()
        })
      })
      .catch((err: ApiError) => {
        this.setData({ sendingCode: false }, () => this.refreshButtons())
        wx.showToast({ icon: 'none', title: err.message })
      })
  },

  startCountdown() {
    if (this.timer) clearInterval(this.timer)
    this.timer = setInterval(() => {
      const next = this.data.countdown - 1
      if (next <= 0) {
        if (this.timer) clearInterval(this.timer)
        this.timer = null
        this.setData({ countdown: 0 }, () => this.refreshButtons())
      } else {
        this.setData({ countdown: next }, () => this.refreshButtons())
      }
    }, 1000)
  },

  onLogin() {
    if (this.data.submitDisabled) return
    this.setData({ loggingIn: true }, () => this.refreshButtons())
    verifyLoginCode(this.data.phone, this.data.code)
      .then(() => {
        wx.reLaunch({ url: '/pages/index/index' })
      })
      .catch((err: ApiError) => {
        this.setData({ loggingIn: false }, () => this.refreshButtons())
        wx.showToast({ icon: 'none', title: err.message })
      })
  },
})
