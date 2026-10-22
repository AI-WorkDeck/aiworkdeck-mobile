import { abilityAccessCtrl, common, PermissionRequestResult, Permissions, Want } from '@kit.AbilityKit'
import { fileUri } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BackupConsentService } from '../services/BackupConsentService'
import { AppModel } from '../AppModel'
import { StatusDot } from '../design/Components'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { CaptureItem, MediaKind, RelayProject } from '../model/Capture'
import { formatClock, formatDay } from '../model/Format'
import { Loc } from '../model/Loc'
import { Tally } from '../model/TransferTally'
import { gpsChip, watermarkLines } from '../model/Watermark'
import { CameraService, isCameraClosed } from '../services/CameraService'
import { LocationStamper } from '../services/LocationStamper'
import {
  hasPermission, PERM_APPROX_LOCATION, PERM_CAMERA, PERM_LOCATION, PERM_MICROPHONE,
} from '../services/Permissions'
import { RecorderService } from '../services/RecorderService'
import { RecordingState } from '../services/RecordingState'
import { ScreenshotMode } from '../ScreenshotMode'
import { ServiceLocator } from '../services/ServiceLocator'
import { errorText, toast } from './Feedback'

const DOMAIN: number = 0x0000
const TAG: string = 'Home'

/** 秒针：水印时间行与录制计时共用这一个心跳。 */
const TICK_MS: number = 1000
/** 定位续期。按快门到落库不能等 GPS，所以平时就把最近一次的结果留着。 */
const LOCATE_MS: number = 10000
/** 快门白闪的时长。唯一的「拍到了」即时反馈，比任何提示都快。 */
const FLASH_MS: number = 120

/** 快门内圈与白闪的纯白；Color 枚举与令牌字符串混在三元里会让 ResourceColor 推成联合类型。 */
const WHITE: string = '#FFFFFF'
const TRANSPARENT: string = '#00000000'

const SHUTTER_SIZE: number = 74
const SHUTTER_INNER: number = 60
const STOP_SIZE: number = 30
const THUMB_SIZE: number = 44

/** 三档采集模式。录音不点亮摄像头——麦克风不需要相机会话。 */
enum CapMode {
  photo = 'photo',
  video = 'video',
  audio = 'audio',
}

/**
 * 首页 = 取景器。现场是单手、光线差、要快，所以进来就是镜头，不再隔一层「按转盘进取景页」。
 * 信息各归其位：业务归属在顶部，画面铺满中间（淡水印叠加），快门与档位在拇指够得到的下方。
 * 镜像安卓 `HomeScreen.kt` 与 iOS `HomeView`。
 *
 * 水印**只叠加在取景与展示层，不烧录进照片字节**（决策 D3）：照片要保住 JPEG 直出的
 * SHA-256，烧录会毁掉证据链。
 */
@Component
export struct Home {
  stack: NavPathStack = new NavPathStack()

  @State mode: CapMode = CapMode.photo
  @State hasCamera: boolean = false
  @State hasMic: boolean = false
  @State hasLocation: boolean = false
  @State projectName: string = ''
  @State tallyText: string = ''
  @State total: number = 0
  @State desktopOnline: boolean = false
  @State recentUri: string = ''
  @State recentIsAudio: boolean = false
  @State hasRecent: boolean = false
  @State gpsText: string = ''
  @State stampLines: string[] = []
  @State recordingVideo: boolean = false
  @State recordingMessage: string = ''
  @State recordingAudio: boolean = false
  @State interrupted: boolean = false
  @State recordingPaused: boolean = false
  @State voiceUnavailable: boolean = false
  @State backgroundReminderAvailable: boolean = true
  @State pauseBusy: boolean = false
  @State landscape: boolean = false
  @State elapsedText: string = '00:00'
  @State flash: boolean = false

