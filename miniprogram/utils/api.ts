/**
 * 后端 API 封装 —— 全小程序唯一网络出口。
 *
 * 契约见 docs/specs/2026-08-20-miniprogram-real-api.md §2；
 * 响应判读语义照抄 iOS 端 ios/Sources/Services/Backend.swift（信封与裸数组两种形状、
 * 网络层失败与业务失败分开说）。鉴权用 X-Session-Id 请求头，与桌面端同门
 * （见 docs/specs/2026-08-20-project-sync-relay.md）。
 */

import { t, wireCodeFor } from './i18n'
import { BACKUP_CONSENT_VERSION } from './contract/capabilities'
import { fromCatalog, sameProject, type CatalogProject, type ProjectLocation } from './project-catalog'

export const BASE_URL = 'https://addin.aiworkdeck.com'

/** 官网（Next.js 站点）。引流页换号走这里，与插件云后端不是一个服务。 */
export const WEB_BASE_URL = 'https://aiworkdeck.com'

/** Envelope.kind：机器可读判别位，contract/schema/billing.schema.json 的 $defs.kind 同一套取值。
 *  各端一律按 kind 分支，禁止匹配 message 措辞——message 经 LangText 在英文部署下会整条变英文。 */
export type ApiErrorKind =
  | 'DISABLED'
  | 'UNAVAILABLE'
  | 'NOT_CONNECTED'
  | 'NOT_FOUND'
  | 'REJECTED'
  | 'REVIEW_ACCOUNT'
  | 'ALREADY_PAID'
  | 'IDEMPOTENCY_CONFLICT'

/** 统一错误：code 是信封里的业务 code；网络层/HTTP 层失败固定为 -1。
 *  kind 是可选的机器可读判别位（缺席多半是非 billing 专有的失败，走通用 handler）；
 *  outTradeNo 仅 kind 为 ALREADY_PAID / IDEMPOTENCY_CONFLICT 时有值。 */
export class ApiError extends Error {
  code: number
  kind: ApiErrorKind | null
  outTradeNo: string | null
  constructor(code: number, message: string, kind: ApiErrorKind | null = null, outTradeNo: string | null = null) {
    super(message)
    this.code = code
    this.kind = kind
    this.outTradeNo = outTradeNo
    this.name = 'ApiError'
  }
}

// ---------- 会话 / 用户 / 选中项目：全部走 wx.*StorageSync ----------

const KEY_SESSION = 'awd.session'
const KEY_USER = 'awd.user'
const KEY_PROJECT = 'awd.project'
const KEY_PHONE = 'awd.phone'

export interface AccountUser {
  id: number
  username: string
  displayName: string
}

export interface LoginResult {
  sessionId: string
  isNewUser: boolean
  user: AccountUser
}

/** 统一项目身份与采集目标快照。旧 deviceId/key 保留作实际上传路由，不能按名称合并。 */
export interface RelayProject {
  projectUid?: string
  locations?: ProjectLocation[]
  deviceId: string
  deviceName: string | null
  key: string
  name: string
}

export interface MediaStatus {
  projectUid?: string
  fileUid?: string
  fileId?: number
  clientMediaId: string
  delivered: boolean
  waitingSeconds: number
  /** 中转区到期时刻（ISO 本地时间字符串），仅未投递件带；投递后不再有意义 */
  expiresAt?: string
}

export function getSession(): string | null {
  const v = wx.getStorageSync(KEY_SESSION)
  return typeof v === 'string' && v ? v : null
}

export function personalAccountScope(): string | null {
  const user = wx.getStorageSync(KEY_USER) as AccountUser | undefined
  return getSession() && user?.id != null ? BASE_URL + ':' + String(user.id) : null
}

function clearFilePreviews(): void {
  const pulls = wx.getStorageSync('awd.filePulls') || {}
  for (const row of Object.values(pulls) as { path?: string }[]) {
    if (row.path) wx.getFileSystemManager().unlink({ filePath: row.path, fail: () => {} })
  }
  wx.removeStorageSync('awd.filePulls')
}

export function setSession(v: string | null): void {
  if (getSession() !== v) {
    clearFilePreviews()
    wx.removeStorageSync('awd.personalConversation')
    setSelectedProject(null)
  }
  if (v) {
    wx.setStorageSync(KEY_SESSION, v)
  } else {
    wx.removeStorageSync(KEY_SESSION)
  }
}

