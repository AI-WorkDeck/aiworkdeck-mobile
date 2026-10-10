/**
 * 主界面 —— 取景器优先（与 iOS 端同期重构对齐，取证拍摄流程两端逐像素一致）。
 *
 * 顶部信息（项目名 / 待传·传输中·已上传 / 切换项目）、中部 <camera> 实时取景 +
 * 左下角淡水印（时间到秒、项目名），底部「照片/录像/录音」三档显式切换 +
 * 居中大快门 + 左侧最近缩略图入口。
 *
 * 水印只是界面叠加，不烧录进照片——烧录会破坏取证哈希链（刻意决策，别改）。
 * 上传队列与云中转契约（utils/queue.ts / utils/api.ts）一律不动，本页只做 UI 与接线。
 */

import { Icon } from '../../utils/icons'
import type { Metrics } from '../../utils/layout'
import { getSession, getSelectedProject, type RelayProject } from '../../utils/api'
import { listItems, tallyFor, subscribe, pollStatus, processQueue, enqueueCapture, type QueueItem } from '../../utils/queue'
import { dotClass, projectId, tallyTotal, PHASE_LABEL, type Tally } from '../../utils/phase'
import { t } from '../../utils/i18n'
import { reportDiag } from '../../utils/diag'
import { startRecording, stopRecording, isRecording, resumeIfInterrupted, recordingSnapshot, bindRecordingCallbacks } from '../../utils/recorder'
import { CAPS, DEGRADED_NOTICE } from '../../utils/contract/capabilities'
import { thumbFor, setVideoThumb, markThumbBroken } from '../../utils/thumbs'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

/** 队列轮询节奏：5 秒一次，见实施契约 §3 */
const POLL_INTERVAL = 5000

/** 「拍摄件同时存入系统相册」开关（dev-board#311，对齐 iOS 端 Prefs.saveToAlbum）。
 *  默认关：尽调影像进相册是要用户知情选择的事，与 iOS 端同一权衡。 */
const KEY_SAVE_ALBUM = 'awd.saveToAlbum'

type CaptureMode = 'photo' | 'video' | 'audio'

/** D6：能力边界明示，不能默默降级 */
const MODE_NOTES: Record<CaptureMode, string> = {
  photo: '拍摄内容自动归入今天的现场影像；水印仅屏幕显示，不写入照片',
  video: '录像单段最长 30 秒，自动连续分段归档；本端录像为记录用途，证据用途请用 iOS 端',
  audio: '录音自动归入今天的现场录音，单段满 10 分钟自动续录',
}

/** 底部最近缩略图入口的展示结构 */
interface RecentDisplay {
  id: string
  /** 可渲染的缩略图路径；空串走占位图标 */
  thumb: string
  icon: string
  /** 状态点样式类，见 phase.dotClass */
  dotClass: string
}

function placeholderIcon(mediaType: QueueItem['mediaType']): string {
  if (mediaType === 'video') return Icon.videoWhite
  if (mediaType === 'audio') return Icon.micWhite
  return Icon.imageWhite
}

/** 今天的归档路径，取本机时区 */
function todayArchivePath(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = `${d.getMonth() + 1}`.padStart(2, '0')
  const day = `${d.getDate()}`.padStart(2, '0')
  return t('archive.path', { date: `${y}-${m}-${day}` })
}

/** 水印时间：到秒 */
function watermarkTime(): string {
  const d = new Date()
  const p = (n: number) => `${n}`.padStart(2, '0')
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
  )
}

