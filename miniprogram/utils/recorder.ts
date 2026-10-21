/**
 * 现场录音 —— wx.getRecorderManager() 的唯一封装（dev-board#228）。
 *
 * RecorderManager 是全局单例，onStop/onError 只在首次取用时绑定一次，
 * 绝不重复绑（重复绑会让一次停止触发多次入队）。
 *
 * 分段自动续录：单段最长 10 分钟（RecorderManager 的 duration 上限），
 * 时长到顶 onStop 自动开下一段；手动停止用 manualStop 意图标志区分，
 * 避免 onStop 的「到顶还是用户停」二义。每段经 enqueueCapture 入上传队列，
 * 段号从 1 递增，文件名形如 录音_yyyyMMdd_HHmmss_段N.mp3。
 *
 * 系统中断：立即请求停止，等待 onStop 给出片段并确认留底后结束；不自动恢复。
 * 只有接近单段时长上限的完整片段可以自动续录，系统提前停止不能冒充到顶。
 */

import type { RelayProject } from './api'
import { enqueueCapture } from './queue'
import { t } from './i18n'

/** 单段最长 10 分钟——RecorderManager 的上限 */
export const SEGMENT_DURATION_MS = 600000

export interface RecorderCallbacks {
  /** 到顶自动续录、开出新一段时回调（首段不回调），带新段号 */
  onSegment: (segmentIndex: number) => void
  /** 手动停止、末段已入队后回调 */
  onFinish: () => void
  /** 录音出错（含续录失败），会话已结束 */
  onError: (message: string) => void
  /** 系统中断开始，正在停止并保存 */
  onInterrupted?: (interrupted: boolean) => void
}

interface Session extends RecorderCallbacks {
  project: RelayProject | null
  segmentIndex: number
  manualStop: boolean
  /** 被系统中断（通话等），停止后必须提示 */
  interrupted: boolean
  finalizing: boolean
  segmentStarted: boolean
  errorTimer: ReturnType<typeof setTimeout> | null
  elapsedMs: number
  resumedAt: number | null
}

let starting = false
let manager: WechatMiniprogram.RecorderManager | null = null
let session: Session | null = null
let notice: string | null = null

function getManager(): WechatMiniprogram.RecorderManager {
  if (manager) return manager
  manager = wx.getRecorderManager()

  manager.onStop((res) => {
    const s = session
    if (!s || s.finalizing || (!s.segmentStarted && !s.manualStop)) return
    clearErrorTimer(s)
    pauseClock(s)
    s.segmentStarted = false
    s.finalizing = true
    if (!res.tempFilePath || !(res.duration > 0) || !(res.fileSize > 0)) {
      finishError(s)
      return
    }
    // RecorderManager's duration is milliseconds. Allow its final frame to fall just
    // short of the configured limit; an early system stop never starts another segment.
    const complete = res.duration >= SEGMENT_DURATION_MS - 1000
    const continueRecording = complete && !s.manualStop && !s.interrupted
    try {
      enqueueCapture(res.tempFilePath, 'audio', s.project, s.segmentIndex, (saved) => {
        if (session !== s || !s.finalizing) return
        if (!saved) { finishError(s); return }
        if (continueRecording && !s.manualStop && !s.interrupted) {
          s.finalizing = false
          s.segmentIndex += 1
          s.onSegment(s.segmentIndex)
          startSegment()
        } else {
          session = null
          if (s.interrupted || !s.manualStop) notice = t('rec.interruption.saved')
          s.onFinish()
        }
      })
    } catch { finishError(s) }
  })

  manager.onError(() => {
    const s = session
    // An error delivered after onStop must not discard a file already being saved.
    if (!s || s.finalizing || s.errorTimer !== null) return
    // Native errors carry no session ID. Before onStart, allow its acknowledgement
    // to settle a late prior error; a genuine failed start still times out.
    s.errorTimer = setTimeout(() => finishError(s), 5000)
    if (s.segmentStarted || s.manualStop) {
      s.interrupted = true
      s.onInterrupted?.(true)
      stopRecording()
    }
  })

  manager.onInterruptionBegin(() => {
    const s = session
    if (!s) return
    pauseClock(s)
    s.interrupted = true
    s.onInterrupted?.(true)
    stopRecording()
  })

  manager.onStart(() => {
    const s = session
    if (!s || s.finalizing) { manager?.stop(); return }
    s.segmentStarted = true
    if (s.manualStop) { manager?.stop(); return }
    clearErrorTimer(s)
    s.resumedAt = Date.now()
  })

  return manager
}

