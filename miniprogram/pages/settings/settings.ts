import { chooseBackupConsent } from '../../utils/backup-consent'
/**
 * 「我的」页（dev-board#535）。
 *
 * 起因是第二期上线后的实测反馈：充值入口挂在项目页页脚、且只在余额行可见时才渲染，
 * 而没有官网账户的用户余额是 NOT_CONNECTED、整行不渲染——充值口在界面上根本找不到。
 * 现在账户相关的东西（手机号、余额、充值、退出登录、版本）统一收进这一页，
 * 项目页只管选项目。
 *
 * 余额行与充值入口的显隐规则一律走契约（contract/schema/billing.schema.json 的 UI 映射，
 * 实现在 utils/money.ts 的 balanceRowForError），按 kind 分支，不匹配 message 措辞。
 */
import { billingBalance, getPhone, logout, maskPhone, backupConsent, setBackupConsent, getSession } from '../../utils/api'
import type { ApiError, BillingBalance } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import {
  t,
  getLocalePreference,
  setLocalePreference,
  getCurrentLanguageLabel,
  getLanguagePickerOptions,
  isRtl,
  type LocalePreference,
} from '../../utils/i18n'
import { balanceRowForError, formatMoney } from '../../utils/money'
import { CAPS } from '../../utils/contract/capabilities'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

/** 本端有没有充值通道：contract/capabilities.json 的 recharge，**非 false 即有**
 *  （小程序当前是微信虚拟支付 virtual）。生成物把它收窄成了字面量类型，这里放宽一档再比——
 *  页面不该写死某一种通道名，将来多一种通道也不用改这一页。 */
const CAN_RECHARGE: boolean = (CAPS.recharge as string | false) !== false

/** 金额格式化按契约统一口径（contract/schema/billing.schema.json），不在这里重写。 */
function credits(cents: number): string {
  return t('subscription.credits', { amount: (cents / 100).toFixed(2) })
}

function formatBalance(b: BillingBalance): string {
  return t('balance.amount', { amount: formatMoney(b.balanceCents, b.currency) })
}

/** 小程序版本号。体验版 / 开发版拿不到，回落 settings.devBuild。 */
function miniProgramVersion(): string {
  try {
    const info = wx.getAccountInfoSync()
    return info.miniProgram.version || t('settings.devBuild')
  } catch {
    return t('settings.devBuild')
  }
}

function languageState() {
  const options = getLanguagePickerOptions()
  const pref = getLocalePreference()
  const idx = Math.max(0, options.findIndex((o) => o.code === pref))
  return {
    dir: isRtl() ? 'rtl' : 'ltr',
    languageLabel: t('settings.language'),
    languageValue: getCurrentLanguageLabel(),
    languageOptions: options,
    languageIndex: idx,
  }
}

