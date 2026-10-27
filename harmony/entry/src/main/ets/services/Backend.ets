import { ContractCapabilities } from 'contract'
import { BackupConsent, decodeBackupConsent } from '../model/ProjectFiles'
import { http } from '@kit.NetworkKit'
import { JSON as ArkJson } from '@kit.ArkTS'
import { ApiError, Unauthorized, checkEnvelope } from '../model/Envelope'
import { RelayProject } from '../model/Capture'
import { SessionStore } from './SessionStore'
import { AccountRegion, baseUrlOf, currentAppLanguage } from '../model/AccountRegion'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  LoginResult, MediaStatus, MediaUsage, SubscriptionBalance, decodeSubscriptionBalance,
  asRecord, decodeLoginResult, decodeMediaStatuses, decodeMediaUsage, decodeCatalog,
} from './ApiTypes'

const CONNECT_TIMEOUT_MS: number = 15000
const READ_TIMEOUT_MS: number = 30000
const DOMAIN: number = 0x0000
const TAG: string = 'Backend'

/**
 * 后端调用。语义逐条对照安卓 Backend.kt：
 *
 * - 每次请求 `createHttp()` 建一个新的 HttpRequest，`finally` 里 `destroy()`；连接池由系统管，
 *   不复用对象是因为 HttpRequest 上的回调与请求一一对应，复用只会更容易串味。
 * - 会话经 `X-Session-Id` 头带上；服务端返回 `code 4010` 时清掉本机会话再抛 Unauthorized。
 * - 响应统一按 `HttpDataType.STRING` 取文本自己解析：ArkTS 里没有反射解码，
 *   拿 Object 回来还是要一个字段一个字段判类型，不如从文本起步，出错时还能把原文记进日志。
 * - HTTP 非 2xx 直接 `ApiError(status, 'HTTP n')`，与安卓一致——信封只在 200 的响应体里出现。
 *
 * 上传不走这里（见 Uploader，用 request.agent 的后台任务）。
 */
export class Backend {
  /** 当前账号区域，每次请求现取（dev-board#837）：定主机，也定 `X-App-Language`。 */
  private readonly region: () => AccountRegion
  private readonly session: SessionStore

  constructor(region: () => AccountRegion, session: SessionStore) {
    this.region = region
    this.session = session
  }

  async accountLogin(account: string, password: string): Promise<LoginResult> {
    const body: Record<string, string> = { 'account': account, 'password': password }
    return await this.login('/api/auth/account-login', body)
  }

  async sendLoginCode(phone: string): Promise<void> {
    const body: Record<string, string> = { 'phone': phone }
    await this.envelope('/api/auth/sms-login/send-code', body)
  }

  async verifyLoginCode(phone: string, code: string): Promise<LoginResult> {
    const body: Record<string, string> = { 'phone': phone, 'code': code }
    return await this.login('/api/auth/sms-login/verify', body)
  }

  async sendMailLoginCode(email: string): Promise<void> {
    const body: Record<string, string> = { 'email': email }
    await this.envelope('/api/auth/mail-login/send-code', body)
  }

  async verifyMailLoginCode(email: string, code: string): Promise<LoginResult> {
    const body: Record<string, string> = { 'email': email, 'code': code }
    return await this.login('/api/auth/mail-login/verify', body)
  }

  async deleteAccount(): Promise<void> {
    const body: Record<string, string> = {}
    await this.envelope('/api/auth/account/delete', body)
  }

  async logout(): Promise<void> {
    await this.session.clear()
  }

  /** 本机有没有会话。只判断「有没有」，还有效没有由第一次真实请求的 4010 发现。 */
  async hasSession(): Promise<boolean> {
    const sid: string | null = await this.session.current()
    return sid !== null
  }

  async myProjects(): Promise<RelayProject[]> {
    return decodeCatalog(await this.bare('/api/mobile/catalog'))
  }

  async subscriptionBalance(): Promise<SubscriptionBalance | null> {
    return decodeSubscriptionBalance(await this.bare('/api/mobile/billing/balance'))
  }

  async mediaUsage(): Promise<MediaUsage> {
    return decodeMediaUsage(await this.bare('/api/mobile/media/usage'))
  }

  async mediaStatus(ids: string[]): Promise<MediaStatus[]> {
    if (ids.length === 0) return []
    return decodeMediaStatuses(await this.bare('/api/mobile/media/status?clientMediaIds=' + ids.join(',')))
  }

  async backupConsent(): Promise<BackupConsent> {
    return decodeBackupConsent(await this.bare('/api/mobile/backup-consent'))
  }

  async setBackupConsent(enabled: boolean, expectedSession: string): Promise<BackupConsent> {
    if (await this.session.current() !== expectedSession) throw new Unauthorized()
    const body: Record<string, Object> = { 'enabled': enabled, 'consentVersion': ContractCapabilities.backupConsentVersion }
    const text: string = await this.execute('/api/mobile/backup-consent', http.RequestMethod.PUT, ArkJson.stringify(body), expectedSession)
    const o: Record<string, Object> | null = asRecord(ArkJson.parse(text))
    if (o === null) throw new ApiError(1, 'Invalid backup response')
    await this.check(o)
    if (await this.session.current() !== expectedSession) throw new Unauthorized()
    return decodeBackupConsent(o)
  }

