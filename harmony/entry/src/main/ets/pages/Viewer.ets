import { fileUri } from '@kit.CoreFileKit'
import { AppModel } from '../AppModel'
import { GlassBar, StatusDot } from '../design/Components'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { CaptureItem, MediaKind } from '../model/Capture'
import { formatClock, formatDay, formatHms } from '../model/Format'
import { TransferStateOps } from '../model/TransferState'
import { RecorderService } from '../services/RecorderService'
import { ViewerRequest } from './ViewerRequest'

/** 录音快进 / 快退一步的秒数。 */
const SKIP_SECONDS: number = 15
const MAX_ZOOM: number = 5
const DOUBLE_TAP_ZOOM: number = 2.5
const BLACK: string = '#000000'

/**
 * 全屏看大图。左右滑同一天的其他件；照片可缩放，录像与录音交给系统播放器。
 * 只放核对要用的东西：状态、失败原因、时刻、日期 · 类型、项目；哈希放在「记录详情」里（质证要用时可复制）。不做编辑、不做分享——
 * 取证件不该从这一屏流出去。镜像安卓 `ViewerScreen.kt` 与 iOS `ViewerView`。
 *
 * 要看哪一段由 `ViewerRequest` 带进来（只带 id 与起点），条目每次从 `AppModel.items` 取，
 * 所以上传状态在这一屏上是活的，不是一份打开时的快照。
 */
@Component
export struct Viewer {
  stack: NavPathStack = new NavPathStack()

  @State items: CaptureItem[] = []
  @State index: number = 0
  /** 照片缩放。翻页时复位——上一张放大着，下一张进来也是放大的会让人以为拍糊了。 */
  @State zoom: number = 1
  private pinchBase: number = 1
  @State showingDetails: boolean = false
  /** 录音播放：进度条与 ±15 秒由我们自己画，`Video` 只负责出声。 */
  @State audioTime: number = 0
  @State audioDuration: number = 0
  @State audioPlaying: boolean = false
  private audioController: VideoController = new VideoController()
  private token: number = -1

  aboutToAppear(): void {
    this.index = ViewerRequest.index >= 0 ? ViewerRequest.index : 0
    this.token = AppModel.shared.subscribe((): void => this.syncModel())
    this.syncModel()
  }

  aboutToDisappear(): void {
    if (this.token >= 0) AppModel.shared.unsubscribe(this.token)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          Swiper() {
            ForEach(this.items, (it: CaptureItem, i: number): void => {
              this.page(it, i)
            }, (it: CaptureItem): string => it.id)
          }
          .index(this.index)
          .loop(false)
          .indicator(false)
          .width('100%')
          .height('100%')
          .onChange((i: number): void => {
            this.index = i
            this.zoom = 1
            this.pinchBase = 1
            this.audioTime = 0
            this.audioDuration = 0
            this.audioPlaying = false
          })
        }
        .width('100%')
        .height('100%')

