import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { JSON as ArkJson, util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { RelayProject } from '../model/Capture'
import { AccountRegion, regionFromStored } from '../model/AccountRegion'
import { asRecord, decodeRelayProject } from './ApiTypes'

const DOMAIN: number = 0x0000
const TAG: string = 'Prefs'
const FILE: string = 'prefs'
const KEY_SAVE_TO_ALBUM: string = 'saveToAlbum'
const KEY_SELECTED_PROJECT: string = 'selectedProject'
const KEY_DEVICE_ID: string = 'deviceId'
const KEY_LIBRARY_VIEW: string = 'libraryView'
const KEY_ACCOUNT_REGION: string = 'accountRegion'
const KEY_APP_LOCALE: string = 'appLocale'

export const LIBRARY_VIEW_GRID: string = 'grid'
export const LIBRARY_VIEW_LIST: string = 'list'

/**
 * 本机偏好：不加密的设置项（存相册开关、当前项目、图集的看法、本机身份）。
 *
 * 存相册**默认关**（spec H8）：没有 WRITE_IMAGEVIDEO 受限权限时每件都要弹系统确认，
 * 默认开会把取证节奏打断，与安卓的默认开不同。
 */
export class Prefs {
  private readonly ctx: common.Context
  private store: preferences.Preferences | null = null

  constructor(ctx: common.Context) {
    this.ctx = ctx
  }

  private async open(): Promise<preferences.Preferences> {
    const cached: preferences.Preferences | null = this.store
    if (cached !== null) return cached
    const options: preferences.Options = { name: FILE }
    const opened: preferences.Preferences = await preferences.getPreferences(this.ctx, options)
    this.store = opened
    return opened
  }

  /**
   * 同步打开。只给「装配时就要知道的值」用（账号区域：Backend 与 Uploader 从第一次请求起就得打对主机）。
   * 与异步 open() 共用同一个缓存实例，系统按文件名也只给一个 Preferences 对象，两条路写读的是同一份。
   */
  private openSync(): preferences.Preferences {
    const cached: preferences.Preferences | null = this.store
    if (cached !== null) return cached
    const options: preferences.Options = { name: FILE }
    const opened: preferences.Preferences = preferences.getPreferencesSync(this.ctx, options)
    this.store = opened
    return opened
  }

  private async putString(key: string, value: string): Promise<void> {
    const p: preferences.Preferences = await this.open()
    await p.put(key, value)
    await p.flush()
  }

  private async readString(key: string): Promise<string | null> {
    const p: preferences.Preferences = await this.open()
    const v: preferences.ValueType = await p.get(key, '')
    if (typeof v !== 'string') return null
    const s: string = v as string
    return s.length === 0 ? null : s
  }

  async saveToAlbum(): Promise<boolean> {
    const p: preferences.Preferences = await this.open()
    const v: preferences.ValueType = await p.get(KEY_SAVE_TO_ALBUM, false)
    return typeof v === 'boolean' ? v as boolean : false
  }

  async setSaveToAlbum(v: boolean): Promise<void> {
    const p: preferences.Preferences = await this.open()
    await p.put(KEY_SAVE_TO_ALBUM, v)
    await p.flush()
  }

  /**
   * 本机身份。服务端靠它认「哪台手机」，换了值已传的件与后传的件会被当成两台设备——
   * 所以只在第一次读取时生成，之后一直沿用，卸载重装才换（与安卓 Prefs.deviceId 一致）。
   */
  async deviceId(): Promise<string> {
    const existing: string | null = await this.readString(KEY_DEVICE_ID)
    if (existing !== null) return existing
    const fresh: string = util.generateRandomUUID(false).toLowerCase()
    await this.putString(KEY_DEVICE_ID, fresh)
    return fresh
  }

  async selectedProject(): Promise<RelayProject | null> {
    const text: string | null = await this.readString(KEY_SELECTED_PROJECT)
    if (text === null) return null
    try {
      const o: Record<string, Object> | null = asRecord(ArkJson.parse(text))
      return o === null ? null : decodeRelayProject(o)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'selectedProject unreadable: %{public}s', (e as Error).message)
      return null
    }
  }

  async setSelectedProject(p: RelayProject | null): Promise<void> {
    const store: preferences.Preferences = await this.open()
    if (p === null) {
      await store.delete(KEY_SELECTED_PROJECT)
    } else {
      await store.put(KEY_SELECTED_PROJECT, ArkJson.stringify(p))
    }
    await store.flush()
  }

  /** 图集的看法（grid / list）。进程被杀回来也该是用户上次选的那种，所以落盘而不是留内存。 */
  async libraryView(): Promise<string> {
    const v: string | null = await this.readString(KEY_LIBRARY_VIEW)
    return v === LIBRARY_VIEW_LIST ? LIBRARY_VIEW_LIST : LIBRARY_VIEW_GRID
  }

  async setLibraryView(v: string): Promise<void> {
    await this.putString(KEY_LIBRARY_VIEW, v === LIBRARY_VIEW_LIST ? LIBRARY_VIEW_LIST : LIBRARY_VIEW_GRID)
  }

  /** 账号区域（dev-board#837）。没存过 → 缺省 cn：存量已登录用户本机没有这个键，照旧打大陆站。 */
  accountRegionSync(): AccountRegion {
    try {
      const v: preferences.ValueType = this.openSync().getSync(KEY_ACCOUNT_REGION, '')
      return regionFromStored(typeof v === 'string' ? v as string : null)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'accountRegion unreadable: %{public}s', (e as Error).message)
      return regionFromStored(null)
    }
  }

  async setAccountRegion(r: AccountRegion): Promise<void> {
    await this.putString(KEY_ACCOUNT_REGION, r)
  }

  appLocaleSync(): string {
    try {
      const v: preferences.ValueType = this.openSync().getSync(KEY_APP_LOCALE, 'system')
      if (typeof v === 'string' && (v as string).length > 0) {
        return v as string
      }
      return 'system'
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'appLocale unreadable: %{public}s', (e as Error).message)
      return 'system'
    }
  }

  async setAppLocale(v: string): Promise<void> {
    const store: preferences.Preferences = await this.open()
    if (v === 'system' || v.length === 0) {
      await store.delete(KEY_APP_LOCALE)
      await store.flush()
    } else {
      await this.putString(KEY_APP_LOCALE, v)
    }
  }
}