  async fileRequest(path: string, body: Record<string, Object> | null = null, expectedSession: string): Promise<Record<string, Object>> {
    const text: string = await this.execute(path, body === null ? http.RequestMethod.GET : http.RequestMethod.POST,
      body === null ? null : ArkJson.stringify(body), expectedSession)
    const o: Record<string, Object> | null = asRecord(ArkJson.parse(text))
    if (o === null) throw new ApiError(1, 'Invalid file response')
    await this.check(o)
    return o
  }

  async personalRequest(path: string, method: http.RequestMethod, body: Record<string, Object> | null, expectedSession: string): Promise<Record<string, Object>> {
    const host: string = baseUrlOf(this.region())
    const text: string = await this.execute('/api/mobile/' + path, method, body === null ? null : ArkJson.stringify(body), expectedSession, 240000)
    if (await this.session.current() !== expectedSession || baseUrlOf(this.region()) !== host) throw new Unauthorized()
    const raw: Record<string, Object> | null = asRecord(ArkJson.parse(text))
    if (raw === null || typeof raw['code'] !== 'number') throw new ApiError(1, 'Invalid response')
    await this.check(raw)
    const data: Record<string, Object> | null = asRecord(raw['data'])
    if (data === null) throw new ApiError(1, 'Invalid response')
    return data
  }

  // ---- 内部 ----

  /** 裸响应（数组 / 对象）。是对象才查信封——未登录时这些接口同样回 4010 信封。 */
  private async bare(path: string): Promise<Object | null> {
    const text: string = await this.execute(path, http.RequestMethod.GET, null)
    const parsed: Object | null = ArkJson.parse(text)
    const o: Record<string, Object> | null = asRecord(parsed)
    if (o !== null) await this.check(o)
    return parsed
  }

  private async envelope(path: string, body: Record<string, string>): Promise<Record<string, Object>> {
    const text: string = await this.execute(path, http.RequestMethod.POST, ArkJson.stringify(body))
    const o: Record<string, Object> | null = asRecord(ArkJson.parse(text))
    if (o === null) throw new ApiError(1, 'response is not an envelope')
    await this.check(o)
    return o
  }

  private async login(path: string, body: Record<string, string>): Promise<LoginResult> {
    const env: Record<string, Object> = await this.envelope(path, body)
    const data: Record<string, Object> | null = asRecord(env['data'])
    if (data === null) throw new ApiError(1, 'empty data')
    const result: LoginResult = decodeLoginResult(data)
    if (result.sessionId.length === 0 || result.user.id <= 0) throw new ApiError(1, 'invalid login identity')
    await this.session.save(result.sessionId)
    return result
  }

  /** 信封判定在领域层（checkEnvelope）；这里只多做一件端上的事：4010 顺手清掉死会话。 */
  private async check(o: Record<string, Object>): Promise<void> {
    try {
      checkEnvelope(o)
    } catch (e) {
      if (e instanceof Unauthorized) await this.session.clear()
      throw e as Error
    }
  }

  private async execute(path: string, method: http.RequestMethod, body: string | null, expectedSession: string | null = null, timeout: number = READ_TIMEOUT_MS): Promise<string> {
    const sid: string | null = await this.session.current()
    if (expectedSession !== null && sid !== expectedSession) throw new Unauthorized()
    const region: AccountRegion = this.region()
    const header: Record<string, string> = { 'X-App-Language': currentAppLanguage(region) }
    if (sid !== null) header['X-Session-Id'] = sid
    const client: http.HttpRequest = http.createHttp()
    try {
      let options: http.HttpRequestOptions
      if (body === null) {
        options = {
          method: method, header: header, expectDataType: http.HttpDataType.STRING,
          connectTimeout: CONNECT_TIMEOUT_MS, readTimeout: timeout, maxRedirects: 0,
        }
      } else {
        header['Content-Type'] = 'application/json; charset=utf-8'
        options = {
          method: method, header: header, extraData: body, expectDataType: http.HttpDataType.STRING,
          connectTimeout: CONNECT_TIMEOUT_MS, readTimeout: timeout, maxRedirects: 0,
        }
      }
      const url: string = baseUrlOf(region) + path
      // 只记方法与地址（不含查询串与头）：走查时据此确认打的是哪一站
      hilog.info(DOMAIN, TAG, '%{public}s %{public}s', method, url.split('?')[0])
      const resp: http.HttpResponse = await client.request(url, options)
      const status: number = resp.responseCode
      if (status < 200 || status >= 300) throw new ApiError(status, `HTTP ${status}`)
      return typeof resp.result === 'string' ? resp.result as string : ''
    } finally {
      client.destroy()
    }
  }
}