        // 顶栏与底座压在画面上下沿。整层 Transparent：中间那片空白不吃触摸，
        // 缩放与翻页仍然落在下面的画面上
        Column() {
          GlassBar() {
            this.topBar()
          }
          Column()
            .layoutWeight(1)
            .width('100%')
          GlassBar() {
            this.bottomBar()
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(BLACK)
  }

  // MARK: - 画面

  /**
   * 一页。照片双指缩放、双击在 1x 与 2.5x 之间切换；录像与录音都交给 `Video`——
   * 录音没有画面，只出控制条（占位底色 + 音符）。
   *
   * 播放器只在当前页建：几段 1080p 同时解码会把解码器占满。
   */
  @Builder
  page(item: CaptureItem, i: number) {
    Stack() {
      if (item.kind === MediaKind.photo) {
        Image(fileUri.getUriFromPath(item.localPath))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .scale({ x: this.zoom, y: this.zoom })
          .gesture(GestureGroup(GestureMode.Parallel,
            PinchGesture()
              .onActionStart((): void => {
                this.pinchBase = this.zoom
              })
              .onActionUpdate((e: GestureEvent): void => {
                this.zoom = clampZoom(this.pinchBase * e.scale)
              }),
            TapGesture({ count: 2 })
              .onAction((): void => {
                this.zoom = this.zoom > 1 ? 1 : DOUBLE_TAP_ZOOM
                this.pinchBase = this.zoom
              })))
      } else if (this.index === i) {
        if (RecorderService.shared.state.isRecording) {
          Text(tr('player.stopRecordingFirst')).fontColor(Tk.D.fg)
        } else if (item.kind === MediaKind.audio) {
          this.audioPage(item)
        } else {
          Video({ src: fileUri.getUriFromPath(item.localPath) })
            .controls(true)
            .autoPlay(false)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BLACK)
  }

  /**
   * 录音页：音符 + 可拖的进度条（左已播、右总长）+ 后退 15 秒 / 播放暂停 / 前进 15 秒。
   * `Video` 不出控制条、只占 1vp，声音照出；录像仍用 `Video` 自带的可拖进度条。
   */
  @Builder
  audioPage(item: CaptureItem) {
    Column({ space: Tk.Sp.s4 }) {
      Text('♪')
        .fontSize(Tk.Ty.hero)
        .fontColor(Tk.D.fgMuted)
        .textAlign(TextAlign.Center)
      Video({ src: fileUri.getUriFromPath(item.localPath), controller: this.audioController })
        .controls(false)
        .autoPlay(false)
        .width(1)
        .height(1)
        .onPrepared((e: PreparedInfo): void => { this.audioDuration = e.duration })
        .onUpdate((e: PlaybackInfo): void => { this.audioTime = e.time })
        .onStart((): void => { this.audioPlaying = true })
        .onPause((): void => { this.audioPlaying = false })
        .onFinish((): void => { this.audioPlaying = false })
      Slider({ value: this.audioTime, min: 0, max: this.audioDuration > 0 ? this.audioDuration : 1, step: 0.1 })
        .width('100%')
        .enabled(this.audioDuration > 0)
        .selectedColor(Tk.D.fg)
        .trackColor(Tk.D.fgMuted)
        .onChange((value: number, mode: SliderChangeMode): void => {
          this.audioTime = value
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.seekAudio(value)
        })
      // 时间保持 LTR（RTL 语言下也不翻转）
      Row() {
        Text(formatClock(this.audioTime)).fontSize(Tk.Ty.micro).fontColor(Tk.D.fgMuted)
        Blank()
        Text(formatClock(this.audioDuration)).fontSize(Tk.Ty.micro).fontColor(Tk.D.fgMuted)
      }
      .width('100%')
      .direction(Direction.Ltr)
      Row({ space: Tk.Sp.s8 }) {
        Text('-' + SKIP_SECONDS)
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.D.fg)
          .width(Tk.touchMin)
          .height(Tk.touchMin)
          .textAlign(TextAlign.Center)
          .accessibilityText(tr('player.back15'))
          .onClick((): void => this.seekAudio(this.audioTime - SKIP_SECONDS))
        Text(this.audioPlaying ? '❚❚' : '▶\uFE0E')
          .fontSize(Tk.Ty.title)
          .fontColor(Tk.D.fg)
          .width(Tk.touchMin)
          .height(Tk.touchMin)
          .textAlign(TextAlign.Center)
          .accessibilityText(tr(this.audioPlaying ? 'player.pause' : 'player.play'))
          .onClick((): void => {
            if (this.audioPlaying) this.audioController.pause()
            else this.audioController.start()
          })
        Text('+' + SKIP_SECONDS)
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.D.fg)
          .width(Tk.touchMin)
          .height(Tk.touchMin)
          .textAlign(TextAlign.Center)
          .accessibilityText(tr('player.forward15'))
          .onClick((): void => this.seekAudio(this.audioTime + SKIP_SECONDS))
      }
      .justifyContent(FlexAlign.Center)
      .direction(Direction.Ltr)
    }
    .width('100%')
    .height('100%')
    .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter })
    .justifyContent(FlexAlign.Center)
  }

  // MARK: - 顶栏与底座

  @Builder
  topBar() {
    Row({ space: Tk.Sp.s2 }) {
      Text('✕')
        .fontSize(Tk.Ty.body)
        .fontColor(Tk.D.fg)
        .width(Tk.touchMin)
        .height(Tk.touchMin)
        .textAlign(TextAlign.Center)
        .accessibilityText(tr('common.close'))
        .onClick((): void => {
          this.stack.pop()
        })
      Text(this.pageLabel())
        .fontSize(Tk.Ty.micro)
        .fontColor(Tk.D.fgMuted)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
      Text('ⓘ')
        .fontSize(Tk.Ty.body)
        .fontColor(this.showingDetails ? Tk.D.fg : Tk.D.fgMuted)
        .width(Tk.touchMin)
        .height(Tk.touchMin)
        .textAlign(TextAlign.Center)
        .accessibilityText(tr('viewer.details'))
        .onClick((): void => { this.showingDetails = !this.showingDetails })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Tk.Sp.s2, right: Tk.Sp.gutter })
  }

  @Builder
  bottomBar() {
    Column({ space: Tk.Sp.s1 }) {
      Row({ space: Tk.Sp.s1 }) {
        StatusDot({ color: this.dotColor() })
        Text(this.detail())
          .fontSize(Tk.Ty.small)
          .fontColor(Tk.D.fg)
        Text(this.time())
          .fontSize(Tk.Ty.micro)
          .fontColor(Tk.D.fgMuted)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 失败原因不折起来：它是用户唯一能据以判断「要不要重传」的东西
      if (this.failure().length > 0) {
        Text(this.failure())
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.S.failed)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Row({ space: Tk.Sp.s2 }) {
        Text(this.dateKind())
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
        Text(this.projectName())
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.showingDetails) {
        this.details()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s2, bottom: Tk.Sp.s3,
    })
  }

  /** 记录详情：拍摄时间、位置（±精度）、设备、文件指纹。都可长按复制。 */
  @Builder
  details() {
    Column({ space: Tk.Sp.s2 }) {
      this.detailRow(tr('details.capturedAt'), this.capturedAt(), false)
      if (this.location().length > 0) {
        this.detailRow(tr('details.location'), this.location(), false)
      }
      this.detailRow(tr('details.device'), this.device(), false)
      // 文件指纹：质证时证明文件未被改动；平时用不到，所以只放在详情里
      this.detailRow(tr('details.fingerprint'), this.fingerprint(), true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: Tk.Sp.s2 })
  }

  @Builder
  detailRow(label: string, value: string, mono: boolean) {
    Column({ space: Tk.Sp.s1 }) {
      Text(label)
        .fontSize(Tk.Ty.nano)
        .fontColor(Tk.D.fgMuted)
      if (mono) {
        // 哈希保持 LTR（RTL 语言下也不翻转）
        Text(value)
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fg)
          .fontFamily('monospace')
          .direction(Direction.Ltr)
          .copyOption(CopyOptions.LocalDevice)
      } else {
        Text(value)
          .fontSize(Tk.Ty.small)
          .fontColor(Tk.D.fg)
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // MARK: - 当前这一件

  private current(): CaptureItem | null {
    if (this.items.length === 0) return null
    const i: number = this.index < 0 ? 0 : (this.index >= this.items.length ? this.items.length - 1 : this.index)
    return this.items[i]
  }

  /** 不叫 position：与 CustomComponent 的通用属性方法重名，编不过。 */
  private pageLabel(): string {
    return this.items.length === 0 ? '' : `${this.index + 1} / ${this.items.length}`
  }

  private dotColor(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? Tk.D.rule : Tk.color(TransferStateOps.dotToken(it.state), true)
  }

  private detail(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? '' : TransferStateOps.detail(it.state)
  }

  private failure(): string {
    const it: CaptureItem | null = this.current()
    if (it === null) return ''
    const err: string | null = it.lastError
    return err === null ? '' : err
  }

  /** 「日期 · 类型」：取代原来的哈希前缀。 */
  private dateKind(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? '' : formatDay(it.capturedAtMs()) + ' · ' + kindLabel(it.kind)
  }

  private capturedAt(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? '' : formatDay(it.capturedAtMs()) + ' ' + formatHms(it.capturedAtMs())
  }

  private location(): string {
    const it: CaptureItem | null = this.current()
    if (it === null || it.manifest.latitude === undefined || it.manifest.longitude === undefined) return ''
    const acc: number | undefined = it.manifest.horizontalAccuracy
    return `${it.manifest.latitude.toFixed(5)}, ${it.manifest.longitude.toFixed(5)}` + (acc === undefined ? '' : ` ±${Math.round(acc)}m`)
  }

  private device(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? '' : it.manifest.deviceModel
  }

  private fingerprint(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? '' : it.manifest.sha256
  }

  private seekAudio(seconds: number): void {
    const max: number = this.audioDuration
    const target: number = seconds < 0 ? 0 : (seconds > max ? max : seconds)
    this.audioTime = target
    this.audioController.setCurrentTime(target, SeekMode.Accurate)
  }

  private time(): string {
    const it: CaptureItem | null = this.current()
    return it === null ? '' : formatHms(it.capturedAtMs())
  }

  private projectName(): string {
    const it: CaptureItem | null = this.current()
    if (it === null) return ''
    return it.project === null ? tr('library.unknownProject') : it.project.name
  }

  /**
   * 按 id 从库里取当前的那一份。中途被删掉的件会从这一段里消失，
   * 索引跟着夹回范围内——不留一个指着空处的页码。
   */
  private syncModel(): void {
    const all: CaptureItem[] = AppModel.shared.items
    const picked: CaptureItem[] = []
    for (const id of ViewerRequest.ids) {
      for (const it of all) {
        if (it.id === id) picked.push(it)
      }
    }
    this.items = picked
    if (picked.length === 0) {
      this.index = 0
    } else if (this.index >= picked.length) {
      this.index = picked.length - 1
    }
  }
}

function clampZoom(v: number): number {
  if (v < 1) return 1
  return v > MAX_ZOOM ? MAX_ZOOM : v
}

function kindLabel(kind: MediaKind): string {
  if (kind === MediaKind.photo) return tr('home.mode.photo')
  return kind === MediaKind.video ? tr('home.mode.video') : tr('home.mode.audio')
}