  private readonly xctl: XComponentController = new XComponentController()
  private readonly camera: CameraService = new CameraService()
  private readonly stamper: LocationStamper = new LocationStamper()
  /** 最近一次定位。按快门时取它的快照——现场按下快门到落库不能等 GPS。 */
  private locSnapshot: Loc | null = null
  /** 开录那一瞬的项目与位置快照。停录可能是几分钟后的事，中途换了项目也不该改归属。 */
  private videoProject: RelayProject | null = null
  private videoLoc: Loc | null = null
  private surfaceId: string = ''
  private visible: boolean = false
  private foreground: boolean = true
  /** 这一屏还在不在。异步回调回来时组件可能已经销毁，往里写 @State 是错误日志甚至崩溃。 */
  private alive: boolean = false
  private tickId: number = -1
  private flashId: number = -1
  private locateId: number = -1
  private token: number = -1
  private recToken: number = -1
  private silenceDialog: boolean = false
  private lifeToken: number = -1

  // MARK: - 生命周期

  aboutToAppear(): void {
    this.alive = true
    // 模拟器没有 GPS（一直「定位中」）：截图模式给一个固定的 ±5 米
    if (ScreenshotMode.enabled) this.locSnapshot = ScreenshotMode.loc
    this.token = AppModel.shared.subscribe((): void => this.syncModel())
    this.recToken = RecorderService.shared.state.subscribe((): void => this.syncRecording())
    this.lifeToken = AppModel.shared.subscribeLifecycle((foreground: boolean): void => {
      this.onLifecycle(foreground)
    })
    this.readPermissions()
    this.syncModel()
    this.syncRecording()
    this.tick()
    this.tickId = setInterval((): void => this.tick(), TICK_MS)
    this.askPermissions()
    BackupConsentService.promptFirstUse(this.getUIContext(), (): boolean => this.alive)
  }

