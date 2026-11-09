import { pauseCloudUploads } from '../../utils/queue'
import { cloudBillingState, acceptPostpaid, resumeCloud, reconnectCloud, invalidateCloudEpoch, getSession } from '../../utils/api'
import type { PostpaidState } from '../../utils/cloud-access'
import type { Metrics } from '../../utils/layout'
import { t, isRtl } from '../../utils/i18n'
import { formatMoney } from '../../utils/money'
/**
 * 后付费详情页：设置页只留一行状态，授信、费率、条款与开通/还款/恢复都在这里。
 * 大多数人从没开通过后付费，不该在设置首屏读一整段扣费条款。
 */

interface AppGlobal {
  globalData: { metrics: Metrics }
}

function labels() {
  return {
    dir: isRtl() ? 'rtl' : 'ltr',
    navTitle: t('postpaid.title'),
    postpaidNotice: t('postpaid.notice'),
    postpaidAccept: t('postpaid.accept'),
    postpaidRepay: t('postpaid.repay'),
    postpaidResume: t('postpaid.resume'),
    retryText: t('project.retry'),
  }
}

Page({
  postpaid: null as PostpaidState | null,
  postpaidSession: null as string | null,
  data: {
    metrics: {} as Metrics,
    ...labels(),
    loaded: false,
    postpaidRows: [] as {label: string, value: string, alert: boolean}[],
    rateLines: [] as string[],
    postpaidState: '', postpaidError: '', postpaidBusy: false,
    canAcceptPostpaid: false, canResumeCloud: false, hasDebt: false,
  },

  onLoad() {
    this.setData({ metrics: getApp<AppGlobal>().globalData.metrics, ...labels() })
  },

  onShow() {
    this.setData(labels())
    this.loadPostpaid()
  },

  async loadPostpaid(accept = false, resume = false) {
    if (this.data.postpaidBusy) return
    const session = getSession()
    if ((accept || resume) && session !== this.postpaidSession) return
    this.setData({postpaidBusy: true, postpaidError: ''})
    try {
      if (resume) { invalidateCloudEpoch(); pauseCloudUploads() }
      const state = resume && this.postpaid?.cloudAccess.frozen ? await resumeCloud(this.postpaid.billing.policyVersion) : accept && this.postpaid ? await acceptPostpaid(this.postpaid.billing.policyVersion) : await cloudBillingState()
      if (session !== getSession()) return
      if (accept || resume) { await reconnectCloud() }
      this.postpaid = state
      this.postpaidSession = session
      const b = state.billing
      const rows = [
        {label: t('postpaid.limit'), value: formatMoney(b.creditLimitCents, b.cashCurrency), alert: false},
        {label: t('postpaid.available'), value: formatMoney(b.availableCreditCents, b.cashCurrency), alert: false},
        {label: t('postpaid.debt'), value: formatMoney(b.debtCents, b.cashCurrency), alert: b.debtCents > 0},
      ]
      for (const [key, value] of [['postpaid.remind', b.remindAt], ['postpaid.cleanup', b.cleanupAt]]) if (value) rows.push({label: t(key!), value: new Date(value).toLocaleString(), alert: false})
      const rateLines = [t('postpaid.storageRate', {amount: formatMoney(b.storagePrice.cashCentsPerGiBMonth, b.storagePrice.cashCurrency)})]
      if (b.egressPrice) rateLines.push(t('postpaid.egressRate', {amount: formatMoney(b.egressPrice.cashCentsPerGiB, b.egressPrice.cashCurrency)}))
      this.setData({loaded: true, postpaidRows: rows, rateLines, canResumeCloud: b.accepted && (state.cloudAccess.frozen !== true || b.debtCents === 0), canAcceptPostpaid: !b.accepted && b.acceptEnabled && !!b.egressPrice, hasDebt: b.debtCents > 0, postpaidState: state.cloudAccess.cleanupState === 'complete' ? t('postpaid.cleared') : b.accepted && !state.cloudAccess.canUse ? t('postpaid.restricted') : ''})
    } catch { if (session === getSession()) this.setData({postpaidError: t('balance.unavailable')}) }
    finally { if (session === getSession()) this.setData({postpaidBusy: false}) }
  },
  async onAcceptPostpaid() {
    if (!this.data.canAcceptPostpaid || this.data.postpaidBusy) return
    const session = getSession()
    if (session !== this.postpaidSession) return
    const result = await wx.showModal({title: t('postpaid.accept'), content: t('postpaid.notice'), confirmText: t('common.on')})
    if (result.confirm && session === getSession()) await this.loadPostpaid(true)
  },
  async onResumeCloud() {
    if (!this.data.canResumeCloud || this.data.postpaidBusy || getSession() !== this.postpaidSession) return
    const session = getSession()
    const result = await wx.showModal({title: t('postpaid.resume'), content: t('postpaid.resumeNotice'), confirmText: t('common.on')})
    if (result.confirm && session === getSession()) await this.loadPostpaid(false, true)
  },
  onPostpaidRetry() { this.loadPostpaid() },
  onRepay() { wx.navigateTo({ url: '/pages/recharge/recharge' }) },
})