function setUser(u: AccountUser | null): void {
  if (u) {
    wx.setStorageSync(KEY_USER, u)
  } else {
    wx.removeStorageSync(KEY_USER)
  }
}

/** 登录时记下的手机号，「我的」页脱敏展示用。取不到（一键登录且服务端没把号当用户名）就是 null，
 *  页面只显示「账号」两个字，不编一个号码出来。 */
export function getPhone(): string | null {
  const v = wx.getStorageSync(KEY_PHONE)
  return typeof v === 'string' && /^\d{11}$/.test(v) ? v : null
}

/** 只认大陆 11 位数字；别的形态（邮箱用户名等）不记，免得「我的」页脱敏出一串乱码。 */
function rememberPhone(candidate: string | null): void {
  if (candidate && /^\d{11}$/.test(candidate)) {
    wx.setStorageSync(KEY_PHONE, candidate)
  } else {
    wx.removeStorageSync(KEY_PHONE)
  }
}

/** 138****0000。不是 11 位就原样回，不做半吊子脱敏。 */
export function maskPhone(phone: string | null): string {
  if (!phone || !/^\d{11}$/.test(phone)) return phone || ''
  return phone.slice(0, 3) + '****' + phone.slice(7)
}

export function getSelectedProject(): RelayProject | null {
  const v = wx.getStorageSync(KEY_PROJECT)
  return v ? (v as RelayProject) : null
}

export function setSelectedProject(p: RelayProject | null): void {
  if (p) {
    wx.setStorageSync(KEY_PROJECT, p)
  } else {
    wx.removeStorageSync(KEY_PROJECT)
  }
}

// ---------- 统一响应判读 ----------

/**
 * 信封与裸数组共用一套判读，五条规则：
 * 1. HTTP 非 2xx → ApiError(-1, '服务器返回 N')。
 * 2. 体是数组 → 直接成功（裸数组端点：/projects、/media/status）。
 * 3. 体是对象且有数字 code：0 成功取 data；4010 清会话并跳登录后抛错；
 *    其他 code 原样抛错。
 * 4. 体是对象但没有数字 code：默认按解析失败处理——大多数端点的信封必然带数字
 *    code，一个没有 code 的对象体更可能是网关 interstitial / 代理注入 / 后端改了形状，
 *    不是合法响应。只有调用点显式传 `{ bare: true }`（当前只有 /billing/balance 这一条
 *    裸对象端点）才把它当成功直接返回。**不要为了让某个端点跑通而放宽这条判读**——
 *    放宽是全局的，会让 verifyLoginCode 把网关异常响应当登录成功、myProjects/mediaStatus
 *    把非数组交给 groupByDevice 变成运行时 TypeError（dev-board#425 二轮复审 N5）。
 * 5. 都不匹配（HTTP 层正常但体既非数组也非对象，如 null/字符串/数字）→ 解析失败。
 * 网络层失败（wx.request/wx.uploadFile 的 fail 回调）不在这里处理，由调用方分开说。
 *
 * export 仅为了 tests/contract.test.ts 拿 contract/fixtures/billing.json 的
 * envelope 夹具直接跑判读逻辑，不是给业务代码外部调用的公开 API。
 */
export function readEnvelope<T>(statusCode: number, body: unknown, opts: { bare?: boolean } = {}): T {
  if (statusCode < 200 || statusCode >= 300) {
    throw new ApiError(-1, t('error.httpStatus', { code: statusCode }))
  }
  if (Array.isArray(body)) {
    return body as T
  }
  if (body && typeof body === 'object') {
    if (typeof (body as { code?: unknown }).code !== 'number') {
      if (opts.bare) return body as T
      throw new ApiError(-1, t('error.badResponse'))
    }
    const env = body as { code: number; message?: string; data?: T; kind?: ApiErrorKind; outTradeNo?: string }
    if (env.code === 0) {
      return env.data as T
    }
    if (env.code === 4010) {
      // 鉴权失败是 HTTP 200 + {code:4010}，不是 401——实测行为，见契约红线。
      setSession(null)
      wx.reLaunch({ url: '/pages/login/login' })
      throw new ApiError(4010, t('error.signInRequired'))
    }
    throw new ApiError(env.code, env.message || t('error.generic'), env.kind ?? null, env.outTradeNo ?? null)
  }
  throw new ApiError(-1, t('error.badResponse'))
}

