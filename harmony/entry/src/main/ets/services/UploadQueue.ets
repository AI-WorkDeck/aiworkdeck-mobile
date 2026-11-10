import { cloudGeneration } from './CloudEpoch'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { CaptureItem } from '../model/Capture'
import { RelayProject } from '../model/Capture'
import { StatusMerge, TransferEvent, TransferState, TransferStateOps } from '../model/TransferState'
import { Backoff } from '../model/Backoff'
import { uploadFileName } from '../model/UploadNaming'
import { Unauthorized } from '../model/Envelope'
import { EvidenceStore } from './EvidenceStore'
import { Uploader } from './Uploader'
import { Backend } from './Backend'
import { MediaStatus } from './ApiTypes'

const DOMAIN: number = 0x0000
const TAG: string = 'UploadQueue'
const STATUS_BATCH: number = 50

/** kick() 的结果：单飞占用中 / 处理完但还有可处理的 waiting 件 / 处理完且暂无更多可传件。 */
export enum KickResult {
  done = 'done',
  hasMoreWaiting = 'hasMoreWaiting',
  alreadyRunning = 'alreadyRunning',
}

function messageOf(e: Object): string {
  if (e instanceof Error) {
    const err: Error = e as Error
    return err.message.length > 0 ? err.message : err.name
  }
  return `${e}`
}

/**
 * 上传队列。镜像安卓 UploadQueue.kt / iOS UploadQueue.swift：串行、单飞、失败落盘不吞、
 * 退避不硬重试。区别只在于 ArkTS 无协程无 Mutex，单飞用一个布尔标志（本类的方法都在
 * UI 线程的事件循环上跑，读改标志之间没有真并发）。
 *
 * 状态推进全部经 EvidenceStore 落盘——进程被杀、App 切走再回来，队列能从磁盘恢复，
 * 不依赖内存里的任何东西（除了退避计时与 attempts 计数，这两样 iOS / 安卓同样不落盘）。
 */
export class UploadQueue {
  private readonly store: EvidenceStore
  private readonly uploader: Uploader
  private readonly backend: Backend
  private running: boolean = false
  /** 失败次数计数，纯内存、不落盘（lastError 只留最近一条原因，推不出次数）。 */
  private readonly attempts: Map<string, number> = new Map<string, number>()
  private readonly backoff: Backoff = new Backoff()
  /** 队列里最近一次遇到 4010：AppModel 据此触发登出，本类不碰界面、不弹提示。 */
  private unauthorized: boolean = false

  progress: Map<string, number> = new Map<string, number>()
  onChange: (() => void) | null = null
  nextAutoKickAt: number = 0

  constructor(store: EvidenceStore, uploader: Uploader, backend: Backend) {
    this.store = store
    this.uploader = uploader
    this.backend = backend
  }

  /**
   * 取走并清掉「队列撞过 4010」的标记。AppModel 每轮心跳消费一次——不清掉的话，
   * 重新登录之后还会被上一次的旧标记再踢出去一次。
   */
  consumeUnauthorized(): boolean {
    const hit: boolean = this.unauthorized
    this.unauthorized = false
    return hit
  }

  /** 启动一轮。已经在跑就直接返回 alreadyRunning，不排队叠加。 */
  async kick(): Promise<KickResult> {
    if (this.running) return KickResult.alreadyRunning
    this.running = true
    try {
      await this.recoverStale()
      await this.releaseScratchWithoutStorage()
      while (true) {
        const generation: number = cloudGeneration()
        const item: CaptureItem | null = await this.nextPending()
        if (item === null) break
        const ok: boolean = await this.uploadOne(item, generation)
        if (!ok) break
      }
      return (await this.hasActionableWaiting()) ? KickResult.hasMoreWaiting : KickResult.done
    } finally {
      this.running = false
    }
  }

  /** 周期性自愈：滞留/待传直接续跑；失败按退避到期才自动重排，不到期就什么也不做。 */
  async autoKick(): Promise<void> {
    if (this.running) return
    const items: CaptureItem[] = await this.store.loadAll()
    const hasFailed: boolean = items.some((i: CaptureItem): boolean => i.state === TransferState.failed)
    const hasWork: boolean = items.some((i: CaptureItem): boolean =>
      i.state === TransferState.waiting || i.state === TransferState.uploading)
    if (hasFailed && Date.now() >= this.nextAutoKickAt) {
      await this.autoRetryFailed()
      return
    }
    if (hasWork) await this.kick()
  }

