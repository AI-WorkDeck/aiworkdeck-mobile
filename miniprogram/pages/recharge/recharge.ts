/**
 * 充值页 —— 微信小程序虚拟支付（dev-board#427）。
 *
 * 六步流程与判定条件的唯一来源是
 * docs/specs/2026-09-09-miniprogram-virtual-payment-plan.md §5：
 * 幂等键先落盘 → wx.login 取 code → 下单 → wx.requestVirtualPayment → 轮询查单 → 收尾。
 *
 * 档位只能来自契约（contract/products.json → utils/contract/products.ts），
 * 页面里不许手抄一份价格：官网侧另有权威表复核，两边不一致会被回成 REJECTED。
 */
import { billingRecharge, billingRechargeStatus, uuid } from '../../utils/api'
import type { ApiError, RechargeOrder } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import { PRODUCTS } from '../../utils/contract/products'
import { t } from '../../utils/i18n'
import { formatMoney } from '../../utils/money'
import { reportDiag } from '../../utils/diag'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

/** 幂等键落盘的键名。值是 { key, productId }：换档位要换键，同档位复用。 */
const KEY_IDEM = 'awd.recharge.idem'

const POLL_INTERVAL_MS = 1500
const POLL_MAX_TRIES = 8
/** 成功 toast 停留多久再返回上一页（项目页 onShow 会重新拉余额） */
const BACK_DELAY_MS = 900

/** wxvp 只用在大陆小程序，档位一律人民币。 */
const CURRENCY = 'CNY' as const

interface TierRow {
  productId: string
  amountCents: number
  label: string
}

function tiersFor(): TierRow[] {
  return PRODUCTS.wxvp.map((p) => ({
    productId: p.productId,
    amountCents: p.amountCents,
    label: t('recharge.tier', { amount: formatMoney(p.amountCents, CURRENCY) }),
  }))
}

interface PendingIdem {
  key: string
  productId: string
}

/**
 * 幂等键**生成后先写 storage 再发请求**：支付流程中小程序被杀掉后重进本页，
 * 同一档位复用同一把键，服务端 UNIQUE(userId, idempotencyKey) 兜底，不会变成两笔单。
 */
function takeIdempotencyKey(productId: string): string {
  const saved = wx.getStorageSync(KEY_IDEM) as PendingIdem | '' | null
  if (saved && saved.key && saved.productId === productId) return saved.key
  const key = uuid()
  const pending: PendingIdem = { key, productId }
  wx.setStorageSync(KEY_IDEM, pending)
  return key
}

function clearIdempotencyKey(): void {
  wx.removeStorageSync(KEY_IDEM)
}

function wxLogin(): Promise<string> {
  return new Promise((resolve, reject) => {
    wx.login({
      success: (res) => {
        if (res.code) resolve(res.code)
        else reject(new Error(t('recharge.failed')))
      },
      fail: () => reject(new Error(t('recharge.failed'))),
    })
  })
}

type PayResult = 'ok' | 'cancelled' | 'failed'
/** 最近一次微信支付 fail 的原文（errCode + errMsg），失败提示里带上，真机才能定位（dev-board#427） */
let lastPayError = ''

/**
 * 唤起虚拟支付。signData 原样透传：这一串是服务端签名时用的原文，
 * 端上重新序列化一遍键序/空白就变了，paySig 与 signature 立刻对不上。
 * （类型声明把 signData 写成了对象，与微信文档「该参数需以 string 形式传递」不符，
 * 所以这里必须绕过声明，不能顺着声明去传对象。）
 */
