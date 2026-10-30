import { request } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { JSON as ArkJson } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { CaptureItem, MediaKind, MediaKindOps, RelayProject } from '../model/Capture'
import { ApiError, Unauthorized, checkEnvelope } from '../model/Envelope'
import { SessionStore } from './SessionStore'
import { Prefs } from './Prefs'
import { CaptureOrganization, UploadResult, asRecord, decodeUploadResult } from './ApiTypes'
import { AccountRegion, baseUrlOf, currentAppLanguage } from '../model/AccountRegion'

const DOMAIN: number = 0x0000
const TAG: string = 'Uploader'
/**
 * 一件的总超时。几百 MB 的现场录像在弱网下也够传完，超过这个数就不是「慢」而是卡住了
 * （系统任务被挂起、终态回调没落回本进程）。超时视为失败：本地记录落 failed 走退避重排，
 * 系统任务一并 remove 掉，幂等键保证重排后不会产生重复件。
 */
const UPLOAD_TIMEOUT_MS: number = 30 * 60 * 1000

/** ArkTS 不接受把 ApiError 直接当 Error 实参（arkts-no-structural-typing），过一道具名函数。 */
function timeoutError(): Error {
  const e: ApiError = new ApiError(1, 'upload timeout')
  return e
}

function mimeOf(k: MediaKind): string {
  if (k === MediaKind.photo) return 'image/jpeg'
  if (k === MediaKind.video) return 'video/mp4'
  return 'audio/mp4'
}

/**
 * 一件影像的上传。用 `request.agent` 的 BACKGROUND 任务：切后台后由系统继续传，
 * 这是鸿蒙兑现契约 `backgroundUpload: true` 的正道（spec H6）。
 *
 * ### 响应体怎么拿（d.ts 依据）
 *
 * `@ohos.request.d.ts`：
 * - 2276-2324 `interface Progress`，其中 2314-2323 的注释写明
 *   `readonly extras?: object` 是 "Extra information of the task, **for example, the header and
 *   body of the response from the server**"——`on('completed')` 回调收到的就是 Progress，
 *   所以响应体从 `progress.extras` 取。
 * - 2504-2685 `interface TaskInfo` 的 `extras`（2684）只写 "Extra information of the task"，
 *   没提响应体，所以它只用来在失败时取 `faults`（2668）与 `reason`（2676）。
 * - 2694-2729 `interface HttpResponse` 有 `statusCode`（2712），由 `on('response')`（3085，@since 12）
 *   送达；BACKGROUND 任务的 HTTP 4xx/5xx 未必触发 `on('failed')`，所以状态码单独记一份。
 *
 * extras 的键名 SDK 没写死，这里按 JSON 往返成 Record 后依次试 `body` / `response`，
 * 整体是字符串时直接当正文。**待设备验证**：本机无模拟器镜像，取不到真实 extras 形状；
 * 取不到正文时按「2xx 即成功」构造 UploadResult，服务端的幂等键保证重传不会产生重复件。
 *
 * ### 文件路径
 *
 * `FileSpec.path`（1620-1690）接受相对 cache 路径、`internal://cache/...`、以及
 * "Application sandbox directory. Only the base directory and its subdirectories"。
 * filesDir 落在 base 下，理论上可直传；**待设备验证**。create 失败时退化成拷到 cacheDir
 * 用 `internal://cache/<name>`，终态删掉副本。
 */
export class Uploader {
  private readonly ctx: common.Context
  /** 当前账号区域，建任务时现取（dev-board#837）；已建的系统任务 URL 与头固定，不随换区改。 */
  private readonly region: () => AccountRegion
  private readonly session: SessionStore
  private readonly prefs: Prefs

  constructor(ctx: common.Context, region: () => AccountRegion, session: SessionStore, prefs: Prefs) {
    this.ctx = ctx
    this.region = region
    this.session = session
    this.prefs = prefs
  }