  /** 把失败的重新排回待传。用户手动点「重试」时调用，不看退避、不看次数。 */
  async pauseCloudUploads(): Promise<void> {
    const items: CaptureItem[] = await this.store.loadAll()
    for (const item of items) if (item.state === TransferState.waiting || item.state === TransferState.uploading || item.state === TransferState.failed) {
      await this.store.updateState(item.id, TransferState.failed, 0, null, true)
    }
    this.emit()
  }

  async retryFailed(): Promise<void> {
    const items: CaptureItem[] = await this.store.loadAll()
    const failed: CaptureItem[] = items.filter((i: CaptureItem): boolean => i.state === TransferState.failed)
    for (const f of failed) await this.store.updateState(f.id, TransferState.waiting, 0, null, false)
    if (failed.length > 0) this.emit()
    await this.kick()
  }

  /**
   * 对停在中转区的影像查投递回执。查询失败静默返回——回执只是状态汇报，不该产生任何打扰。
   * 返回未投递件的中转区到期时刻（键 clientMediaId 小写），队列页拿去做到期提醒。
   */
  async checkDelivered(): Promise<Map<string, string>> {
    const expiry: Map<string, string> = new Map<string, string>()
    const items: CaptureItem[] = await this.store.loadAll()
    const uploaded: CaptureItem[] = items.filter((i: CaptureItem): boolean => i.state === TransferState.uploaded)
    if (uploaded.length === 0) return expiry
    let changed: boolean = false
    for (let start: number = 0; start < uploaded.length; start += STATUS_BATCH) {
      const batch: CaptureItem[] = uploaded.slice(start, start + STATUS_BATCH)
      const ids: string[] = batch.map((i: CaptureItem): string => i.manifest.clientMediaId)
      let statuses: MediaStatus[]
      try {
        statuses = await this.backend.mediaStatus(ids)
      } catch (e) {
        hilog.info(DOMAIN, TAG, 'mediaStatus skipped: %{public}s', messageOf(e))
        continue
      }
      const byId: Map<string, MediaStatus> = new Map<string, MediaStatus>()
      for (const s of statuses) byId.set(s.clientMediaId.toLowerCase(), s)
      for (const item of batch) {
        const key: string = item.manifest.clientMediaId.toLowerCase()
        const st: MediaStatus | undefined = byId.get(key)
        if (st === undefined) continue
        const merged: StatusMerge = TransferStateOps.applyingStatus(
          item.state, st.delivered, st.waitingSeconds, st.expiresAt === undefined ? null : st.expiresAt)
        if (merged.state !== item.state) {
          await this.store.updateState(item.id, merged.state, 1, null)
          changed = true
        }
        if (merged.expiresAt !== null) expiry.set(key, merged.expiresAt)
      }
    }
    if (changed) this.emit()
    return expiry
  }

  // ---- 内部 ----

  /**
   * 滞留的「传输中」= 上一次进程死在上传半路。串行队列走到这里没有任何在途上传，
   * 所以此刻所有 uploading 都是尸体——按契约的 app_launch 回拨重传，
   * 幂等键（clientMediaId）保证服务端不产生重复件。
   */
  private async recoverStale(): Promise<void> {
    // 系统任务表里的残留同理：单飞走到这里没有在途上传，留着的都是上次进程的尸体
    await this.uploader.sweepStale()
    const items: CaptureItem[] = await this.store.loadAll()
    const stale: CaptureItem[] = items.filter((i: CaptureItem): boolean => i.state === TransferState.uploading)
    for (const s of stale) {
      const attempts: number = this.attemptsOf(s.id)
      await this.store.updateState(s.id, TransferStateOps.recovered(s.state, attempts), 0, null)
    }
    if (stale.length > 0) this.emit()
  }