function authHeader(): Record<string, string> {
  const session = getSession()
  const headers: Record<string, string> = { 'X-App-Language': wireCodeFor() }
  if (session) headers['X-Session-Id'] = session
  return headers
}

function request<T>(
  url: string,
  method: 'GET' | 'POST' | 'PUT',
  data?: Record<string, unknown>,
  opts: { bare?: boolean; rootEnvelope?: boolean; timeout?: number } = {},
): Promise<T> {
  return new Promise((resolve, reject) => {
    wx.request({
      url: BASE_URL + url,
      method,
      timeout: opts.timeout ?? 30000,
      data,
      header: {
        ...authHeader(),
        ...(method !== 'GET' ? { 'Content-Type': 'application/json' } : {}),
      },
      success: (res) => {
        try {
          const value = readEnvelope<T>(res.statusCode, res.data, opts)
          resolve(opts.rootEnvelope ? res.data as T : value)
        } catch (e) {
          reject(e)
        }
      },
      fail: () => {
        // 网络层失败要与业务失败分开说：用户看到「验证码错误」和看到
        // 「连不上服务器」会做完全不同的事。
        reject(new ApiError(-1, t('error.unreachable')))
      },
    })
  })
}

// ---------- 登录 ----------

/** Website account authority; only a complete mobile identity may be persisted. */
export async function accountLogin(account: string, password: string): Promise<LoginResult> {
  const result = await request<LoginResult>('/api/auth/account-login', 'POST', { account, password })
  if (!result || typeof result.sessionId !== 'string' || !result.sessionId ||
      !result.user || !Number.isSafeInteger(result.user.id) || result.user.id <= 0 ||
      typeof result.user.username !== 'string' || typeof result.user.displayName !== 'string') {
    throw new ApiError(1, t('error.loginNoData'))
  }
  setSession(result.sessionId)
  setUser(result.user)
  rememberPhone(account)
  return result
}

export function sendLoginCode(phone: string): Promise<void> {
  return request<void>('/api/auth/sms-login/send-code', 'POST', { phone })
}

export function verifyLoginCode(phone: string, code: string): Promise<LoginResult> {
  return request<LoginResult>('/api/auth/sms-login/verify', 'POST', { phone, code }).then((result) => {
    setSession(result.sessionId)
    setUser(result.user)
    rememberPhone(phone)
    return result
  })
}

/**
 * 微信手机号一键登录（dev-board#534）。
 *
 * 入参是 button open-type="getPhoneNumber" 回调里的 e.detail.code，服务端拿它去官网
 * 换手机号再发会话；**响应与 sms-login/verify 完全同形**（LoginResult），所以成功路径
 * 与 verifyLoginCode 逐字相同：存会话、存用户、记手机号。
 *
 * 手机号明文不回传，这里只能退而求其次：服务端把手机号当用户名时（findOrCreateByPhone
 * 的既有口径）rememberPhone 会认出来，认不出就不记，「我的」页少显示一行号码而已。
 *
 * 业务失败一律走信封 code 1（本服务器没开通 / 授权过期 / 非大陆号），调用方 toast
 * message 并把短信表单展开——一键登录不可用不是死路。
 */
export function wxPhoneLogin(code: string): Promise<LoginResult> {
  return request<LoginResult>('/api/auth/wx-phone-login', 'POST', { code }).then((result) => {
    setSession(result.sessionId)
    setUser(result.user)
    rememberPhone(result.user ? result.user.username : null)
    return result
  })
}

/** 清会话 + 用户 + 已选项目 + 记下的手机号，登出必须一起清，不然守门逻辑会判断错、
 *  「我的」页还会挂着上一个人的号码。 */
export function logout(): void {
  setSession(null)
  setUser(null)
  setSelectedProject(null)
  rememberPhone(null)
}

// ---------- 统一账户余额（dev-board#425/#429） ----------

export interface SubscriptionBalance {
  active: boolean
  availableCents: number
  monthlyLimitCents: number
  monthlyUsedCents: number
  weeklyLimitCents: number
  weeklyUsedCents: number
}