  async upload(item: CaptureItem, project: RelayProject, fileName: string,
    onProgress: (p: number) => void): Promise<UploadResult> {
    const sid: string | null = await this.session.current()
    if (sid === null) throw new Unauthorized()
    const deviceId: string = await this.prefs.deviceId()
    const clientMediaId: string = item.manifest.clientMediaId
    const region: AccountRegion = this.region()
    const organizationScope: string = Prefs.organizationScope(baseUrlOf(region), sid)
    const organize: boolean = this.prefs.organizeCaptures(organizationScope)

    let copiedPath: string | null = null
    let task: request.agent.Task
    try {
      task = await request.agent.create(this.ctx,
        this.config(item.localPath, fileName, sid, deviceId, project, item, organize, region))
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sandbox path rejected, copying to cache: %{public}s', (e as Error).message)
      copiedPath = `${this.ctx.cacheDir}/upload-${clientMediaId}.${MediaKindOps.ext(item.kind)}`
      fs.copyFileSync(item.localPath, copiedPath)
      task = await request.agent.create(this.ctx,
        this.config(`internal://cache/upload-${clientMediaId}.${MediaKindOps.ext(item.kind)}`,
          fileName, sid, deviceId, project, item, organize, region))
    }

    const tid: string = task.tid
    let statusCode: number = 0
    let settled: boolean = false
    let resolveFn: (v: UploadResult) => void = (v: UploadResult): void => {}
    let rejectFn: (e: Error) => void = (e: Error): void => {}
    const done: Promise<UploadResult> = new Promise<UploadResult>((res, rej) => {
      resolveFn = res
      rejectFn = rej
    })

    task.on('response', (r: request.agent.HttpResponse): void => {
      statusCode = r.statusCode
    })
    task.on('progress', (p: request.agent.Progress): void => {
      const total: number = p.sizes.length > 0 ? p.sizes[0] : 0
      onProgress(total > 0 ? p.processed / total : 0)
    })
    const timedOut: () => void = (): void => {
      // 系统任务一并 remove：本地记录落 failed 后由退避重排，让它继续在系统里传只会重复
      this.cleanup(tid, copiedPath).then((): void => {
        rejectFn(timeoutError())
      }, (): void => {
        rejectFn(timeoutError())
      })
    }
    const timer: number = setTimeout((): void => {
      if (settled) return
      settled = true
      timedOut()
    }, UPLOAD_TIMEOUT_MS)

    task.on('completed', (p: request.agent.Progress): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      this.finish(tid, statusCode, p, clientMediaId, copiedPath).then(resolveFn, rejectFn)
    })
    task.on('failed', (): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      this.fail(tid, statusCode, copiedPath).then(rejectFn, rejectFn)
    })

    try {
      await task.start()
    } catch (e) {
      settled = true
      clearTimeout(timer)
      await this.cleanup(tid, copiedPath)
      throw e as Error
    }
    const result: UploadResult = await done
    try {
    if (fs.accessSync(item.localPath) && (organize || (result.organization !== undefined && result.organization.state !== 'disabled'))) {
      const organization: CaptureOrganization = result.organization ?? { state: 'unknown', tags: [] }
      await this.prefs.saveOrganization(organizationScope, clientMediaId, organization, async (): Promise<boolean> => {
        const currentSession: string | null = await this.session.current()
        return organizationScope === Prefs.organizationScope(baseUrlOf(this.region()), currentSession)
          && fs.accessSync(item.localPath)
      }).catch((): void => {})
    }
    } catch (e) { /* A deleted original must not recreate result metadata. */ }
    return result
  }

  /**
   * 清掉系统里残留的传输任务。进程被杀时留下的任务系统还会接着传，而本地记录已按 app_launch
   * 回拨重传——两边都在传同一件，服务端靠幂等键不会重复入库，但系统任务表会一直堆着。
   *
   * 只由 UploadQueue.recoverStale 在单飞里调用：那时候没有任何在途上传，
   * 所有系统任务都是尸体，和把 uploading 回拨 waiting 是同一个道理。
   * 单个 remove 失败不影响别的（任务可能已被系统回收），记日志即可。
   */
  async sweepStale(): Promise<void> {
    let tids: string[] = []
    try {
      // 必须显式给 Filter：`Filter.after` 不传时默认「调用时刻减 24 小时」
      // （`@ohos.request.d.ts:2455` 的注释），只扫得到最近一天的残留，
      // 而进程被杀两天后才回来的那条旧任务正是要清的。0 是 Unix 纪元，覆盖全部历史；
      // `before` 不传默认就是调用时刻，这里一并写明白。
      const filter: request.agent.Filter = {
        after: 0,
        before: Date.now(),
        action: request.agent.Action.UPLOAD,
      }
      tids = await request.agent.search(filter)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'search failed: %{public}s', (e as Error).message)
      return
    }
    for (const tid of tids) {
      try {
        await request.agent.remove(tid)
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'stale remove failed: %{public}s', (e as Error).message)
      }
    }
  }

  // ---- 内部 ----

  private config(path: string, fileName: string, sid: string, deviceId: string,
    project: RelayProject, item: CaptureItem, organize: boolean, region: AccountRegion): request.agent.Config {
    const file: request.agent.FileSpec = {
      path: path, filename: fileName, mimeType: mimeOf(item.kind),
    }
    const data: request.agent.FormItem[] = [
      { name: 'deviceId', value: deviceId },
      { name: 'projectKey', value: project.key },
      { name: 'clientMediaId', value: item.manifest.clientMediaId },
      { name: 'fileName', value: fileName },
      { name: 'mediaType', value: MediaKindOps.mediaType(item.kind) },
      { name: 'capturedAt', value: item.manifest.capturedAt },
      { name: 'organize', value: organize ? 'true' : 'false' },
      { name: 'file', value: file },
    ]
    const headers: Record<string, string> = { 'X-Session-Id': sid, 'X-App-Language': currentAppLanguage(region) }
    const conf: request.agent.Config = {
      action: request.agent.Action.UPLOAD,
      url: `${baseUrlOf(region)}/api/mobile/media`,
      method: 'POST',
      mode: request.agent.Mode.BACKGROUND,
      headers: headers,
      data: data,
      gauge: true,
      retry: false,
      overwrite: true,
    }
    return conf
  }

  private async finish(tid: string, statusCode: number, p: request.agent.Progress,
    clientMediaId: string, copiedPath: string | null): Promise<UploadResult> {
    await this.cleanup(tid, copiedPath)
    if (statusCode !== 0 && (statusCode < 200 || statusCode >= 300)) {
      throw new ApiError(statusCode, `HTTP ${statusCode}`)
    }
    const body: Record<string, Object> | null = bodyOf(p.extras)
    if (body === null) {
      // 拿不到正文：2xx 即成功。服务端按 clientMediaId 幂等，重传不会产生重复件。
      const fallback: UploadResult = { code: 0, id: 0, clientMediaId: clientMediaId, delivered: false }
      return fallback
    }
    // 信封判定与 Backend 同一套；4010 顺手清掉死会话（安卓的 checkEnvelopeCode 也在这一步清）
    try {
      checkEnvelope(body)
    } catch (e) {
      if (e instanceof Unauthorized) await this.session.clear()
      throw e as Error
    }
    return decodeUploadResult(body, clientMediaId)
  }

  /** 失败终态。faults / reason 是系统给的诊断串，原样落进 lastError（英文，非界面文案）。 */
  private async fail(tid: string, statusCode: number, copiedPath: string | null): Promise<Error> {
    let reason: string = 'upload failed'
    try {
      const info: request.agent.TaskInfo = await request.agent.show(tid)
      reason = info.reason.length > 0 ? info.reason : `fault ${info.faults}`
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'show(tid) failed: %{public}s', (e as Error).message)
    }
    await this.cleanup(tid, copiedPath)
    const code: number = statusCode === 0 ? 1 : statusCode
    return new ApiError(code, reason)
  }

  private async cleanup(tid: string, copiedPath: string | null): Promise<void> {
    try {
      await request.agent.remove(tid)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove(tid) failed: %{public}s', (e as Error).message)
    }
    if (copiedPath === null) return
    try {
      fs.unlinkSync(copiedPath)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cache copy unlink failed: %{public}s', (e as Error).message)
    }
  }
}

/** extras 的形状 SDK 没写死：整体是串就当正文，是对象就依次试 body / response 两个键。 */
function bodyOf(extras: Object | undefined): Record<string, Object> | null {
  if (extras === undefined || extras === null) return null
  try {
    if (typeof extras === 'string') return asRecord(ArkJson.parse(extras as string))
    const holder: Record<string, Object> | null = asRecord(ArkJson.parse(ArkJson.stringify(extras)))
    if (holder === null) return null
    for (const key of ['body', 'response']) {
      const v: Object | undefined = holder[key]
      if (typeof v === 'string') return asRecord(ArkJson.parse(v as string))
      const nested: Record<string, Object> | null = asRecord(v)
      if (nested !== null) return nested
    }
    return holder
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'response body unreadable: %{public}s', (e as Error).message)
    return null
  }
}