  /**
   * 临时项目 is cloud-only: without persistent cloud storage the server refuses it, so those captures
   * go back to the phone instead of failing. Asked only when such an item is pending (incl. failed).
   */
  private async releaseScratchWithoutStorage(): Promise<void> {
    const items: CaptureItem[] = await this.store.loadAll()
    const pending: boolean = items.some((i: CaptureItem): boolean =>
      i.project !== null && (i.project.isDefault === true || i.project.projectType === 'SCRATCH') &&
      (i.state === TransferState.waiting || i.state === TransferState.failed))
    if (!pending || await this.backend.persistentCloudWritable()) return
    if (await this.store.unassignScratch() > 0) this.emit()
  }

  /**
   * 目标项目按件走；没记项目的件跳过（等旧记录被用户手动归类）。
   * 先传最早拍的：loadAll 按拍摄时间降序，取最后一个即最早。
   */
  private async nextPending(): Promise<CaptureItem | null> {
    const items: CaptureItem[] = await this.store.loadAll()
    const pending: CaptureItem[] = items.filter((i: CaptureItem): boolean =>
      !i.cloudResumeRequired && i.state === TransferState.waiting && i.project !== null)
    return pending.length === 0 ? null : pending[pending.length - 1]
  }

  private async hasActionableWaiting(): Promise<boolean> {
    const items: CaptureItem[] = await this.store.loadAll()
    return items.some((i: CaptureItem): boolean =>
      !i.cloudResumeRequired && i.state === TransferState.waiting && i.project !== null)
  }

  /** 一件的上传。成功 true；失败/未授权 false——调用方据此 break，弱网下不把后面几条也挤掉。 */
  private async uploadOne(item: CaptureItem, generation: number): Promise<boolean> {
    const project: RelayProject | null = item.project
    if (project === null) return false
    await this.store.updateState(item.id, TransferState.uploading, 0, null)
    this.progress.set(item.id, 0)
    this.emit()
    try {
      const fileName: string = uploadFileName(item.kind, item.capturedAtMs(), item.id)
      await this.uploader.upload(item, project, fileName, (p: number): void => {
        this.progress.set(item.id, p)
        this.emit()
      }, generation)
      // 进了中转区 ≠ 到了电脑：真正的 arrived 由 checkDelivered 按回执改
      await this.store.updateState(item.id, TransferState.uploaded, 1, null)
      this.attempts.delete(item.id)
      this.backoff.reset()
      this.progress.delete(item.id)
      this.emit()
      return true
    } catch (e) {
      if (e instanceof Unauthorized) {
        this.unauthorized = true
        await this.recordFailure(item.id, messageOf(e), false)
      } else {
        await this.recordFailure(item.id, messageOf(e), true)
      }
      return false
    }
  }

  /** 原因照实落盘——队列页要显示「为什么失败」，光一个红点用户没法自救。 */
  private async recordFailure(id: string, message: string, backoff: boolean): Promise<void> {
    this.attempts.set(id, this.attemptsOf(id) + 1)
    await this.store.updateState(id, TransferState.failed, 0, message)
    this.progress.delete(id)
    if (backoff) {
      this.backoff.onFailure(Date.now())
      this.nextAutoKickAt = this.backoff.nextAt
    }
    this.emit()
  }

  /**
   * 自动重排：走契约的 retry_auto 事件与 guard（attempts <= maxAutoRetries），
   * 超过次数的件留在 failed，等用户手动 retryFailed()。
   */
  private async autoRetryFailed(): Promise<void> {
    const items: CaptureItem[] = await this.store.loadAll()
    const failed: CaptureItem[] = items.filter((i: CaptureItem): boolean => !i.cloudResumeRequired && i.state === TransferState.failed)
    let any: boolean = false
    for (const f of failed) {
      const next: TransferState | null = TransferStateOps.next(f.state, TransferEvent.retryAuto, this.attemptsOf(f.id))
      if (next === TransferState.waiting) {
        await this.store.updateState(f.id, TransferState.waiting, 0, null)
        any = true
      }
    }
    if (any) this.emit()
    await this.kick()
  }

  private attemptsOf(id: string): number {
    const n: number | undefined = this.attempts.get(id)
    return n === undefined ? 0 : n
  }

  private emit(): void {
    const cb: (() => void) | null = this.onChange
    if (cb !== null) cb()
  }
}