function requestVirtualPayment(order: RechargeOrder): Promise<PayResult> {
  const { signData, paySig, signature } = order
  if (!signData || !paySig || !signature) return Promise.resolve<PayResult>('failed')
  return new Promise<PayResult>((resolve) => {
    const option = {
      mode: 'short_series_goods',
      signData,
      paySig,
      signature,
      success: () => resolve('ok'),
      fail: (err: { errMsg?: string; errCode?: number; errno?: number }) => {
        const msg = String(err && err.errMsg ? err.errMsg : '')
        const code = err && (err.errCode !== undefined ? err.errCode : err.errno)
        lastPayError = `${code !== undefined ? code + ' ' : ''}${msg}`
        resolve(msg.indexOf('cancel') >= 0 ? 'cancelled' : 'failed')
      },
    }
    wx.requestVirtualPayment(option as unknown as WechatMiniprogram.RequestVirtualPaymentOption)
  })
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

Page({
  data: {
    metrics: {} as Metrics,
    navTitle: t('recharge.title'),
    pickText: t('recharge.pick'),
    payText: t('recharge.pay'),
    tiers: tiersFor(),
    selected: 0,
    paying: false,
    hint: '',
  },

  backTimer: null as ReturnType<typeof setTimeout> | null,

  onLoad() {
    const app = getApp<AppGlobal>()
    this.setData({
      metrics: app.globalData.metrics,
      navTitle: t('recharge.title'),
      pickText: t('recharge.pick'),
      payText: t('recharge.pay'),
      tiers: tiersFor(),
    })
  },

  onUnload() {
    if (this.backTimer) clearTimeout(this.backTimer)
  },

  onSelectTier(e: { currentTarget: { dataset: { i: number } } }) {
    if (this.data.paying) return
    this.setData({ selected: e.currentTarget.dataset.i })
  },

  async onPay() {
    if (this.data.paying) return
    const tier = this.data.tiers[this.data.selected]
    if (!tier) return
    this.setData({ paying: true, hint: t('recharge.paying') })
    try {
      const placed = await this.placeOrder(tier, true)
      if (placed.pay !== 'ok') {
        // 取消与失败都**不清**幂等键：同一档再点一次要复用同一把键，不能变成两笔单
        if (placed.pay === 'cancelled') {
          this.settle(t('recharge.cancelled'))
        } else {
          reportDiag(t('diag.payFailed'), lastPayError || t('diag.noWxErrMsg'))
          this.settle(`${t('recharge.failed')} ${lastPayError}`.trim())
        }
        return
      }
      if (await this.pollUntilPaid(placed.outTradeNo)) {
        clearIdempotencyKey()
        this.settle(t('recharge.success'))
        this.backTimer = setTimeout(() => wx.navigateBack(), BACK_DELAY_MS)
      } else {
        // 轮询超时不等于失败：微信侧的发货通知也会把这笔单入账，所以幂等键留着
        this.settle(t('recharge.pendingLong'))
      }
    } catch (e) {
      // 服务端给的 message 经 LangText 已是可读话术，原样展示；不按 message 措辞分支
      this.settle((e as ApiError).message)
    }
  },

  /** 第 1–4 步。返回可查单的 outTradeNo 与支付环节的结果。 */
  async placeOrder(tier: TierRow, retryOnConflict: boolean): Promise<{ outTradeNo: string; pay: PayResult }> {
    const idempotencyKey = takeIdempotencyKey(tier.productId)
    const wxCode = await wxLogin()
    try {
      const order = await billingRecharge({
        channel: 'wxvp',
        productId: tier.productId,
        amountCents: tier.amountCents,
        idempotencyKey,
        wxCode,
      })
      return { outTradeNo: order.outTradeNo, pay: await requestVirtualPayment(order) }
    } catch (e) {
      const err = e as ApiError
      // 这把键的单子已经付过了：不重新下单，拿服务端回的单号直接去查单
      if (err.kind === 'ALREADY_PAID' && err.outTradeNo) return { outTradeNo: err.outTradeNo, pay: 'ok' }
      // 同一把键换了金额/类型：丢掉旧键换新键重来一次，只重来一次，避免打转
      if (err.kind === 'IDEMPOTENCY_CONFLICT' && retryOnConflict) {
        clearIdempotencyKey()
        return this.placeOrder(tier, false)
      }
      throw err
    }
  },

  /** 第 5 步：间隔 1.5 秒最多查 8 次。单次查单失败不打断轮询。 */
  async pollUntilPaid(outTradeNo: string): Promise<boolean> {
    for (let i = 0; i < POLL_MAX_TRIES; i++) {
      await sleep(POLL_INTERVAL_MS)
      try {
        const status = await billingRechargeStatus(outTradeNo)
        if (status.paid) return true
      } catch {
        /* 查单这一次没成不代表没到账，接着轮询；轮完还没到账走 pendingLong */
      }
    }
    return false
  },

  settle(message: string) {
    this.setData({ paying: false, hint: message })
    wx.showToast({ title: message, icon: 'none' })
  },
})