function startSegment(): void {
  // mp3 + 16kHz 单声道是 RecorderManager 的合法组合（16000 允许码率 24k-96k），
  // 语音留证够用且体积小。
  getManager().start({
    format: 'mp3',
    sampleRate: 16000,
    numberOfChannels: 1,
    encodeBitRate: 48000,
    duration: SEGMENT_DURATION_MS,
  })
}

/**
 * 录音权限：先 authorize；被拒过的话 authorize 直接 fail，
 * 引导去设置页开「麦克风」再回来。
 */
function ensureRecordAuth(): Promise<boolean> {
  return new Promise((resolve) => {
    wx.authorize({
      scope: 'scope.record',
      success: () => resolve(true),
      fail: () => {
        wx.showModal({
          title: '需要麦克风权限',
          content: '录音需要使用麦克风。请在设置里打开「麦克风」权限后重试。',
          confirmText: '去设置',
          success: (res) => {
            if (!res.confirm) {
              resolve(false)
              return
            }
            wx.openSetting({
              success: (s) => resolve(!!s.authSetting['scope.record']),
              fail: () => resolve(false),
            })
          },
          fail: () => resolve(false),
        })
      },
    })
  })
}

export function isRecording(): boolean {
  return session !== null
}

/** 开始一次录音会话；返回是否真的开录了（权限被拒 / 已在录则 false）。 */
export async function startRecording(project: RelayProject | null, callbacks: RecorderCallbacks): Promise<boolean> {
  if (session || starting) return false
  starting = true
  try {
    const ok = await ensureRecordAuth()
    if (!ok) return false
    session = { project, segmentIndex: 1, manualStop: false, interrupted: false, finalizing: false, segmentStarted: false, errorTimer: null,
      elapsedMs: 0, resumedAt: null, ...callbacks }
    startSegment()
    return session !== null
  } finally { starting = false }
}

/** 手动停止：末段在 onStop 里入队后回调 onFinish。 */
export function stopRecording(): void {
  if (!session || session.manualStop) return
  session.manualStop = true
  pauseClock(session)
  if (!session.finalizing) getManager().stop()
}

function clearErrorTimer(s: Session): void {
  if (s.errorTimer !== null) clearTimeout(s.errorTimer)
  s.errorTimer = null
}

function finishError(s: Session): void {
  if (session !== s) return
  clearErrorTimer(s)
  session = null
  notice = t('rec.failed')
  s.onError(notice)
}

/** Keep notices while the capture page is hidden or has been recreated. */
export function takeRecordingNotice(): string | null {
  const result = notice
  notice = null
  return result
}

function pauseClock(s: Session): void {
  if (s.resumedAt !== null) s.elapsedMs += Math.max(0, Date.now() - s.resumedAt)
  s.resumedAt = null
}

/** A recreated page restores its controls and clock from the recording session. */
export function recordingSnapshot() {
  const s = session
  if (!s) return null
  return { segmentIndex: s.segmentIndex, interrupted: s.interrupted,
    elapsedSeconds: Math.floor((s.elapsedMs + (s.resumedAt === null ? 0 : Math.max(0, Date.now() - s.resumedAt))) / 1000) }
}

export function bindRecordingCallbacks(callbacks: RecorderCallbacks): void {
  if (session) Object.assign(session, callbacks)
}
