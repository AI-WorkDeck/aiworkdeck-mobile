import { ContractCapabilities } from 'contract'
import { RecordingClock } from '../model/RecordingClock'

/**
 * 录音的进程级状态。录音跨得过界面的生死（长时任务在后台继续录，取景页可能已经销毁重建），
 * 界面与录音机只能隔着这个对象说话——对位安卓 `RecordingState.kt`。
 *
 * **不用状态装饰器**：理由同 `AppModel`（V1 的 `@State` 会包代理、V2 的 `@Trace` 只在
 * `@ComponentV2` 里被观察，而现有组件是 V1）。谁要跟着变，谁 `subscribe` 一个回调，
 * 在回调里把值抄进自己的 `@State`。
 *
 * 秒表只在录音中跑：`elapsedSec` 每秒从 `clock.elapsed(now)` 重算，而不是自增计数——
 * 中断期间时钟不走，自增会把通话的那两分钟也算成录音时长。
 */
export class RecordingState {
  message: string = ''
  isRecording: boolean = false
  /** 开录的墙钟时刻（毫秒）。落库的采集时刻也取它——「什么时候开始录」比「什么时候按停」重要。 */
  startedAt: number = 0
  /** 被系统中断（来电等）暂停中。界面据此显示 `rec.paused.interrupted`。 */
  interrupted: boolean = false
  userPaused: boolean = false
  silencePending: boolean = false
  voiceUnavailable: boolean = false
  backgroundReminderAvailable: boolean = true
  readonly clock: RecordingClock = new RecordingClock()
  elapsedSec: number = 0

  private tickId: number = -1
  private nextToken: number = 1
  private readonly listeners: Map<number, () => void> = new Map<number, () => void>()

  /** 订阅状态变化。返回的号用来退订（页面 aboutToDisappear 里退，免得回调打在已销毁的组件上）。 */
  subscribe(cb: () => void): number {
    const token: number = this.nextToken
    this.nextToken = token + 1
    this.listeners.set(token, cb)
    return token
  }

  unsubscribe(token: number): void {
    this.listeners.delete(token)
  }

  // MARK: - 迁移（纯状态，由 RecorderService 在录音机真的动了之后调用）

  begin(at: number): void {
    this.message = ''
    this.clock.start(at)
    this.startedAt = at
    this.isRecording = true
    this.interrupted = false
    this.userPaused = false
    this.silencePending = false
    this.voiceUnavailable = false
    this.elapsedSec = 0
    this.startTicking()
    this.emit()
  }

  /** 系统把录音机暂停了。幂等：系统可能只发状态不发原因，两条路都会走到这里。 */
  markInterrupted(at: number): void {
    if (!this.isRecording || this.interrupted) return
    this.clock.interrupt(at)
    this.interrupted = true
    this.recompute()
    this.emit()
  }

  markResumed(at: number): void {
    if (!this.isRecording || !this.interrupted) return
    this.clock.resume(at)
    this.interrupted = false
    this.recompute()
    this.emit()
  }

  markUserPaused(at: number): void {
    if (!this.isRecording || this.userPaused) return
    this.clock.interrupt(at)
    this.userPaused = true
    this.silencePending = false
    this.voiceUnavailable = false
    this.recompute()
    this.emit()
  }

  markUserResumed(at: number): void {
    if (!this.isRecording || !this.userPaused) return
    this.clock.resume(at)
    this.userPaused = false
    this.silencePending = false
    this.voiceUnavailable = false
    this.message = ''
    this.recompute()
    this.emit()
  }

  updateVoice(silenceMs: number): void {
    if (!this.isRecording || this.userPaused || this.interrupted) return
    const unavailable: boolean = silenceMs < 0
    const pending: boolean = silenceMs >= ContractCapabilities.voiceReminderSeconds * 1000
    if (this.voiceUnavailable === unavailable && this.silencePending === pending) return
    this.voiceUnavailable = unavailable
    this.silencePending = pending
    this.emit()
  }

  clearSilenceReminder(): void {
    this.silencePending = false
    this.emit()
  }

  finish(): void {
    this.stopTicking()
    this.isRecording = false
    this.interrupted = false
    this.userPaused = false
    this.silencePending = false
    this.voiceUnavailable = false
    this.startedAt = 0
    this.elapsedSec = 0
    this.emit()
  }

  setBackgroundReminderAvailable(available: boolean): void {
    this.backgroundReminderAvailable = available
    this.emit()
  }

  setMessage(message: string): void {
    this.message = message
    this.emit()
  }

  // MARK: - 内部

  private startTicking(): void {
    if (this.tickId >= 0) return
    this.tickId = setInterval((): void => this.tick(), 1000)
  }

  private stopTicking(): void {
    if (this.tickId < 0) return
    clearInterval(this.tickId)
    this.tickId = -1
  }

  /** 秒表一跳。秒数没变就不吵醒订阅者——中断期间时钟停着，每秒重画一次没有意义。 */
  private tick(): void {
    const before: number = this.elapsedSec
    this.recompute()
    if (this.elapsedSec !== before) this.emit()
  }

  private recompute(): void {
    this.elapsedSec = Math.floor(this.clock.elapsed(Date.now()))
  }

  private emit(): void {
    for (const cb of this.listeners.values()) cb()
  }
}