export interface BillingBalance {
  balanceCents: number
  currency: 'CNY' | 'USD'
  plan: string | null
  subscription?: SubscriptionBalance
}

/**
 * 统一账户余额。裸对象成功；未登录/未关联/官网不可达等一律 Envelope(code 1) 走
 * readEnvelope 的信封分支抛错，绝不会用余额 0 冒充失败。本期只读余额，不放充值入口
 * （App Store 3.1.3 硬约束，站外充值行动号召会触发强制内购）。
 *
 * 唯一传 `{ bare: true }` 的调用点：裸对象响应没有数字 code，其余端点一律走默认的
 * 严格判读（见 readEnvelope 规则 4，dev-board#425 二轮复审 N5）。
 */
export function billingBalance(): Promise<BillingBalance> {
  return request<BillingBalance>('/api/mobile/billing/balance', 'GET', undefined, { bare: true })
}

// ---------- 充值（dev-board#427，小程序走微信虚拟支付） ----------

/** 充值通道。不传这个字段是第一期行为（走站点默认通道）；小程序一律传 wxvp。 */
export type RechargeChannel = 'wxvp'

/** 契约的 present 全集（contract/schema/billing.schema.json）。小程序只会收到 virtual，
 *  其余取值照样解码：解码器是契约的实现，不是本页的实现。 */
export type RechargePresent = 'qrcode' | 'redirect' | 'virtual' | 'native'

/** 服务端裸响应原文：不适用的键**不出现**（服务端 putIfPresent 对 null 与空串都不出键）。 */
export interface RawRechargeOrder {
  present: RechargePresent
  outTradeNo: string
  amountCents: number
  codeUrl?: string
  qrCode?: string
  redirectUrl?: string
  signData?: string
  paySig?: string
  signature?: string
  appAccountToken?: string
}

/** 解码后的充值单：缺席的可选键一律是 null，不是空串也不是 undefined
 *  （contract/schema/billing.schema.json 的 recharge 段把这条钉死，
 *  contract/fixtures/billing.json 的 recharge 用例逐条对拍）。 */
export interface RechargeOrder {
  present: RechargePresent
  outTradeNo: string
  amountCents: number
  codeUrl: string | null
  qrCode: string | null
  redirectUrl: string | null
  /** present=virtual：签名原文，**必须原样透传**给 wx.requestVirtualPayment。
   *  端上重新 JSON.stringify 一遍键序/空白就变了，paySig 与 signature 立刻对不上。 */
  signData: string | null
  paySig: string | null
  signature: string | null
  /** present=native（iOS 内购，dev-board#426）：订单与 StoreKit 交易的挂钩 UUID。
   *  小程序侧永远是 null，留在这里是因为解码器实现的是契约而不是某一端。 */
  appAccountToken: string | null
}

export interface RechargeStatus {
  status: 'pending' | 'paid' | 'closed' | 'expired'
  paid: boolean
  amountCents: number
}

const optional = (v: string | undefined): string | null => (v ? v : null)

/** 生产解码路径。tests/contract.test.ts 拿 contract/fixtures/billing.json 的 recharge 段对拍它，
 *  不在测试里另抄一份结构体。 */
export function decodeRechargeOrder(raw: RawRechargeOrder): RechargeOrder {
  return {
    present: raw.present,
    outTradeNo: raw.outTradeNo,
    amountCents: raw.amountCents,
    codeUrl: optional(raw.codeUrl),
    qrCode: optional(raw.qrCode),
    redirectUrl: optional(raw.redirectUrl),
    signData: optional(raw.signData),
    paySig: optional(raw.paySig),
    signature: optional(raw.signature),
    appAccountToken: optional(raw.appAccountToken),
  }
}

/**
 * 创建充值单。裸对象成功，业务失败走信封（code 1 + kind）：
 * ALREADY_PAID / IDEMPOTENCY_CONFLICT 会连 outTradeNo 一起回来，调用方按 kind 分支恢复。
 *
 * idempotencyKey 由客户端生成并**先落盘再发**（服务端不代生成，缺失即 code 1 无 kind）。
 */