  aboutToDisappear(): void {
    this.alive = false
    if (this.token >= 0) AppModel.shared.unsubscribe(this.token)
    if (this.recToken >= 0) RecorderService.shared.state.unsubscribe(this.recToken)
    if (this.lifeToken >= 0) AppModel.shared.unsubscribeLifecycle(this.lifeToken)
    if (this.tickId >= 0) clearInterval(this.tickId)
    if (this.flashId >= 0) {
      clearTimeout(this.flashId)
      this.flashId = -1
    }
    this.stopLocating()
    // 这一屏被换掉（退出登录、切项目）时相机不会自己放开，镜头会一直亮着、别的应用也拿不到
    this.stopVideoAndStore()
    this.camera.close().catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'close on disappear failed: %{public}s', `${e}`)
    })
  }

  /**
   * 退到后台只停录像与相机，**不停录音**——录音靠长时任务继续录，这正是 #407 要的。
   * 回前台把预览重开：摄像头在后台留不住。
   */
  private onLifecycle(foreground: boolean): void {
    this.foreground = foreground
    if (foreground) {
      this.readPermissions()
      this.openCamera()
      this.showSilenceReminder()
      return
    }
    this.stopVideoAndStore()
    this.camera.close().catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'close on background failed: %{public}s', `${e}`)
    })
  }

  build() {
    NavDestination() {
      Stack() {
        this.stage()
        Column() {
          this.topBar()
          Column() {
            if (this.mode === CapMode.audio) {
              this.audioStage()
            } else if (!this.hasCamera) {
              this.permissionStage(tr('home.permission.camera'))
            } else {
              this.stamp()
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding(Tk.Sp.s3)
          .alignItems(this.centered() ? HorizontalAlign.Center : HorizontalAlign.Start)
          .justifyContent(this.centered() ? FlexAlign.Center : FlexAlign.End)

          this.bottomBar()
        }
        .width('100%')
        .height('100%')

        if (this.flash) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(WHITE)
        }
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_previous: Area, current: Area): void => {
        this.landscape = Number(current.width) > Number(current.height)
      })
    }
    .hideTitleBar(true)
    .backgroundColor(Tk.D.bg)
    // 往栈上推图集 / 队列 / 设置**不会**销毁这一层，`aboutToDisappear` 不触发；
    // 不在这里放开相机，镜头就一直亮着（系统指示灯常亮、耗电、别的应用拿不到摄像头）。
    // `onShown` / `onHidden`：`component/nav_destination.d.ts:684,703`，@since 10。
    .onHidden((): void => {
      this.visible = false
      this.stopVideoAndStore()
      this.camera.close().catch((e: Object): void => {
        hilog.warn(DOMAIN, TAG, 'close on hidden failed: %{public}s', `${e}`)
      })
    })
    .onShown((): void => {
      this.visible = true
      this.showSilenceReminder()
      this.readPermissions()
      this.openCamera()
    })
  }

  // MARK: - 画面

  /**
   * 取景画面。`XComponent(type SURFACE)` 的 surface 交给相机当预览输出，
   * surfaceId 从 `XComponentController.getXComponentSurfaceId()`
   * （`sdk/.../component/xcomponent.d.ts:171`）在 `onLoad`（同上 :585）里取。
   */
  @Builder
  stage() {
    // 截图模式：模拟器没有相机，取景区贴一张静态现场照（debug-only，见 ScreenshotMode）
    if (this.mode !== CapMode.audio && ScreenshotMode.stagePath.length > 0) {
      Image(fileUri.getUriFromPath(ScreenshotMode.stagePath))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    } else if (this.mode !== CapMode.audio && this.hasCamera) {
      XComponent({ type: XComponentType.SURFACE, controller: this.xctl })
        .onLoad((): void => {
          this.surfaceId = this.xctl.getXComponentSurfaceId()
          this.openCamera()
        })
        .onDestroy((): void => {
          this.surfaceId = ''
          this.camera.close().catch((): void => {})
        })
        .onAreaChange((): void => this.camera.updatePreviewRotation())
        .width('100%')
        .height('100%')
    } else {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Tk.D.bg)
    }
  }

  /** 淡水印：时间到秒、项目名、坐标与精度。只叠加，不烧录。 */
  @Builder
  stamp() {
    Column({ space: Tk.Sp.s1 }) {
      ForEach(this.stampLines, (line: string): void => {
        Text(line)
          .fontSize(Tk.Ty.micro)
          .fontColor(Tk.D.fg)
          .opacity(0.7)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }, (line: string): string => line)
    }
    .alignItems(HorizontalAlign.Start)
  }

  /** 录音档没有取景画面：深色底，等宽计时器就是全部的界面。 */
  @Builder
  audioStage() {
    if (!this.hasMic) {
      this.permissionStage(tr('home.permission.mic'))
    } else {
      Column({ space: Tk.Sp.s3 }) {
        Text(this.elapsedText)
          .fontSize(Tk.Ty.hero)
          .fontColor(Tk.D.fg)
        Text(this.recordingAudio ? tr(this.recordingPaused ? 'rec.pause.status' : 'home.recording.audio') : tr('home.audio.hint'))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
        if (this.recordingAudio && !this.backgroundReminderAvailable) {
          Text(tr('rec.silence.backgroundUnavailable')).fontSize(Tk.Ty.nano).fontColor(Tk.D.fgMuted).textAlign(TextAlign.Center)
        }
        if (this.recordingAudio && this.voiceUnavailable && !this.recordingPaused) {
          Text(tr('rec.silence.unavailable')).fontSize(Tk.Ty.small).fontColor(Tk.D.fg).textAlign(TextAlign.Center)
        }
        if (this.recordingMessage.length > 0) {
          Text(this.recordingMessage)
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fg)
            .onClick((): void => { this.stack.pushPath(new NavPathInfo('Library', '')) })
        }
        if (!this.recordingAudio && this.recordingMessage.length > 0) {
          Text(tr('rec.retrySave')).height(Tk.touchMin).fontColor(Tk.D.fg)
            .onClick((): void => {
              RecorderService.shared.recoverDrafts().then((): Promise<void> => AppModel.shared.refresh())
            })
        }
        // 录音中说一句「退后台也在录」：用户开会时最怕的就是切出去一下就断了
        if (this.recordingAudio) {
          Text(tr(this.recordingPaused ? 'rec.pause.remember' : this.interrupted ? 'rec.paused.interrupted' : 'home.audio.backgroundOk'))
            .fontSize(Tk.Ty.nano)
            .fontColor(this.interrupted ? Tk.S.failed : Tk.D.fgMuted)
            .textAlign(TextAlign.Center)
        }
      }
      .alignItems(HorizontalAlign.Center)
    }
  }

  /** 权限缺失：说清楚缺什么，给一个能直接去开的入口。不在这里重复系统的措辞。 */
  @Builder
  permissionStage(title: string) {
    Column({ space: Tk.Sp.s3 }) {
      Text(title)
        .fontSize(Tk.Ty.heading)
        .fontColor(Tk.D.fg)
        .textAlign(TextAlign.Center)
      Text(tr('home.permission.open'))
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.S.movingOnDark)
        .height(Tk.touchMin)
        .onClick((): void => this.openSystemSettings())
    }
    .alignItems(HorizontalAlign.Center)
  }

  // MARK: - 顶栏

  @Builder
  topBar() {
    Column({ space: Tk.Sp.s1 }) {
      Row({ space: Tk.Sp.s1 }) {
        Text(tr('home.eyebrow'))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
          .layoutWeight(1)
        // 位置精度：没有精度的坐标在质证时说明不了问题，所以直接显示出来
        StatusDot({ color: this.locSnapshot === null ? Tk.D.rule : Tk.S.arrivedOnDark })
        Text(this.gpsText)
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
          .layoutWeight(2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (ServiceLocator.region === 'cn') {
          Text(tr('dd.title')).fontSize(Tk.Ty.nano).fontColor(Tk.D.fgMuted).height(Tk.touchMin)
            .onClick((): void => { this.stack.pushPath(new NavPathInfo('DdClient', '')) })
        }
        Text(tr('home.settings'))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
          .height(Tk.touchMin)
          .margin({ left: Tk.Sp.s3 })
          .onClick((): void => {
            this.stack.pushPath(new NavPathInfo('Settings', ''))
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.projectName)
        .onClick((): void => this.stack.pushPath(new NavPathInfo('ProjectPickerSwitch', '')))
        .fontSize(Tk.Ty.title)
        .fontColor(Tk.D.fg)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(tr('home.archiveTo',
        { 'path': tr('archive.path', { 'date': formatDay(ScreenshotMode.archiveMs(Date.now())) }) }))
        .fontSize(Tk.Ty.nano)
        .fontColor(Tk.D.fgMuted)
      Text(this.tallyText)
        .fontSize(Tk.Ty.nano)
        .fontColor(Tk.D.fgMuted)
        .height(Tk.touchMin)
        .onClick((): void => this.openQueue())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s2, bottom: Tk.Sp.s2 })
  }

  // MARK: - 底栏

  @Builder
  bottomBar() {
    Column({ space: Tk.Sp.s3 }) {
      if (this.recording()) {
        Row({ space: Tk.Sp.s1 }) {
          StatusDot({ color: this.recordingPaused ? Tk.D.fgMuted : Tk.S.failed, dotSize: 7 })
          Text(this.elapsedText)
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fg)
          Text(tr(this.recordingPaused ? 'rec.pause.status' : this.recordingVideo ? 'home.recording.video' : 'home.recording.audio'))
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.D.fgMuted)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        if (this.recordingPaused) {
          Text(tr('rec.pause.remember')).fontSize(Tk.Ty.small).fontColor(Tk.D.fg).textAlign(TextAlign.Center)
        }
        if (!this.landscape) { this.pauseControl() }
      } else {
        // 三档并排、点选切换。取证的档位必须显式可预期，不做横滑档位条，也不做快门手势
        // 切换——手滑录错档位是取证事故。
        Row({ space: Tk.Sp.s8 }) {
          this.modeButton(tr('home.mode.photo'), CapMode.photo)
          this.modeButton(tr('home.mode.video'), CapMode.video)
          this.modeButton(tr('home.mode.audio'), CapMode.audio)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }

      Row() {
        Column() {
          if (this.landscape && this.recording()) { this.pauseControl() }
          else { this.recentThumb() }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.shutter()

        Column({ space: Tk.Sp.s1 }) {
          Text(`${this.total}`)
            .fontSize(Tk.Ty.heading)
            .fontColor(Tk.D.fg)
          Text(tr('home.counter.project'))
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.D.fgMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.End)
        .onClick((): void => this.openQueue())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider().color(Tk.D.rule)

      Row({ space: Tk.Sp.s1 }) {
        StatusDot({ color: this.desktopOnline ? Tk.S.arrivedOnDark : Tk.D.rule })
        Text(this.desktopOnline ? tr('home.desktop.online') : tr('home.desktop.offline'))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s3, bottom: Tk.Sp.s2 })
  }

  @Builder
  modeButton(label: string, m: CapMode) {
    Column({ space: Tk.Sp.s1 }) {
      Text(label)
        .fontSize(Tk.Ty.small)
        .fontColor(this.mode === m ? Tk.D.fg : Tk.D.fgMuted)
      Row()
        .width(3)
        .height(3)
        .borderRadius(1.5)
        .backgroundColor(this.mode === m ? Tk.D.fg : TRANSPARENT)
    }
    .width(Tk.touchMin)
    .height(Tk.touchMin)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => this.switchMode(m))
  }

  @Builder
  pauseControl() {
    Button(tr(this.recordingPaused ? (this.recordingVideo ? 'rec.resume.video' : 'rec.resume.audio') :
      (this.recordingVideo ? 'rec.pause.video' : 'rec.pause.audio')))
      .fontColor(Tk.D.bg).backgroundColor(Tk.D.fg).height(Tk.touchMin)
      .enabled(!this.pauseBusy).onClick((): void => { this.togglePause() })
  }

  /** 快门。照片单击即拍；录像 / 录音单击切换开始与停止，录制中变红方块。 */
  @Builder
  shutter() {
    Stack() {
      if (this.recording()) {
        Row()
          .width(STOP_SIZE)
          .height(STOP_SIZE)
          .borderRadius(5)
          .backgroundColor(Tk.S.failed)
      } else {
        Row()
          .width(SHUTTER_INNER)
          .height(SHUTTER_INNER)
          .borderRadius(SHUTTER_INNER / 2)
          .backgroundColor(this.mode === CapMode.photo ? WHITE : Tk.S.failed)
      }
    }
    .width(SHUTTER_SIZE)
    .height(SHUTTER_SIZE)
    .borderRadius(SHUTTER_SIZE / 2)
    .borderWidth(2)
    .borderColor(Tk.D.fg)
    .accessibilityText(this.shutterLabel())
    .onClick((): void => this.shoot())
  }

  /** 最近一件的真缩略图，也是影像浏览的入口。 */
  @Builder
  recentThumb() {
    Stack() {
      if (!this.hasRecent) {
        Row()
          .width('100%')
          .height('100%')
          .borderWidth(1)
          .borderColor(Tk.D.rule)
      } else if (this.recentIsAudio) {
        Text('♪')
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.D.fgMuted)
          .width('100%')
          .height('100%')
          .textAlign(TextAlign.Center)
          .backgroundColor(Tk.D.surface)
      } else {
        Image(this.recentUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      }
    }
    .width(THUMB_SIZE)
    .height(THUMB_SIZE)
    .accessibilityText(tr('home.thumb'))
    .onClick((): void => {
      this.stack.pushPath(new NavPathInfo('Library', ''))
    })
  }

  // MARK: - 行为

  private centered(): boolean {
    return this.mode === CapMode.audio || !this.hasCamera
  }

  private recording(): boolean {
    return this.recordingVideo || this.recordingAudio
  }

  private shutterLabel(): string {
    if (this.recordingVideo) return tr('home.shutter.stopVideo')
    if (this.recordingAudio) return tr('home.shutter.stopAudio')
    if (this.mode === CapMode.photo) return tr('home.shutter.photo')
    return this.mode === CapMode.video ? tr('home.shutter.startVideo') : tr('home.shutter.startAudio')
  }

  private openQueue(): void {
    this.stack.pushPath(new NavPathInfo('Queue', ''))
  }

  /** 换档位。录像档与照片档共用同一个相机会话，只有录音档要把镜头放开。 */
  private switchMode(m: CapMode): void {
    if (this.mode === m || this.recording()) return
    this.mode = m
    if (m === CapMode.audio) {
      this.camera.close().catch((e: Object): void => {
        hilog.warn(DOMAIN, TAG, 'close for audio mode failed: %{public}s', `${e}`)
      })
    } else {
      this.openCamera()
    }
  }

  private openCamera(): void {
    if (!this.alive || !this.visible || !this.foreground || RecorderService.shared.state.isRecording || !this.hasCamera || this.mode === CapMode.audio || this.surfaceId.length === 0) return
    this.camera.open(this.surfaceId).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'open camera failed: %{public}s', `${e}`)
    })
  }

  private shoot(): void {
    if (RecorderService.shared.state.isRecording) {
      this.toggleAudio()
      return
    }
    // 顺手把定位续一次，供下一件用；这一件用的是已经在手上的那份快照，不等 GPS
    this.refreshLocation()
    if (this.mode === CapMode.photo) {
      this.takePhoto()
    } else if (this.mode === CapMode.video) {
      if (this.recordingVideo) this.stopVideoAndStore()
      else this.startVideo()
    } else {
      this.toggleAudio()
    }
  }

  private async togglePause(): Promise<void> {
    if (this.pauseBusy) return
    this.pauseBusy = true
    try {
      if (this.recordingVideo) {
        if (this.camera.isVideoPaused) await this.camera.resumeVideo()
        else await this.camera.pauseVideo()
        if (this.alive) this.recordingPaused = this.camera.isVideoPaused
        this.tick()
      } else if (this.recordingAudio) {
        if (RecorderService.shared.state.userPaused) await RecorderService.shared.resume()
        else await RecorderService.shared.pause()
      }
    } catch (_) {
      if (this.recordingVideo && !this.camera.isVideoPaused) this.stopVideoAndStore()
      if (this.alive) toast(this.getUIContext(), tr(this.camera.isVideoPaused ? 'rec.resume.videoFailed' : 'rec.interruption.saving'))
    } finally { if (this.alive) this.pauseBusy = false }
  }

  private showSilenceReminder(): void {
    const svc: RecorderService = RecorderService.shared
    if (!this.alive || !this.visible || !this.foreground || this.silenceDialog || !svc.state.silencePending) return
    const startedAt: number = svc.state.startedAt
    this.silenceDialog = true
    this.getUIContext().showAlertDialog({ title: tr('rec.silence.title'), message: tr('rec.silence.message'),
      autoCancel: false,
      primaryButton: { value: tr('rec.silence.continue'), action: (): void => {
        this.silenceDialog = false
        if (svc.state.startedAt === startedAt) svc.continueAfterSilence()
      } },
      secondaryButton: { value: tr('rec.silence.stop'), action: (): void => {
        this.silenceDialog = false
        if (svc.state.startedAt === startedAt) svc.stop()
      } },
    })
  }

  private takePhoto(): void {
    if (!this.hasCamera) return
    // 采集时刻、项目、位置都在按下的这一瞬定死：落库是异步的，中途切了项目，
    // 这一件该记的仍是按下快门时屏幕上显示的那个（与录音路径同口径）
    const at: number = Date.now()
    const loc: Loc | null = this.locSnapshot
    const target: RelayProject | null = AppModel.shared.selectedProject
    this.flash = true
    if (this.flashId >= 0) clearTimeout(this.flashId)
    this.flashId = setTimeout((): void => {
      this.flashId = -1
      if (!this.alive) return
      this.flash = false
    }, FLASH_MS)
    this.camera.takePhoto().then((path: string): Promise<CaptureItem> =>
      AppModel.shared.store(MediaKind.photo, path, at, loc, target)
    ).catch((e: Object): void => {
      // 相机被拆（退后台、切档位）导致的失败是用户自己的动作，记一句就够，不打扰
      if (isCameraClosed(e)) {
        hilog.info(DOMAIN, TAG, '%{public}s', 'capture dropped: camera closed')
        return
      }
      hilog.error(DOMAIN, TAG, 'takePhoto failed: %{public}s', `${e}`)
      if (!this.alive) return
      toast(this.getUIContext(), errorText(e))
    })
  }

  private startVideo(): void {
    // 项目与位置在按下开录的这一瞬快照，停录时用它落库——录像可能录几分钟，
    // 中途从设置里换了项目也不该把这一段搬到别人的电脑上去
    const target: RelayProject | null = AppModel.shared.selectedProject
    const loc: Loc | null = this.locSnapshot
    this.camera.startVideo().then((): void => {
      this.videoProject = target
      this.videoLoc = loc
      if (!this.alive) return
      this.recordingVideo = true
      this.recordingPaused = false
      this.tick()
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'startVideo failed: %{public}s', `${e}`)
      if (!this.alive) return
      toast(this.getUIContext(), errorText(e))
    })
  }

  /** 在录的录像停下并落库。退后台、这一屏被换掉、用户按停走的是同一条路。 */
  private stopVideoAndStore(): void {
    if (!this.camera.isRecordingVideo) return
    const at: number = this.camera.videoStartedAt
    const loc: Loc | null = this.videoLoc
    const target: RelayProject | null = this.videoProject
    this.videoLoc = null
    this.videoProject = null
    if (this.alive) { this.recordingVideo = false; this.recordingPaused = false }
    this.camera.stopVideo().then((path: string): Promise<CaptureItem> =>
      AppModel.shared.store(MediaKind.video, path, at, loc, target)
    ).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'stopVideo failed: %{public}s', `${e}`)
    })
  }

  private toggleAudio(): void {
    const svc: RecorderService = RecorderService.shared
    if (svc.state.isRecording) {
      svc.stop().catch((e: Object): void => {
        hilog.error(DOMAIN, TAG, 'stop recording failed: %{public}s', `${e}`)
      })
      return
    }
    if (!this.hasMic) return
    svc.start(AppModel.shared.selectedProject, this.locSnapshot).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'start recording failed: %{public}s', `${e}`)
    })
  }

  // MARK: - 权限

  private readPermissions(): void {
    this.hasCamera = hasPermission(PERM_CAMERA)
    this.hasMic = hasPermission(PERM_MICROPHONE)
    this.hasLocation = hasPermission(PERM_LOCATION) || hasPermission(PERM_APPROX_LOCATION)
    this.refreshGps()
    this.restartLocating()
  }

  /** 没有定位权限就直说缺什么，别让人对着一个永远「定位中」的芯片猜。 */
  private refreshGps(): void {
    this.gpsText = this.hasLocation ? gpsChip(this.locSnapshot) : tr('home.permission.location')
  }

  /**
   * 一次问齐相机、麦克风、定位。分三次问会让人在按快门前连点三个对话框，现场最烦这个。
   * `requestPermissionsFromUser`：`@ohos.abilityAccessCtrl.d.ts:340`。
   */
  private askPermissions(): void {
    const wanted: Permissions[] = [PERM_CAMERA, PERM_MICROPHONE, PERM_APPROX_LOCATION, PERM_LOCATION]
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ServiceLocator.ctx, wanted)
      .then((res: PermissionRequestResult): void => {
        hilog.info(DOMAIN, TAG, 'permissions answered: %{public}d', res.authResults.length)
        if (!this.alive) return
        this.readPermissions()
        this.openCamera()
      })
      .catch((e: Object): void => {
        hilog.warn(DOMAIN, TAG, 'requestPermissionsFromUser failed: %{public}s', `${e}`)
      })
  }

  /**
   * 去系统里开权限。走 `startAbility` 的设置页 want 而不是 `settings.openAppDetailSettingsPage`：
   * 后者是 API 26 才有的（`@ohos.settings.d.ts:1383`），而本工程的
   * `compatibleSdkVersion` 是 5.0.0(12)，在存量机上会直接抛。
   */
  private openSystemSettings(): void {
    const params: Record<string, Object> = { 'pushParams': ServiceLocator.ctx.applicationInfo.name }
    const want: Want = {
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
      uri: 'application_info_entry',
      parameters: params,
    }
    const ctx: common.UIAbilityContext = ServiceLocator.ctx as common.UIAbilityContext
    ctx.startAbility(want).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'open settings failed: %{public}s', `${e}`)
    })
  }

  // MARK: - 定位

  private restartLocating(): void {
    this.stopLocating()
    if (!this.hasLocation) return
    this.refreshLocation()
    this.locateId = setInterval((): void => this.refreshLocation(), LOCATE_MS)
  }

  private stopLocating(): void {
    if (this.locateId < 0) return
    clearInterval(this.locateId)
    this.locateId = -1
  }

  /** 拿不到新定位就留着上一次的，不清空——上一次的坐标仍然说明「在这栋楼」。 */
  private refreshLocation(): void {
    this.stamper.current().then((at: Loc | null): void => {
      if (at === null || !this.alive) return
      this.locSnapshot = at
      this.refreshGps()
      this.refreshStamp()
    }).catch((e: Object): void => {
      hilog.info(DOMAIN, TAG, 'locate skipped: %{public}s', `${e}`)
    })
  }

  // MARK: - 同步

  private tick(): void {
    this.refreshStamp()
    if (this.recordingVideo) {
      this.elapsedText = formatClock(this.camera.videoClock.elapsed(Date.now()))
    }
  }

  private refreshStamp(): void {
    this.stampLines = watermarkLines(
      ScreenshotMode.archiveMs(Date.now()), this.projectName, this.locSnapshot)
  }

  private syncModel(): void {
    const model: AppModel = AppModel.shared
    const p: RelayProject | null = model.selectedProject
    this.projectName = p === null ? tr('library.unknownProject') : p.name
    const tally: Tally = model.tally()
    this.total = tally.total
    this.tallyText = tallySummary(tally)
    this.desktopOnline = model.desktopOnline()
    const items: CaptureItem[] = model.currentItems()
    this.hasRecent = items.length > 0
    if (items.length > 0) {
      const first: CaptureItem = items[0]
      this.recentIsAudio = first.kind === MediaKind.audio
      this.recentUri = first.kind === MediaKind.audio ? '' : fileUri.getUriFromPath(first.localPath)
    } else {
      this.recentIsAudio = false
      this.recentUri = ''
    }
    this.refreshStamp()
  }

  private syncRecording(): void {
    const st: RecordingState = RecorderService.shared.state
    this.recordingMessage = st.message
    this.recordingAudio = st.isRecording
    this.voiceUnavailable = st.voiceUnavailable
    this.backgroundReminderAvailable = st.backgroundReminderAvailable
    if (!this.recordingVideo) this.recordingPaused = st.userPaused
    if (st.isRecording) this.mode = CapMode.audio
    this.interrupted = st.interrupted
    if (st.isRecording || !this.recordingVideo) this.elapsedText = formatClock(st.elapsedSec)
    this.showSilenceReminder()
  }
}

/** 三桶计数一句话。失败件不单列一桶，它是「上传中」桶里的异常，追加在上传中后面。 */
function tallySummary(t: Tally): string {
  const failed: string = t.failed > 0 ? tr('tally.summary.failedPart', { 'm': t.failed }) : ''
  return tr('tally.summary', { 'u': t.uploading, 'f': failed, 's': t.staged, 'l': t.landed })
}
