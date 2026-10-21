import { abilityAccessCtrl, bundleManager, PermissionRequestResult, Permissions, Want, wantAgent, WantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { media } from '@kit.MediaKit'
import { JSON as ArkJson, util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { CaptureItem, MediaKind, RelayProject } from '../model/Capture'
import { tr } from '../design/L10n'
import { Loc } from '../model/Loc'
import { RecordingState } from './RecordingState'
import { PcmRecorder } from './PcmRecorder'
import { RecordingReminder } from './RecordingReminder'
import { ScreenshotMode } from '../ScreenshotMode'
import { asRecord, getNumber } from './ApiTypes'
import { ServiceLocator } from './ServiceLocator'

const DOMAIN: number = 0x0000
const TAG: string = 'RecorderService'

const MIC: Permissions = 'ohos.permission.MICROPHONE'

/**
 * 录音（纯音频）。AudioCapturer + AAC/M4A + AUDIO_RECORDING 长时任务 + 中断后保存，对位
 * 安卓 `RecordingService.kt` 的前台服务，见 `docs/specs/2026-09-03-background-recording-design.md`。
 *
 * 进程级单例：录音要跨过取景页的生死（切后台、锁屏都继续录，页面可能已经销毁重建），
 * 界面只读 `state`、只调 `start/stop`。
 *
 * 真正的 paused/stopped/error 事件停止并保存已录部分；普通系统提示未中断录音时保持继续。
 * 回前台不自动续录，避免把中断后的声音误报为已录入。
 */
export class RecorderService {
  static readonly shared: RecorderService = new RecorderService()

  readonly state: RecordingState = new RecordingState()
  /** 落库完成后回调一件。`AppModel` 收到后重读库。 */
  onStored: ((item: CaptureItem) => void) | null = null

  private recorder: PcmRecorder | null = null
  private file: fs.File | null = null
  private path: string = ''
  /** 开录**时**的项目与位置快照：录到一半换项目不该改写这一件的归属。 */
  private project: RelayProject | null = null
  private loc: Loc | null = null
  private bgRunning: boolean = false
  private busy: boolean = false
  private stopRequested: boolean = false
  private interruptedDuringStart: boolean = false
  private encodingInterrupted: boolean = false

  // MARK: - 开录

  /**
   * 开录。任何一步失败都把已经做成的部分退回去（长时任务、录音机、文件描述符、空文件），
   * 返回 false 让界面照常留在待机态——半开的录音机比不录更糟。
   */
  async start(project: RelayProject | null, loc: Loc | null): Promise<boolean> {
    if (this.busy || this.state.isRecording) return false
    this.busy = true
    this.interruptedDuringStart = false
    this.encodingInterrupted = false
    this.stopRequested = false
    try {
      const started: boolean = await this.startInner(project, loc)
      if (!started) this.state.setMessage(tr('rec.startFailed'))
      return started
    } finally {
      await this.finishOperation()
    }
  }

  private async startInner(project: RelayProject | null, loc: Loc | null): Promise<boolean> {
    if (!await this.grantMic()) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'start aborted: microphone permission denied')
      return false
    }
    const reminderAvailable: boolean = await RecordingReminder.prepare()
    // 长时任务先申请再开录音机：系统在长时任务批下来之前就把应用挂起的话，录音机会被一起冻住
    if (!await this.startBackground()) return false

    const dir: string = `${ServiceLocator.ctx.filesDir}/RecordingDrafts`
    if (!fs.accessSync(dir)) fs.mkdirSync(dir, true)
    const path: string = `${dir}/rec-${util.generateRandomUUID(false).toLowerCase()}.m4a`
    let file: fs.File
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open cache file failed: %{public}s', messageOf(e))
      await this.stopBackground()
      return false
    }

    let recorder: PcmRecorder
    try {
      recorder = await PcmRecorder.create(file.fd)
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create PCM/AAC recorder failed: %{public}s', messageOf(e))
      this.closeAndRemove(file, path)
      await this.stopBackground()
      return false
    }

    this.recorder = recorder
    this.file = file
    this.path = path
    this.project = project
    this.loc = loc

    try {
      const draft: Record<string, Object> = { 'capturedAt': Date.now() }
      const draftFd: fs.File = fs.openSync(path + '.json', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      try { fs.writeSync(draftFd.fd, ArkJson.stringify(draft)) } finally { fs.closeSync(draftFd) }
      // Bind callbacks before starting the microphone so interruptions cannot go unnoticed.
      this.listen(recorder)
      await recorder.start()
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'prepare/start failed: %{public}s', messageOf(e))
      try {
        await recorder.release()
      } catch (e2) {
        hilog.warn(DOMAIN, TAG, 'release after failed start: %{public}s', messageOf(e2))
      }
      this.recorder = null
      this.file = null
      this.path = ''
      this.project = null
      this.loc = null
      this.closeAndRemove(file, path)
      await this.stopBackground()
      return false
    }

    this.state.begin(Date.now())
    this.state.setBackgroundReminderAvailable(reminderAvailable)
    hilog.info(DOMAIN, TAG, '%{public}s', 'recording started')
    return true
  }

  // MARK: - 停止

  /**
   * 停录并落库。幂等：重复调用（用户连点两下、系统 stopped 与界面同时到）第二次直接返回 null。
   *
   * 落库失败只记日志，**不删文件**——录到的东西是不可复现的，宁可留一个孤儿在 cacheDir
   * 里等人工捞，也不能因为写 manifest 出错就把它抹掉。
   */
  async stop(interrupted: boolean = false): Promise<CaptureItem | null> {
    if (this.busy) { this.stopRequested = true; return null }
    this.stopRequested = false
    if (!this.state.isRecording && this.recorder === null) return null
    this.busy = true
    const startedAt: number = this.state.startedAt
    const path: string = this.path
    const project: RelayProject | null = this.project
    const loc: Loc | null = this.loc
    try {
      await this.teardown()
    } finally {
      this.state.finish()
      RecordingReminder.cancel()
    }
    if (path.length === 0) { this.busy = false; return null }

    let item: CaptureItem
    try {
      if (!await this.playable(path)) {
        this.state.setMessage(tr('rec.recovery.noAudio', { 'count': 1 }))
        return null
      }
      item = await ServiceLocator.store.save(MediaKind.audio, path, startedAt, loc, project)
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save failed, source file retained: %{public}s', messageOf(e))
      this.state.setMessage(tr('rec.saveFailed'))
      return null
    } finally {
      this.busy = false
    }
    this.removeDraftMetadata(path)
    this.state.setMessage(tr(interrupted || this.encodingInterrupted ? 'rec.interruption.saved' : 'rec.saved.open'))
    hilog.info(DOMAIN, TAG, '%{public}s', 'recording stored')
    // 上传不挡着返回：界面等的是「这一件已经进库」，传没传出去是队列自己的事
    // 截图模式下队列里摆的是灌进去的假件，一上传就会被打成 failed
    if (!ScreenshotMode.enabled) {
      ServiceLocator.queue.kick().catch((e: Object): void => {
        hilog.warn(DOMAIN, TAG, 'kick failed: %{public}s', messageOf(e))
      })
    }
    const cb: ((item: CaptureItem) => void) | null = this.onStored
    if (cb !== null) cb(item)
    return item
  }

  /** Returning to the foreground must not silently restart after missing audio. */
  async resumeIfInterrupted(): Promise<void> {
    if (this.state.interrupted) this.finishInterrupted()
  }

  private finishInterrupted(): void {
    if (this.busy) { this.interruptedDuringStart = true; return }
    if (!this.state.isRecording) return
    this.state.markInterrupted(Date.now())
    this.stop(true).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'interrupted save failed: %{public}s', messageOf(e))
      this.state.setMessage(tr('rec.saveFailed'))
    })
  }

  // MARK: - 事件

  private listen(recorder: PcmRecorder): void {
    recorder.onInterrupted = (): void => {
      if (this.recorder === recorder) this.finishInterrupted()
    }
    recorder.onVoice = (silenceMs: number): void => {
      if (this.recorder !== recorder || !this.state.isRecording || this.state.userPaused) return
      const wasPending: boolean = this.state.silencePending
      this.state.updateVoice(silenceMs)
      if (!wasPending && this.state.silencePending) {
        RecordingReminder.show().then((available: boolean): void => {
          if (this.recorder === recorder && this.state.isRecording && this.state.silencePending) {
            this.state.setBackgroundReminderAvailable(available)
          } else if (!this.state.silencePending) RecordingReminder.cancel()
        })
      } else if (wasPending && !this.state.silencePending) RecordingReminder.cancel()
    }
  }

  async pause(): Promise<void> {
    const recorder: PcmRecorder | null = this.recorder
    if (this.busy || recorder === null || !this.state.isRecording || this.state.userPaused) return
    this.busy = true
    try {
      await recorder.pause()
      this.state.markUserPaused(Date.now())
      RecordingReminder.cancel()
    } catch (_) {
      this.interruptedDuringStart = true
    } finally {
      await this.finishOperation()
    }
  }

  async resume(): Promise<void> {
    const recorder: PcmRecorder | null = this.recorder
    if (this.busy || recorder === null || !this.state.userPaused) return
    this.busy = true
    try {
      await recorder.resume()
      this.state.markUserResumed(Date.now())
    } catch (_) { this.state.setMessage(tr('rec.resume.failed')) } finally {
      await this.finishOperation()
    }
  }

  private async finishOperation(): Promise<void> {
    this.busy = false
    const interrupted: boolean = this.interruptedDuringStart
    this.interruptedDuringStart = false
    if (interrupted && this.state.isRecording) {
      this.state.markInterrupted(Date.now())
      await this.stop(true)
    } else if (this.stopRequested) {
      this.stopRequested = false
      await this.stop()
    }
  }

  continueAfterSilence(): void {
    if (this.recorder !== null) this.recorder.resetVoice()
    this.state.clearSilenceReminder()
    RecordingReminder.cancel()
  }

  private async playable(path: string): Promise<boolean> {
    let file: fs.File | null = null
    let extractor: media.AVMetadataExtractor | null = null
    try {
      if (!fs.accessSync(path) || fs.statSync(path).size === 0) return false
      file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      extractor = await media.createAVMetadataExtractor()
      extractor.fdSrc = { fd: file.fd, offset: 0, length: fs.statSync(path).size }
      const metadata: media.AVMetadata = await extractor.fetchMetadata()
      const duration: number = Number(metadata.duration ?? '0')
      return Number.isFinite(duration) && duration > 0 &&
        (metadata.hasAudio === 'yes' || metadata.hasAudio === 'true' || metadata.hasAudio === '1')
    } catch (_) { return false } finally {
      if (extractor !== null) { try { await extractor.release() } catch (_) {} }
      if (file !== null) closeQuietly(file)
    }
  }

  /** Interrupted process drafts recover locally as unassigned; never inherit a different sign-in's upload target. */
  async recoverDrafts(): Promise<void> {
    if (this.busy || this.state.isRecording) return
    const directory: string = `${ServiceLocator.ctx.filesDir}/RecordingDrafts`
    if (!fs.accessSync(directory)) return
    this.busy = true
    let recovered: number = 0
    let invalid: number = 0
    let failed: number = 0
    try {
      for (const name of fs.listFileSync(directory)) {
        if (!name.endsWith('.m4a.json')) continue
        const path: string = `${directory}/${name.substring(0, name.length - 5)}`
        try {
          if (!fs.accessSync(path)) { this.removeDraftMetadata(path); continue }
          if (!await this.playable(path)) { invalid++; continue }
          const data: Record<string, Object> | null = asRecord(ArkJson.parse(fs.readTextSync(path + '.json')))
          const capturedAt: number | undefined = data === null ? undefined : getNumber(data, 'capturedAt')
          if (capturedAt === undefined || !Number.isFinite(capturedAt) || capturedAt <= 0) { failed++; continue }
          await ServiceLocator.store.save(MediaKind.audio, path, capturedAt, null, null)
          this.removeDraftMetadata(path)
          recovered++
        } catch (_) { failed++ }
      }
      if (invalid > 0) this.state.setMessage(tr('rec.recovery.noAudio', { 'count': invalid }))
      else if (failed > 0) this.state.setMessage(tr('rec.recovery.saveFailed', { 'count': failed }))
      else if (recovered > 0) this.state.setMessage(tr('rec.recovery.saved', { 'count': recovered }))
    } finally { this.busy = false }
  }

  private removeDraftMetadata(path: string): void {
    try { if (fs.accessSync(path + '.json')) fs.unlinkSync(path + '.json') } catch (_) {}
  }

  // MARK: - 内部

  private async grantMic(): Promise<boolean> {
    const perms: Permissions[] = [MIC]
    try {
      const res: PermissionRequestResult =
        await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ServiceLocator.ctx, perms)
      return res.authResults.length > 0 && res.authResults.every((v: number): boolean => v === 0)
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'requestPermissionsFromUser failed: %{public}s', messageOf(e))
      return false
    }
  }

  /** 长时任务。点它的系统通知回到 EntryAbility——录音中的应用必须一步能回得来。 */
  private async startBackground(): Promise<boolean> {
    try {
      const want: Want = { bundleName: bundleName(), abilityName: 'EntryAbility' }
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      }
      const agent: WantAgent = await wantAgent.getWantAgent(info)
      await backgroundTaskManager.startBackgroundRunning(
        ServiceLocator.ctx, backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent)
      this.bgRunning = true
      return true
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', messageOf(e))
      return false
    }
  }

  private async stopBackground(): Promise<void> {
    if (!this.bgRunning) return
    this.bgRunning = false
    try {
      await backgroundTaskManager.stopBackgroundRunning(ServiceLocator.ctx)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', messageOf(e))
    }
  }

  private async teardown(): Promise<void> {
    const recorder: PcmRecorder | null = this.recorder
    const file: fs.File | null = this.file
    this.recorder = null
    this.file = null
    this.path = ''
    this.project = null
    this.loc = null
    if (recorder !== null) {
      try {
        await recorder.stop()
      } catch (e) {
        this.encodingInterrupted = true
        // Keep any playable encoded prefix, but report the incomplete tail.
        hilog.info(DOMAIN, TAG, 'stop skipped: %{public}s', messageOf(e))
      }
      try {
        await recorder.release()
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'release failed: %{public}s', messageOf(e))
      }
    }
    if (file !== null) closeQuietly(file)
    await this.stopBackground()
  }

  /** 开录半途失败时的收尾：文件里还什么都没有，留着只会当孤儿。 */
  private closeAndRemove(file: fs.File, path: string): void {
    closeQuietly(file)
    this.removeDraftMetadata(path)
    try {
      fs.unlinkSync(path)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'unlink failed: %{public}s', messageOf(e))
    }
  }
}

function closeQuietly(file: fs.File): void {
  try {
    fs.closeSync(file)
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'close failed: %{public}s', messageOf(e))
  }
}

function bundleName(): string {
  const info: bundleManager.BundleInfo =
    bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
  return info.name
}

function messageOf(e: Object): string {
  if (e instanceof Error) {
    const err: Error = e as Error
    return err.message.length > 0 ? err.message : err.name
  }
  return `${e}`
}