Page({
  data: {
    Icon,
    phaseLabel: PHASE_LABEL,
    metrics: {} as Metrics,
    project: { name: '', archivePath: '' },
    archiveTo: '',
    /** 三档模式与快门的可读标签走词典（与 iOS / 安卓同键） */
    labels: {
      photo: t('home.mode.photo'),
      video: t('home.mode.video'),
      audio: t('home.mode.audio'),
      shoot: t('home.shutter.photo'),
      on: t('common.on'),
      off: t('common.off'),
    },
    settingsLabel: t('settings.title'),
    tally: { uploading: 0, failed: 0, staged: 0, landed: 0 } as Tally,
    failedSuffix: '',
    total: 0,
    recent: null as RecentDisplay | null,
    mode: 'photo' as CaptureMode,
    modeNote: MODE_NOTES.photo,
    /** pending：等相机初始化；ready：取景中；denied：权限被拒/初始化失败 */
    cameraState: 'pending' as 'pending' | 'ready' | 'denied',
    /** <camera> 原生组件挂不挂。只在本页可见时为 true，见 mountCamera/unmountCamera（dev-board#536） */
    cameraMounted: false,
    recording: false,
    recordElapsed: '00:00',
    recordSegment: 1,
    /** 录音被系统中断（通话等），中断结束自动续录 */
    recordInterrupted: false,
    recordInterruptedText: '',
    /** 能力降级提示：小程序不承诺后台续录时显示，否则空 */
    audioNote: '',
    wmTime: '',
    saveToAlbum: false,
  },

  unsubscribe: null as (() => void) | null,
  /** 本页是不是当前可见页。bindstop 的恢复只在可见时做，页面被盖住时重挂没有意义。 */
  visible: false,
  pollTimer: null as number | null,
  recordTimer: null as number | null,
  wmTimer: null as number | null,
  recordStartedAt: 0,
  cameraCtx: null as WechatMiniprogram.CameraContext | null,
  /** 当前录像段是否已被收走（timeoutCallback 与 stopRecord 只允许一方入队） */
  segmentHandled: true,
  /** 手动停止意图：timeoutCallback 恰好赶上时不再续下一段 */
  manualStopping: false,

  onLoad() {
    const app = getApp<AppGlobal>()
    this.setData({
      metrics: app.globalData.metrics,
      saveToAlbum: wx.getStorageSync(KEY_SAVE_ALBUM) === true,
      recordInterruptedText: t('rec.paused.interrupted'),
      audioNote: CAPS.backgroundRecording === false ? t(DEGRADED_NOTICE.backgroundRecording) : '',
    })
  },

  onShow() {
    // 守门：无会话去登录，有会话无选中项目去项目选择。守门没过就不渲染真数据。
    if (!getSession()) {
      wx.reLaunch({ url: '/pages/login/login' })
      return
    }
    const project = getSelectedProject()
    if (!project) {
      wx.reLaunch({ url: '/pages/project/project' })
      return
    }

    this.setData({
      project: { name: project.name, archivePath: todayArchivePath() },
      archiveTo: t('home.archiveTo', { path: todayArchivePath() }),
    })

    // 录音态与真实 recorder 对齐：页面被 reLaunch 重建等场景下不残留假录制中
    const recording = recordingSnapshot()
    if (recording) {
      bindRecordingCallbacks(this.audioCallbacks())
      this.setData({ mode: 'audio', recording: true, recordSegment: recording.segmentIndex,
        recordInterrupted: recording.interrupted })
      this.startRecordTimer()
    } else if (this.data.mode === 'audio' && this.data.recording && !isRecording()) {
      this.stopRecordUi()
    }
    // 通话结束事件没送到时，回前台补一次续录
    resumeIfInterrupted()

    this.visible = true
    // 安卓从别的页面返回时，上一块原生相机可能还没释放；晚一拍再挂，避免新实例初始化失败
    // 变成一块盖住整页的白画布（dev-board#536）。首次进入也走这条，300ms 肉眼无感。
    setTimeout(() => { if (this.visible) this.mountCamera() }, 300)

    this.refresh()
    if (!this.unsubscribe) {
      this.unsubscribe = subscribe(() => this.refresh())
    }
    this.startPolling()
    this.startWatermark()
    // 启动时未登录的话 recoverOnLaunch 不动队列；守门通过说明已登录，
    // 这里把遗留的待上传项带起来（幂等，单飞锁挡重复）。
    processQueue()
  },

  onHide() {
    this.visible = false
    this.stopPolling()
    this.stopWatermark()
    // 页面隐藏相机即停：录像中尽力收走当前段，不让已录内容白丢。
    // 录音不停——requiredBackgroundModes audio 支持后台续录，维持既有行为。
    if (this.data.mode === 'video' && this.data.recording) {
      this.manualStopping = true
      // 卸载放在 stopRecord 的回调里：先卸原生组件，这一段就收不回来了
      this.camera().stopRecord({
        success: (res) => {
          this.onVideoSegmentEnd(res, false)
          this.unmountCamera()
        },
        fail: () => {
          this.stopRecordUi()
          this.unmountCamera()
        },
      })
      return
    }
    this.unmountCamera()
  },

  onUnload() {
    bindRecordingCallbacks({ onSegment: () => {}, onFinish: () => {}, onError: () => {} })
    this.visible = false
    // 页面正在销毁，只丢引用不 setData
    this.cameraCtx = null
    this.stopPolling()
    this.stopWatermark()
    this.stopRecordTimer()
    if (this.unsubscribe) {
      this.unsubscribe()
      this.unsubscribe = null
    }
  },

  camera(): WechatMiniprogram.CameraContext {
    if (!this.cameraCtx) {
      this.cameraCtx = wx.createCameraContext()
    }
    return this.cameraCtx
  },

  /**
   * 本页可见时才挂 <camera>（dev-board#536）。
   *
   * 原生组件不在 WebView 的渲染流程里（微信文档「原生组件说明」），页面被 navigateTo 盖住时
   * 组件仍留在节点树上、相机会话却被客户端收走；安卓上同层渲染一旦失败，这块脱离 WebView 的
   * 死画布会盖住整个页面——回到首页看到的就是一整屏白且点不动。**卸掉再挂一个新的**是本仓
   * 已有的做法（见 onOpenCameraSetting 的注释：wx:if 先卸再挂，让 camera 组件重新初始化）。
   */
  mountCamera() {
    if (!this.data.cameraMounted) this.setData({ cameraMounted: true })
  },

  /** 卸掉原生组件，顺手丢掉绑在它上面的 CameraContext；denied 态保留，别把权限提示闪没了。 */
  unmountCamera() {
    this.cameraCtx = null
    if (!this.data.cameraMounted && this.data.cameraState !== 'ready') return
    const patch: { cameraMounted: boolean; cameraState?: 'pending' } = { cameraMounted: false }
    if (this.data.cameraState === 'ready') patch.cameraState = 'pending'
    this.setData(patch)
  },

  startPolling() {
    this.stopPolling()
    this.pollTimer = setInterval(() => {
      pollStatus()
    }, POLL_INTERVAL)
  },

  stopPolling() {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  },

  refresh() {
    // 只看当前项目：最近缩略图与三段计数都跟着项目走
    const project = getSelectedProject()
    if (!project) return
    const pid = projectId({ deviceId: project.deviceId, projectKey: project.key, projectUid: project.projectUid })
    const latest = listItems(pid)[0]
    const recent: RecentDisplay | null = latest
      ? {
          id: latest.clientMediaId,
          thumb: thumbFor(latest),
          icon: placeholderIcon(latest.mediaType),
          dotClass: dotClass(latest.state),
        }
      : null
    const tally = tallyFor(pid)
    const failedSuffix = tally.failed > 0 ? t('tally.failedSuffix', { m: tally.failed }) : ''
    this.setData({ tally, failedSuffix, total: tallyTotal(tally), recent })
  },

  // ---------- 水印（仅界面叠加，不写入影像文件） ----------

  startWatermark() {
    this.stopWatermark()
    this.setData({ wmTime: watermarkTime() })
    this.wmTimer = setInterval(() => {
      this.setData({ wmTime: watermarkTime() })
    }, 1000)
  },

  stopWatermark() {
    if (this.wmTimer !== null) {
      clearInterval(this.wmTimer)
      this.wmTimer = null
    }
  },

  // ---------- 相机状态 ----------

  onCameraReady() {
    this.setData({ cameraState: 'ready' })
  },

  onCameraError(e?: { detail?: { errMsg?: string } }) {
    reportDiag('相机错误', String(e && e.detail && e.detail.errMsg ? e.detail.errMsg : '(无 errMsg)'))
    // 权限被拒与初始化失败走同一个降级态：明示 + 去设置 + 系统相机兜底
    if (this.data.recording && this.data.mode === 'video') {
      this.stopRecordUi()
    }
    this.setData({ cameraState: 'denied' })
  },

  /** 摄像头非正常终止（微信文档：如退出后台等情况）。可见时重挂一个新的，
   *  否则留着一块永远不会再出画面的死取景区。录制中交给既有的停止/报错路径，不在这里插手。 */
  onCameraStop() {
    if (this.data.recording) return
    this.unmountCamera()
    // 同一帧里卸了又挂等于没卸：两次 setData 会被合并，原生组件不会重建。等下一帧再挂。
    if (this.visible) wx.nextTick(() => { if (this.visible) this.mountCamera() })
  },

  onOpenCameraSetting() {
    wx.openSetting({
      success: (res) => {
        if (res.authSetting['scope.camera']) {
          // wx:if 先卸再挂，让 camera 组件带着新授权重新初始化
          this.setData({ cameraState: 'pending' })
        }
      },
    })
  },

  // ---------- 三档模式 ----------

  onSwitchMode(e: WechatMiniprogram.BaseEvent<WechatMiniprogram.IAnyObject, { mode: CaptureMode }>) {
    const mode = e.currentTarget.dataset.mode
    if (mode === this.data.mode) return
    // 录制中锁死模式切换，先停再切
    if (this.data.recording) {
      wx.showToast({ title: '请先停止当前录制', icon: 'none' })
      return
    }
    this.setData({ mode, modeNote: MODE_NOTES[mode] })
  },

  // ---------- 快门 ----------

  onShutter() {
    if (isRecording()) { stopRecording(); return }
    const project = getSelectedProject()
    if (!project) return
    wx.vibrateShort({ type: 'light' })

    const mode = this.data.mode
    if (mode === 'audio') {
      if (this.data.recording) {
        this.onStopAudio()
      } else {
        this.onStartAudio(project)
      }
      return
    }

    if (this.data.cameraState !== 'ready') {
      wx.showToast({ title: '相机未就绪', icon: 'none' })
      return
    }

    if (mode === 'photo') {
      this.takePhoto(project)
    } else if (this.data.recording) {
      this.stopVideo()
    } else {
      this.startVideo()
    }
  },

  // ---------- 存相册开关（dev-board#311，对齐 iOS 设置页开关） ----------

  onToggleAlbum() {
    if (!this.data.saveToAlbum) {
      // 开：先把授权拿到手。之前拒过的话 authorize 不会再弹，只能引导去设置页。
      wx.getSetting({
        success: (s) => {
          const granted = s.authSetting['scope.writePhotosAlbum']
          if (granted) {
            this.setAlbumEnabled(true)
          } else if (granted === false) {
            wx.openSetting({
              success: (s2) => {
                if (s2.authSetting['scope.writePhotosAlbum']) this.setAlbumEnabled(true)
              },
            })
          } else {
            wx.authorize({
              scope: 'scope.writePhotosAlbum',
              success: () => this.setAlbumEnabled(true),
              fail: () => {
                wx.showToast({ title: '没有相册权限，影像仍只留在应用内', icon: 'none' })
              },
            })
          }
        },
      })
    } else {
      this.setAlbumEnabled(false)
    }
  },

  setAlbumEnabled(on: boolean) {
    wx.setStorageSync(KEY_SAVE_ALBUM, on)
    this.setData({ saveToAlbum: on })
  },

  /**
   * 开关开着就先存相册、再交给 done 入队。
   *
   * **顺序是被迫的**：enqueueCapture 里的 saveFile 会把临时文件挪进本地存储，
   * 挪完临时路径即失效——并发调 saveXxxToPhotosAlbum 是在跟它赛跑。
   * 相册写失败不打断入队（与 iOS saveToAlbumIfEnabled 同口径：两条链彼此独立）。
   */
  saveToAlbumIfEnabled(tempFilePath: string, kind: 'image' | 'video'): Promise<void> {
    if (!this.data.saveToAlbum) return Promise.resolve()
    return new Promise((resolve) => {
      const opts = {
        filePath: tempFilePath,
        fail: (e: { errMsg?: string }) => {
          const denied = (e.errMsg || '').includes('auth')
          wx.showToast({ title: denied ? '没能存入相册：点「存相册」重新授权' : '没能存入相册', icon: 'none' })
        },
        complete: () => resolve(),
      }
      if (kind === 'image') {
        wx.saveImageToPhotosAlbum(opts)
      } else {
        wx.saveVideoToPhotosAlbum(opts)
      }
    })
  },

  // ---------- 照片 ----------

  takePhoto(project: RelayProject) {
    this.camera().takePhoto({
      quality: 'high',
      success: (res) => {
        this.saveToAlbumIfEnabled(res.tempImagePath, 'image').then(() => {
          enqueueCapture(res.tempImagePath, 'image', project)
        })
      },
      fail: () => {
        wx.showToast({ title: '拍摄失败', icon: 'none' })
      },
    })
  },

  // ---------- 录像：30 秒到顶自动续下一段（连续分段，D6 界面明示） ----------

  startVideo() {
    this.recordStartedAt = Date.now()
    this.setData({ recording: true, recordSegment: 1, recordElapsed: '00:00' })
    this.startRecordTimer()
    this.manualStopping = false
    this.startVideoSegment()
  },

  startVideoSegment() {
    this.segmentHandled = false
    this.camera().startRecord({
      timeoutCallback: (res) => this.onVideoSegmentEnd(res, true),
      fail: () => {
        // 首段常见于录音权限（录像要带声音）被拒
        this.stopRecordUi()
        wx.showToast({ title: '录像启动失败，请检查麦克风权限', icon: 'none' })
      },
    })
  },

  stopVideo() {
    this.manualStopping = true
    this.camera().stopRecord({
      success: (res) => this.onVideoSegmentEnd(res, false),
      fail: () => {
        // 该段可能刚被 timeoutCallback 收走，这里只收 UI
        this.stopRecordUi()
      },
    })
  },

  /** 一段录像结束（到顶或手动停）：入队 + 记帧图；到顶且未要求停则续下一段 */
  onVideoSegmentEnd(
    res: { tempVideoPath?: string; tempThumbPath?: string },
    timedOut: boolean,
  ) {
    if (this.segmentHandled) return
    this.segmentHandled = true

    const project = getSelectedProject()
    if (project && res.tempVideoPath) {
      // 段号先抓下来：续录分支马上就会把 recordSegment 加一
      const videoPath = res.tempVideoPath
      const thumbPath = res.tempThumbPath
      const segment = this.data.recordSegment
      this.saveToAlbumIfEnabled(videoPath, 'video').then(() => {
        const item = enqueueCapture(videoPath, 'video', project, segment)
        if (thumbPath) setVideoThumb(item.clientMediaId, thumbPath)
      })
    }

    if (timedOut && !this.manualStopping) {
      // 静默续录下一段，不弹窗打断现场
      this.setData({ recordSegment: this.data.recordSegment + 1 })
      this.startVideoSegment()
    } else {
      this.stopRecordUi()
    }
  },

  // ---------- 录音（第三档，显式入口；分段续录见 recorder.ts） ----------

  audioCallbacks() {
    return {
      onSegment: (segmentIndex: number) => this.setData({ recordSegment: segmentIndex }),
      onFinish: () => this.stopRecordUi(),
      onError: (message: string) => {
        this.stopRecordUi()
        wx.showToast({ title: message, icon: 'none' })
      },
      onInterrupted: (recordInterrupted: boolean) => this.setData({ recordInterrupted }),
    }
  },

  async onStartAudio(project: RelayProject) {
    const started = await startRecording(project, this.audioCallbacks())
    if (!started) return

    this.recordStartedAt = Date.now()
    this.setData({ recording: true, recordSegment: 1, recordElapsed: '00:00' })
    this.startRecordTimer()
  },

  onStopAudio() {
    // 末段入队后 recorder 回调 onFinish → stopRecordUi
    stopRecording()
  },

  // ---------- 录制计时（录像/录音共用） ----------

  stopRecordUi() {
    this.stopRecordTimer()
    this.setData({ recording: false, recordElapsed: '00:00', recordSegment: 1, recordInterrupted: false })
  },

  startRecordTimer() {
    this.stopRecordTimer()
    this.recordTimer = setInterval(() => {
      const total = this.data.mode === 'audio'
        ? (recordingSnapshot()?.elapsedSeconds ?? 0)
        : Math.floor((Date.now() - this.recordStartedAt) / 1000)
      const mm = `${Math.floor(total / 60)}`.padStart(2, '0')
      const ss = `${total % 60}`.padStart(2, '0')
      this.setData({ recordElapsed: `${mm}:${ss}` })
    }, 1000)
  },

  stopRecordTimer() {
    if (this.recordTimer !== null) {
      clearInterval(this.recordTimer)
      this.recordTimer = null
    }
  },

  // ---------- 系统相机兜底（<camera> 起不来时保留原触发方式） ----------

  async onSystemCapture() {
    if (this.data.recording) return
    const project = getSelectedProject()
    if (!project) return

    const media = await this.chooseFromSystem(['image', 'video'])
    if (!media) return

    if (media.type === 'video') {
      await this.saveToAlbumIfEnabled(media.tempFilePath, 'video')
      const item = enqueueCapture(media.tempFilePath, 'video', project, 1)
      if (media.thumbTempFilePath) setVideoThumb(item.clientMediaId, media.thumbTempFilePath)
      await this.recordMoreSegments(project, 1)
    } else {
      await this.saveToAlbumIfEnabled(media.tempFilePath, 'image')
      enqueueCapture(media.tempFilePath, 'image', project)
    }
  },

  /** 单段录满后询问是否续录下一段，取消则结束循环 */
  async recordMoreSegments(project: RelayProject, segmentIndex: number) {
    const { confirm } = await wx.showModal({
      title: `已录制第 ${segmentIndex} 段（单段最长 60 秒）`,
      content: '继续录制下一段吗？',
    })
    if (!confirm) return

    const media = await this.chooseFromSystem(['video'])
    if (!media) return

    const next = segmentIndex + 1
    await this.saveToAlbumIfEnabled(media.tempFilePath, 'video')
    const item = enqueueCapture(media.tempFilePath, 'video', project, next)
    if (media.thumbTempFilePath) setVideoThumb(item.clientMediaId, media.thumbTempFilePath)
    await this.recordMoreSegments(project, next)
  },

  /** 拉起系统相机；用户取消不算错误，只有非取消的失败才提示 */
  async chooseFromSystem(
    mediaType: Array<'image' | 'video'>
  ): Promise<{ type: string; tempFilePath: string; thumbTempFilePath?: string } | null> {
    try {
      const res = await wx.chooseMedia({
        count: 1,
        mediaType,
        sourceType: ['camera'],
        maxDuration: 60,
        camera: 'back',
      })
      const file = res.tempFiles[0]
      return { type: res.type, tempFilePath: file.tempFilePath, thumbTempFilePath: file.thumbTempFilePath }
    } catch (err) {
      const message = (err as { errMsg?: string })?.errMsg || ''
      if (!message.includes('cancel')) {
        wx.showToast({ title: '拍摄未完成', icon: 'none' })
      }
      return null
    }
  },

  // ---------- 缩略图渲染失败回落占位 ----------

  onRecentThumbError() {
    if (this.data.recent) {
      markThumbBroken(this.data.recent.id)
      this.refresh()
    }
  },

  // ---------- 导航 ----------

  onOpenQueue() {
    wx.navigateTo({ url: '/pages/queue/queue' })
  },

  onOpenGallery() {
    wx.navigateTo({ url: '/pages/gallery/gallery' })
  },

  onOpenSettings() {
    wx.navigateTo({ url: '/pages/settings/settings' })
  },

  onSwitchProject() {
    if (this.data.recording) {
      wx.showToast({ title: '请先停止当前录制', icon: 'none' })
      return
    }
    wx.navigateTo({ url: '/pages/project/project' })
  },
})