export function billingRecharge(opts: {
  channel: RechargeChannel
  productId: string
  amountCents: number
  idempotencyKey: string
  wxCode: string
}): Promise<RechargeOrder> {
  return request<RawRechargeOrder>('/api/mobile/billing/recharge', 'POST', { ...opts }, { bare: true }).then(
    decodeRechargeOrder,
  )
}

/** 查充值单状态。裸对象，三个字段都必有，没有可选键要补 null。 */
export function billingRechargeStatus(outTradeNo: string): Promise<RechargeStatus> {
  return request<RechargeStatus>('/api/mobile/billing/recharge/status', 'GET', { outTradeNo }, { bare: true })
}

// ---------- 引流页：一键手机号建号（dev-board#305） ----------

export interface WxStartResult {
  username: string
  displayName: string
  isNewUser: boolean
  /** 一次性登录票据（10 分钟有效），官网 /api/auth/wx-ticket 可换会话；手机号明文不回传 */
  ticket: string
}

/**
 * 把 button open-type="getPhoneNumber" 的 code 交给官网换号建号。
 *
 * 打的是官网（WEB_BASE_URL）不是插件云后端：响应是官网风格的裸 JSON
 * （成功含 user，失败含 error），不走 readEnvelope 那套信封判读。
 */
export function wxPhoneStart(code: string, ref: string): Promise<WxStartResult> {
  return new Promise((resolve, reject) => {
    wx.request({
      url: WEB_BASE_URL + '/api/auth/wx-phone',
      method: 'POST',
      data: { code, ref },
      header: { 'Content-Type': 'application/json' },
      success: (res) => {
        const body = (res.data ?? {}) as {
          user?: { username: string; displayName: string }
          isNewUser?: boolean
          ticket?: string
          error?: string
          message?: string
        }
        if (res.statusCode >= 200 && res.statusCode < 300 && body.user) {
          resolve({
            username: body.user.username,
            displayName: body.user.displayName,
            isNewUser: body.isNewUser === true,
            ticket: body.ticket || '',
          })
          return
        }
        // 官网端错误码翻译成用户能行动的话（文案红线：不出现「登录/未授权/请先」）
        const msg =
          body.error === 'invalid_wx_code'
            ? t('error.wxAuthExpired')
            : body.error === 'unsupported_region'
              ? body.message || t('error.regionCnOnly')
              : body.error === 'rate_limited'
                ? t('error.rateLimited')
                : t('error.serviceUnavailable')
        reject(new ApiError(-1, msg))
      },
      fail: () => {
        reject(new ApiError(-1, t('error.unreachable')))
      },
    })
  })
}

// ---------- 项目与上传 ----------

/** 账号级云目录，裸数组。仅补旧记录的身份元数据，不修改其已锁定的上传地址。 */
export function myProjects(): Promise<RelayProject[]> {
  return request<CatalogProject[]>('/api/mobile/catalog', 'GET').then(items => {
    const projects = items.map(fromCatalog)
    const selected = getSelectedProject()
    const match = selected && projects.find(p => sameProject(p, selected))
    if (selected && match) setSelectedProject({ ...selected, projectUid: match.projectUid, locations: match.locations })
    const queue: unknown = wx.getStorageSync('awd.queue')
    if (Array.isArray(queue)) {
      for (const row of queue) {
        const target = projects.find(p => sameProject(p, { deviceId: row.deviceId, key: row.projectKey,
          name: row.projectName, deviceName: null, projectUid: row.projectUid }))
        if (target) row.projectUid = target.projectUid
      }
      wx.setStorageSync('awd.queue', queue)
    }
    return projects
  })
}

/** 影像投递状态，裸数组。ids 为空直接返回 []，不发请求。 */
export function mediaStatus(ids: string[]): Promise<MediaStatus[]> {
  if (ids.length === 0) return Promise.resolve([])
  return request<MediaStatus[]>('/api/mobile/media/status', 'GET', { clientMediaIds: ids.join(',') })
}

