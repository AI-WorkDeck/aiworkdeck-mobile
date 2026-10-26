import { L10n } from '../design/L10n'

/**
 * 账号区域（dev-board#837）。大陆站与国际站是两套账号体系、两个主机，同一个人在两边是两个号。
 *
 * 区域只在未登录的登录页切换，登录后固定；换区 = 退出登录后在登录页重选。
 * 存量已登录用户本机没有这个偏好 → 走缺省 cn，老用户仍是大陆站，零迁移。
 */
export enum AccountRegion { cn = 'cn', intl = 'intl' }

/** 登录方式。国际站没有短信通道，只剩邮箱。 */
export enum LoginMethod { phone = 'phone', email = 'email' }

export const DEFAULT_REGION: AccountRegion = AccountRegion.cn

/** 偏好里存的原值 → 区域。没存过、存了别的（手改、将来的新值）一律回缺省，不让一个坏值把人锁在登录页外。 */
export function regionFromStored(raw: string | null): AccountRegion {
  if (raw === AccountRegion.intl) return AccountRegion.intl
  if (raw === AccountRegion.cn) return AccountRegion.cn
  return DEFAULT_REGION
}

/** 区域 → 服务端根地址。所有接口（登录、项目、上传、用量、注销）都打这个主机。 */
export function baseUrlOf(region: AccountRegion): string {
  return region === AccountRegion.intl ? 'https://addin.workdeck.ai' : 'https://addin.aiworkdeck.com'
}

/** 该区域可用的登录方式，按界面上的排列顺序。 */
export function loginMethodsOf(region: AccountRegion): LoginMethod[] {
  return region === AccountRegion.intl ? [LoginMethod.email] : [LoginMethod.phone, LoginMethod.email]
}

/** 切到某区域后默认落在哪种方式：第一项。大陆仍是手机号（现有行为），国际只有邮箱。 */
export function defaultLoginMethodOf(region: AccountRegion): LoginMethod {
  return loginMethodsOf(region)[0]
}

/** 国际站计费未开通（dev-board#664）：余额与充值入口只在大陆区出现。 */
export function billingAvailableIn(region: AccountRegion): boolean {
  return region === AccountRegion.cn
}

/** 区域名称的文案键（`login.region.cn` / `login.region.intl`）。 */
export function regionLabelKey(region: AccountRegion): string {
  return region === AccountRegion.intl ? 'login.region.intl' : 'login.region.cn'
}

/** 区域 → 界面语言（L10n 的 locale 值）。海外版默认英文界面，大陆版中文。 */
export function localeOf(region: AccountRegion): string {
  return region === AccountRegion.intl ? 'en' : 'zh-Hans'
}

/** 区域 → 请求头 `X-App-Language` 的默认语言值。 */
export function appLanguageOf(region: AccountRegion): string {
  return region === AccountRegion.intl ? 'en-US' : 'zh-CN'
}

/** 当前请求头 `X-App-Language` 的实际语言值（优先使用当前活动界面语言的 wireCode）。 */
export function currentAppLanguage(region: AccountRegion): string {
  if (L10n.locale.length > 0) {
    return L10n.wireCode(L10n.locale)
  }
  return appLanguageOf(region)
}

/**
 * 换区要动的三处存储。拆成接口是为了让「换区」这一步在 Node 侧可测（ServiceLocator 里是真实现）。
 */
export interface RegionSwitchSink {
  /** 内存里的区域与界面语言：紧接着的发码请求必须已经打新主机。 */
  applyRegion(r: AccountRegion): void
  /** 本机记着的「当前项目」：它属于上一个区域的账号。 */
  clearSelectedProject(): Promise<void>
  persistRegion(r: AccountRegion): Promise<void>
}

/**
 * 换区（只在未登录的登录页发生）。除了区域本身，还要清掉本机记着的当前项目——
 * 那是另一个站、另一个账号的项目，登录新区后若直接落到它，上传会带着别人的 projectKey 打到新站。
 * 同区重复点不做任何事，返回 false。
 */
export async function switchRegion(current: AccountRegion, next: AccountRegion,
  sink: RegionSwitchSink): Promise<boolean> {
  if (current === next) return false
  sink.applyRegion(next)
  await sink.clearSelectedProject()
  await sink.persistRegion(next)
  return true
}

/** Fixed website flow; the legacy flag carries no email address or credential. */
export function accountFlowUrl(region: AccountRegion, method: LoginMethod, flow: string): string {
  const host: string = region === AccountRegion.intl ? 'https://workdeck.ai/en/account' : 'https://aiworkdeck.com/zh/account'
  const selectedFlow: string = flow === 'reset' ? 'reset' : 'register'
  const migration: string = region === AccountRegion.cn && method === LoginMethod.email ? '&legacyEmail=1' : ''
  return host + '?flow=' + selectedFlow + migration
}