Page({
  data: {
    metrics: {} as Metrics,
    dir: 'ltr',
    navTitle: t('settings.title'),
    accountLabel: t('settings.account'),
    phoneText: '',
    balanceTitle: t('balance.title'),
    // 未知态（还没拉到结果）不渲染，避免先出现空壳行再消失的首帧闪烁（与项目页原来同一口径）
    balanceVisible: false,
    balanceText: '',
    subscriptionRows: [] as { label: string, value: string }[],
    // 充值入口跟余额行分开算：NOT_CONNECTED 时行在、入口也要在（dev-board#535）
    rechargeVisible: false,
    rechargeText: t('recharge.entry'),
    // 「充值后即开通统一账户」只在 NOT_CONNECTED 时说，别的态说这句是废话
    openHint: '',
    languageLabel: t('settings.language'),
    languageValue: '',
    languageOptions: [] as { code: LocalePreference; label: string }[],
    languageIndex: 0,
    versionLabel: t('settings.version'),
    versionText: '',
    signOutText: t('common.signOut'),
    backupTitle: t('backup.title'), backupText: '', backupBusy: false,
  },

  onLoad() {
    const app = getApp<AppGlobal>()
    this.setData({
      metrics: app.globalData.metrics,
      navTitle: t('settings.title'),
      accountLabel: t('settings.account'),
      phoneText: maskPhone(getPhone()),
      balanceTitle: t('balance.title'),
      rechargeText: t('recharge.entry'),
      versionLabel: t('settings.version'),
      versionText: miniProgramVersion(),
      signOutText: t('common.signOut'),
      backupTitle: t('backup.title'),
      ...languageState(),
    })
  },

  onShow() {
    this.setData({
      navTitle: t('settings.title'),
      accountLabel: t('settings.account'),
      balanceTitle: t('balance.title'),
      rechargeText: t('recharge.entry'),
      versionLabel: t('settings.version'),
      versionText: miniProgramVersion(),
      signOutText: t('common.signOut'),
      backupTitle: t('backup.title'),
      ...languageState(),
    })
    // 从充值页返回也走这里：付完钱回来余额要是新的
    this.loadBalance()
    this.loadBackup()
  },

  onLanguageChange(e: { detail: { value: string | number } }) {
    const idx = Number(e.detail.value)
    const option = this.data.languageOptions[idx]
    if (!option) return
    setLocalePreference(option.code)
    this.setData({
      navTitle: t('settings.title'),
      accountLabel: t('settings.account'),
      balanceTitle: t('balance.title'),
      rechargeText: t('recharge.entry'),
      versionLabel: t('settings.version'),
      versionText: miniProgramVersion(),
      signOutText: t('common.signOut'),
      backupTitle: t('backup.title'),
      ...languageState(),
    })
    this.loadBalance()
    this.loadBackup()
  },

  /** 成功显示金额、充值入口按本端能力显隐；失败一律按 kind 走 balanceRowForError。 */
  loadBalance() {
    billingBalance()
      .then((b) => {
        this.setData({
          balanceVisible: true,
          balanceText: formatBalance(b),
          subscriptionRows: b.subscription?.active ? [
            { label: t('subscription.available'), value: credits(b.subscription.availableCents) },
            { label: t('subscription.weekly'), value: `${credits(b.subscription.weeklyUsedCents)} / ${credits(b.subscription.weeklyLimitCents)}` },
            { label: t('subscription.monthly'), value: `${credits(b.subscription.monthlyUsedCents)} / ${credits(b.subscription.monthlyLimitCents)}` },
          ] : [],
          rechargeVisible: CAN_RECHARGE,
          openHint: '',
        })
      })
      .catch((err: ApiError) => {
        const plan = balanceRowForError(err.kind, CAN_RECHARGE)
        this.setData({
          subscriptionRows: [],
          balanceVisible: plan.showRow,
          balanceText: plan.textKey ? t(plan.textKey) : '',
          rechargeVisible: plan.showRecharge,
          openHint: plan.textKey === 'balance.notConnected' ? t('recharge.openHint') : '',
        })
      })
  },

  async loadBackup() {
    const session = getSession()
    try {
      const state = await backupConsent()
      if (session === getSession()) this.setData({ backupText: t(state.enabled ? 'backup.enabled' : 'backup.disabled') })
    } catch { if (session === getSession()) this.setData({ backupText: t('backup.error') }) }
  },

  async onBackup() {
    if (this.data.backupBusy) return
    const session = getSession()
    this.setData({ backupBusy: true })
    try {
      const state = await backupConsent()
      if (session !== getSession()) return
      if (state.enabled) {
        const result = await wx.showModal({ title: t('backup.disable'), content: t('backup.disableMessage') })
        if (result.confirm && session === getSession()) await setBackupConsent(false)
      } else { await chooseBackupConsent(state) }
      if (session === getSession()) await this.loadBackup()
    } catch {
      if (session === getSession()) wx.showToast({ icon: 'none', title: t('backup.error') })
    } finally { this.setData({ backupBusy: false }) }
  },

  onRecharge() {
    wx.navigateTo({ url: '/pages/recharge/recharge' })
  },

  onLogout() {
    wx.showModal({
      title: t('common.signOut'),
      content: t('settings.signOut.confirm'),
      confirmText: t('settings.signOut.action'),
      confirmColor: '#B5483C', // danger（dev-board#731 #732 #733；原生 API 参数无法用 CSS 变量）
      success: (res) => {
        if (res.confirm) {
          logout()
          wx.reLaunch({ url: '/pages/login/login' })
        }
      },
    })
  },
})
