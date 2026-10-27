import { common } from '@kit.AbilityKit'
import { PersonalConversationStore } from './PersonalConversationStore'
import { Backend } from './Backend'
import { EvidenceStore } from './EvidenceStore'
import { Prefs } from './Prefs'
import { SessionStore } from './SessionStore'
import { UploadQueue } from './UploadQueue'
import { Uploader } from './Uploader'
import { DeviceFacts, deviceFacts } from './DeviceFacts'
import { ContractCapabilities } from 'contract'
import { AccountRegion, DEFAULT_REGION, RegionSwitchSink, baseUrlOf, localeOf, switchRegion } from '../model/AccountRegion'
import { L10n, LOCALE_STORAGE_KEY, LOCALE_SYSTEM } from '../design/L10n'

/** 换区时真实的三处存储：内存区域 + 界面语言、偏好里的当前项目、偏好里的区域。 */
class LocatorRegionSink implements RegionSwitchSink {
  applyRegion(r: AccountRegion): void {
    ServiceLocator.applyRegion(r)
  }

  async clearSelectedProject(): Promise<void> {
    await ServiceLocator.prefs.setSelectedProject(null)
  }

  async persistRegion(r: AccountRegion): Promise<void> {
    await ServiceLocator.prefs.setAccountRegion(r)
  }
}

function need<T>(v: T | null): T {
  if (v === null) throw new Error('ServiceLocator.init(ctx) has not run')
  return v
}

/**
 * 进程级服务装配点，`EntryAbility.onCreate` 里 `init(ctx)` 一次。
 * ArkTS 没有 DI，页面与后台任务都从这里取同一批实例——EvidenceStore 的串行锁与
 * UploadQueue 的单飞标志都是实例状态，装配两遍就等于两条互不知情的队列。
 *
 * 字段写成「私有可空 + 只读取值器」而不是 `static x!: T`：ArkTS 不接受静态字段上的
 * 明确赋值断言（10505001），而未装配就取用是编程错误，宁可当场抛也不要拿到 null 再往下走。
 */
export class ServiceLocator {
  private static ctxRef: common.Context | null = null
  private static sessionRef: SessionStore | null = null
  private static prefsRef: Prefs | null = null
  private static factsRef: DeviceFacts | null = null
  private static backendRef: Backend | null = null
  private static storeRef: EvidenceStore | null = null
  private static uploaderRef: Uploader | null = null
  private static queueRef: UploadQueue | null = null
  /**
   * 当前账号区域（dev-board#837）。装配时从偏好同步读出，之后只由登录页的切换改写。
   * Backend 与 Uploader 拿的是取值函数而不是定值，每次请求现读——换区不必重装配。
   * 界面语言跟着区域走（大陆 zh-Hans、海外 en），由 applyRegion 一并设定。
   */
  private static regionRef: AccountRegion = DEFAULT_REGION

  static get ctx(): common.Context {
    return need<common.Context>(ServiceLocator.ctxRef)
  }

  static get session(): SessionStore {
    return need<SessionStore>(ServiceLocator.sessionRef)
  }

  static get prefs(): Prefs {
    return need<Prefs>(ServiceLocator.prefsRef)
  }

  static get facts(): DeviceFacts {
    return need<DeviceFacts>(ServiceLocator.factsRef)
  }

  static get backend(): Backend {
    return need<Backend>(ServiceLocator.backendRef)
  }

  static get store(): EvidenceStore {
    return need<EvidenceStore>(ServiceLocator.storeRef)
  }

  static get uploader(): Uploader {
    return need<Uploader>(ServiceLocator.uploaderRef)
  }

  static get queue(): UploadQueue {
    return need<UploadQueue>(ServiceLocator.queueRef)
  }

  static get region(): AccountRegion {
    return ServiceLocator.regionRef
  }

  /** 当前区域的服务端根地址。所有接口都从这里取主机。 */
  static baseUrl(): string {
    return baseUrlOf(ServiceLocator.regionRef)
  }

  /**
   * 换区。只该在未登录的登录页调用——登录后区域固定，换区要先退出登录。
   * 先改内存再落盘：紧接着的发码请求必须已经打新主机，落盘失败也不该让这一次打错站。
   * 同时清掉本机记着的当前项目（见 switchRegion）。
   */
  static async setRegion(r: AccountRegion): Promise<void> {
    await PersonalConversationStore.clear()
    await switchRegion(ServiceLocator.regionRef, r, new LocatorRegionSink())
  }

  /**
   * 区域与界面语言一起换。若用户未显式指定语言（LOCALE_SYSTEM），则跟随区域默认语言。
   */
  static applyRegion(r: AccountRegion): void {
    ServiceLocator.regionRef = r
    const fallback: string = localeOf(r)
    const locale: string = L10n.preference === LOCALE_SYSTEM ? fallback : L10n.normalize(L10n.preference, fallback)
    L10n.locale = locale
    AppStorage.setOrCreate<string>(LOCALE_STORAGE_KEY, locale)
  }

  static applyLocale(pref: string): void {
    const fallback: string = localeOf(ServiceLocator.regionRef)
    const validPref: string = (pref.length === 0 || pref === LOCALE_SYSTEM) ? LOCALE_SYSTEM : L10n.normalize(pref, fallback)
    L10n.preference = validPref
    const locale: string = validPref === LOCALE_SYSTEM ? fallback : validPref
    L10n.locale = locale
    AppStorage.setOrCreate<string>(LOCALE_STORAGE_KEY, locale)
  }

  static async setLocalePreference(pref: string): Promise<void> {
    ServiceLocator.applyLocale(pref)
    await ServiceLocator.prefs.setAppLocale(L10n.preference)
  }

  static init(ctx: common.Context): void {
    if (ServiceLocator.ctxRef !== null) return
    const session: SessionStore = new SessionStore()
    const prefs: Prefs = new Prefs(ctx)
    L10n.preference = prefs.appLocaleSync()
    // 本端不支持国际账号时（契约 intlAccount=false）不认偏好里的值，一律大陆
    ServiceLocator.applyRegion(ContractCapabilities.intlAccount ? prefs.accountRegionSync() : DEFAULT_REGION)
    const facts: DeviceFacts = deviceFacts(ctx)
    const region: () => AccountRegion = (): AccountRegion => ServiceLocator.regionRef
    const backend: Backend = new Backend(region, session)
    const store: EvidenceStore = new EvidenceStore(`${ctx.filesDir}/FieldEvidence`, facts)
    const uploader: Uploader = new Uploader(ctx, region, session, prefs)
    ServiceLocator.sessionRef = session
    ServiceLocator.prefsRef = prefs
    ServiceLocator.factsRef = facts
    ServiceLocator.backendRef = backend
    ServiceLocator.storeRef = store
    ServiceLocator.uploaderRef = uploader
    ServiceLocator.queueRef = new UploadQueue(store, uploader, backend)
    ServiceLocator.ctxRef = ctx
  }

  static isReady(): boolean {
    return ServiceLocator.ctxRef !== null
  }
}