/** 上传一件现场影像到中转区。幂等键是 clientMediaId，弱网重传不会产生重复件。 */
export function uploadMedia(opts: {
  filePath: string
  deviceId: string
  projectKey: string
  clientMediaId: string
  fileName: string
  mediaType: 'image' | 'video' | 'audio'
  capturedAt: string
  onProgress?: (percent: number) => void
}): Promise<void> {
  return new Promise((resolve, reject) => {
    const task = wx.uploadFile({
      url: BASE_URL + '/api/mobile/media',
      filePath: opts.filePath,
      name: 'file',
      header: authHeader(),
      formData: {
        deviceId: opts.deviceId,
        projectKey: opts.projectKey,
        clientMediaId: opts.clientMediaId,
        fileName: opts.fileName,
        mediaType: opts.mediaType,
        capturedAt: opts.capturedAt,
      },
      success: (res) => {
        // uploadFile 的 res.data 是字符串，先解出来再走同一套信封判读。
        try {
          let body: unknown
          try {
            body = JSON.parse(res.data)
          } catch {
            throw new ApiError(-1, t('error.badResponse'))
          }
          readEnvelope<void>(res.statusCode, body)
          resolve()
        } catch (e) {
          reject(e)
        }
      },
      fail: () => {
        reject(new ApiError(-1, t('error.unreachable')))
      },
    })
    if (opts.onProgress) {
      const onProgress = opts.onProgress
      task.onProgressUpdate((r) => onProgress(r.progress))
    }
  })
}

/** v4 UUID，小写。小程序没有 crypto.randomUUID 保证，用 Math.random 拼即可
 *  （只作幂等键，非安全用途）。 */
export function uuid(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

/** File transfer endpoints keep successful payload fields alongside code. */
export function fileRequest<T>(path: string, data?: Record<string, unknown>, bare = false): Promise<T> {
  return request<T>(path, data ? 'POST' : 'GET', data, { bare, rootEnvelope: true })
}
export function downloadProjectContent(path: string, expectedSize: number): Promise<string> {
  return new Promise((resolve, reject) => {
    let contentType = ''
    const task = wx.downloadFile({ url: BASE_URL + path, header: authHeader(),
      success: result => {
        if (result.statusCode !== 200 || contentType !== 'application/octet-stream') { reject(new ApiError(-1, t('files.error.transferFailed'))); return }
        wx.getFileSystemManager().getFileInfo({ filePath: result.tempFilePath,
          success: info => {
            if (info.size === expectedSize) resolve(result.tempFilePath)
            else reject(new ApiError(-1, t('files.error.response')))
          }, fail: () => reject(new ApiError(-1, t('files.error.response'))),
        })
      }, fail: () => reject(new ApiError(-1, t('files.error.transferFailed'))),
    })
    task.onHeadersReceived(({ header }) => {
      for (const name of Object.keys(header)) {
        if (name.toLowerCase() === 'content-type') contentType = String(header[name]).split(';')[0].trim().toLowerCase()
      }
      if (contentType !== 'application/octet-stream') task.abort()
    })
    task.onProgressUpdate(progress => {
      if (progress.totalBytesWritten > expectedSize || progress.totalBytesExpectedToWrite > expectedSize) task.abort()
    })
  })
}

export interface BackupConsent {
  enabled: boolean
  decided: boolean
  subscriptionActive: boolean
  consentVersion: string | null
}
export function backupConsent(): Promise<BackupConsent> {
  return request<BackupConsent>('/api/mobile/backup-consent', 'GET', undefined, { bare: true })
}
export function setBackupConsent(enabled: boolean): Promise<BackupConsent> {
  return request<BackupConsent>('/api/mobile/backup-consent', 'PUT', { enabled, consentVersion: BACKUP_CONSENT_VERSION }, { bare: true })
}

/** Account-scoped personal workspace endpoints use code/data envelopes. */
export async function personalRequest<T>(path: string, method: 'GET' | 'POST' | 'PUT' = 'GET', data?: Record<string, unknown>): Promise<T> {
  const account = getSession()
  if (!account) throw new ApiError(4010, t('error.signInRequired'))
  const result = await request<T>('/api/mobile/' + path, method, data, { timeout: 240000 })
  if (getSession() !== account) throw new ApiError(4010, t('files.error.closed'))
  return result
}

// A preview target is not an archive destination. Consume once when opening the file page.
let personalPreview: { session: string | null; project: RelayProject } | null = null
export function setPersonalPreview(project: RelayProject): void { personalPreview = { session: getSession(), project } }
export function takePersonalPreview(): RelayProject | null {
  const value = personalPreview; personalPreview = null
  return value?.session === getSession() ? value?.project ?? null : null
}
