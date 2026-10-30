import { fileUri } from '@kit.CoreFileKit'
import { Prefs } from '../services/Prefs'
import { CaptureOrganization } from '../services/ApiTypes'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppModel } from '../AppModel'
import { StatusDot } from '../design/Components'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { CaptureItem, MediaKind, RelayProject } from '../model/Capture'
import { formatHm } from '../model/Format'
import { EXPIRY_WARN_DAYS, expiryDaysLeft } from '../model/QueueExpiry'
import { TransferPhase, TransferState, TransferStateOps } from '../model/TransferState'
import { ServiceLocator } from '../services/ServiceLocator'

const DOMAIN: number = 0x0000
const TAG: string = 'Queue'

/**
 * 开着队列页时每 20 秒问一次投递回执——「已暂存」翻成「已落盘」的那一下应该发生在
 * 用户眼前，而不是下次冷启动。与安卓 `QueueScreen.kt` 同值。
 */
const POLL_MS: number = 20000
/** 行缩略图边长。 */
const ROW_THUMB: number = 56
/** 哈希只给前 12 位：够核对，又不至于把一行撑爆。 */
const SHA_PREFIX: number = 12
/** 进度条永远给一点起始宽度：0% 的条看起来像卡死了，实际是刚开始。 */
const PROGRESS_FLOOR: number = 5
/** 进度按 5% 一档进键——键变才重画，逐字节刷新只会让缩略图闪。 */
const PROGRESS_STEP: number = 5
const PROGRESS_BAR_HEIGHT: number = 2
const EMPTY: string = ''

/**
 * 一行要画的东西，全部先算好。
 *
 * ForEach 只认键：键不变就复用旧组件，行里的值再怎么变都不上屏——而这一页的全部意义
 * 就在于让状态在用户眼前翻过去。所以把状态、进度、到期提醒都编进 `key`，
 * 让「内容变了」等价于「键变了」。
 */
interface QueueRowVM {
  key: string
  isAudio: boolean
  localPath: string
  dotColor: string
  detail: string
  time: string
  showProgress: boolean
  progress: number
  /** 失败原因；无则空串。 */
  error: string
  /** 到期提醒；不该提醒时空串。 */
  expires: string
  sha: string
  organization: string
}

/** 一段。`key` 含全部行键，段内任何一行变了整段重画——队列不长，这点代价换确定性。 */
interface QueueSection {
  key: string
  title: string
  count: number
  tint: string
  rows: QueueRowVM[]
}

/**
 * 上传队列。存在的理由只有一个：**出事的时候能看懂、能自救。**
 * 只给一个红点，用户既不知道该重试还是该找人，也不知道是自己网络的问题还是我们的问题。
 *
 * 只列当前项目——进度跟着项目走。别的项目的未落盘件在末尾提一句，不完全藏起来。
 * 镜像安卓 `QueueScreen.kt` 与 iOS `QueueView`。
 */
@Component
export struct Queue {
  stack: NavPathStack = new NavPathStack()

  @State sections: QueueSection[] = []
  @State total: number = 0
  @State canRetryAll: boolean = false
  @State otherPending: number = 0
  @State projectName: string = EMPTY
  /**
   * 回执带回来的中转区到期时刻（键 clientMediaId 小写）。不放 @State：Map 的内容变化
   * V1 观察不到，改完统一走 syncModel 重算分段，靠键换新触发刷新。
   */
  private expiry: Map<string, string> = new Map<string, string>()
  private token: number = -1
  private pollId: number = -1
  /** 这一屏还在不在。异步回调回来时组件可能已经销毁，往里写 @State 是错误日志甚至崩溃。 */
  private alive: boolean = false
  private organizationScope: string = ''

  aboutToAppear(): void {
    this.alive = true
    ServiceLocator.session.current().then((sid: string | null): void => {
      if (!this.alive) return
      this.organizationScope = Prefs.organizationScope(ServiceLocator.baseUrl(), sid)
      this.syncModel()
    }).catch((): void => {})
    this.token = AppModel.shared.subscribe((): void => this.syncModel())
    this.syncModel()
    // 进页面先问一次，再按 20 秒续问：用户是带着「到底传没传到」的疑问推开这一页的
    this.poll()
    this.pollId = setInterval((): void => this.poll(), POLL_MS)
  }

  aboutToDisappear(): void {
    this.alive = false
    if (this.token >= 0) AppModel.shared.unsubscribe(this.token)
    if (this.pollId >= 0) {
      clearInterval(this.pollId)
      this.pollId = -1
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.topBar()

        List() {
          ForEach(this.sections, (s: QueueSection): void => {
            ListItemGroup({ header: this.sectionHeader(s) }) {
              ForEach(s.rows, (r: QueueRowVM): void => {
                ListItem() {
                  this.row(r)
                }
              }, (r: QueueRowVM): string => r.key)
            }
            .divider({ strokeWidth: 1, color: Tk.L.rule })
          }, (s: QueueSection): string => s.key)

          if (this.total === 0) {
            ListItem() {
              Text(tr('library.empty'))
                .fontSize(Tk.Ty.body)
                .fontColor(Tk.L.fg)
                .margin({ top: Tk.Sp.s16 })
            }
          }
          // 队列只看当前项目，但别的项目的未落盘件不能完全藏起来——至少说一声有多少
          if (this.otherPending > 0) {
            ListItem() {
              Text(tr('library.otherPending', { 'n': this.otherPending }))
                .fontSize(Tk.Ty.nano)
                .fontColor(Tk.L.fgFaint)
                .margin({ top: Tk.Sp.s6, bottom: Tk.Sp.s4 })
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter, bottom: Tk.Sp.s2 })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(Tk.L.bg)
  }

  // MARK: - 顶栏

  @Builder
  topBar() {
    Column() {
      Row({ space: Tk.Sp.s2 }) {
        Text('✕')
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.L.fg)
          .width(Tk.touchMin)
          .height(Tk.touchMin)
          .textAlign(TextAlign.Center)
          .accessibilityText(tr('common.close'))
          .onClick((): void => {
            this.stack.pop()
          })

        Column() {
          Text(tr('queue.title'))
            .fontSize(Tk.Ty.heading)
            .fontColor(Tk.L.fg)
          if (this.projectName.length > 0) {
            Text(this.projectName)
              .fontSize(Tk.Ty.nano)
              .fontColor(Tk.L.fgFaint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 失败段有件才给这一下：没有可重试的东西时，一个可点的「全部重试」只让人怀疑自己漏看了
        if (this.canRetryAll) {
          Text(tr('queue.retryAll'))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.L.accent)
            .height(Tk.touchMin)
            .padding({ left: Tk.Sp.s2, right: Tk.Sp.s2 })
            .onClick((): void => this.retryAll())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: Tk.Sp.s2, right: Tk.Sp.gutter, bottom: Tk.Sp.s2 })

      Divider().color(Tk.L.rule)
    }
    .width('100%')
  }

  // MARK: - 分段

  /** 段头。件数放右边：`queue.section.*` 里没有 {n} 占位，不在端上手拼中文。 */
  @Builder
  sectionHeader(s: QueueSection) {
    Row() {
      Text(s.title)
        .fontSize(Tk.Ty.nano)
        .fontColor(Tk.L.fgMuted)
        .layoutWeight(1)
      Text(`${s.count}`)
        .fontSize(Tk.Ty.small)
        .fontColor(s.tint)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Tk.L.bg)
    .padding({ top: Tk.Sp.s6, bottom: Tk.Sp.s2 })
  }

  // MARK: - 行

  @Builder
  row(r: QueueRowVM) {
    Row({ space: Tk.Sp.s3 }) {
      Stack() {
        this.thumb(r)
      }
      .width(ROW_THUMB)
      .height(ROW_THUMB)
      .backgroundColor(Tk.L.sunken)

      Column({ space: Tk.Sp.s1 }) {
        Row({ space: Tk.Sp.s1 }) {
          StatusDot({ color: r.dotColor })
          Text(r.detail)
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.L.fg)
            .layoutWeight(1)
          Text(r.time)
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.L.fgFaint)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (r.showProgress) {
          Progress({ value: r.progress, total: 100, type: ProgressType.Linear })
            .color(Tk.S.moving)
            .backgroundColor(Tk.L.sunken)
            .height(PROGRESS_BAR_HEIGHT)
            .width('100%')
        }

        // 失败原因照实显示。区分「你的网络」与「我们这边」，用户才知道是该换个地方重试还是该找人
        if (r.organization.length > 0) { Text(r.organization).fontSize(Tk.Ty.nano).fontColor(Tk.L.fgFaint) }
        if (r.error.length > 0) {
          Text(r.error)
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.L.fgMuted)
        }

        // 中转区不是网盘：到期未被桌面端取走就会被清理。只在还剩不到三天时说话
        if (r.expires.length > 0) {
          Text(r.expires)
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.S.waiting)
        }

        // 哈希前 12 位。要核对时不用进详情页
        Text(r.sha)
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.L.fgFaint)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: Tk.Sp.s3, bottom: Tk.Sp.s3 })
  }

  /** 缩略图。录音没有画面，用音符占位。 */
  @Builder
  thumb(r: QueueRowVM) {
    if (r.isAudio) {
      Text('♪')
        .fontSize(Tk.Ty.body)
        .fontColor(Tk.L.fgMuted)
        .width('100%')
        .height('100%')
        .textAlign(TextAlign.Center)
    } else {
      Image(fileUri.getUriFromPath(r.localPath))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    }
  }

  // MARK: - 行为

  private retryAll(): void {
    ServiceLocator.queue.retryFailed().catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'retryFailed failed: %{public}s', `${e}`)
    })
  }

  /** 回执查询失败静默——它只是状态汇报，不该产生任何打扰。 */
  private poll(): void {
    ServiceLocator.queue.checkDelivered().then((m: Map<string, string>): void => {
      // 20 秒的轮询发出去之后用户随时可能退这一页，回来时组件已经销毁
      if (!this.alive) return
      this.expiry = m
      this.syncModel()
    }).catch((e: Object): void => {
      hilog.info(DOMAIN, TAG, 'checkDelivered skipped: %{public}s', `${e}`)
    })
  }

  // MARK: - 同步

  /**
   * 把模型摊成四段视图数据。分桶走契约的 `phaseOf`，只把 `failed` 单独摘出来——
   * 契约把失败也归在 uploading 这一相里，但用户要先看到「需要处理」的那一堆。
   */
  private syncModel(): void {
    const model: AppModel = AppModel.shared
    const scoped: CaptureItem[] = model.currentItems()
    const failed: CaptureItem[] = []
    const active: CaptureItem[] = []
    const staged: CaptureItem[] = []
    const landed: CaptureItem[] = []
    for (const it of scoped) {
      if (it.state === TransferState.failed) {
        failed.push(it)
        continue
      }
      const phase: TransferPhase = TransferStateOps.phaseOf(it.state)
      if (phase === TransferPhase.uploading) active.push(it)
      else if (phase === TransferPhase.staged) staged.push(it)
      else landed.push(it)
    }

    const now: number = Date.now()
    const built: QueueSection[] = []
    this.pushSection(built, tr('queue.section.failed'), Tk.S.failed, failed, now)
    this.pushSection(built, tr('queue.section.uploading'), Tk.S.waiting, active, now)
    this.pushSection(built, tr('queue.section.staged'), Tk.S.moving, staged, now)
    this.pushSection(built, tr('queue.section.landed'), Tk.S.arrived, landed, now)

    this.sections = built
    this.total = scoped.length
    this.canRetryAll = failed.length > 0
    this.otherPending = model.otherPending()
    const p: RelayProject | null = model.selectedProject
    this.projectName = p === null ? EMPTY : p.name
  }

  /** 空段不画——四段全画会让「失败」段在最需要被看见的时候排在一堆空标题里。 */
  private pushSection(into: QueueSection[], title: string, tint: string,
    items: CaptureItem[], now: number): void {
    if (items.length === 0) return
    const rows: QueueRowVM[] = items.map((i: CaptureItem): QueueRowVM => this.rowOf(i, now))
    const keys: string[] = rows.map((r: QueueRowVM): string => r.key)
    const section: QueueSection = {
      key: `${title}#${keys.join(',')}`,
      title: title,
      count: items.length,
      tint: tint,
      rows: rows,
    }
    into.push(section)
  }

  private rowOf(item: CaptureItem, now: number): QueueRowVM {
    const uploading: boolean = item.state === TransferState.uploading
    const progress: number = uploading ? this.progressOf(item) : 0
    const error: string = item.state === TransferState.failed && item.lastError !== null
      ? item.lastError : EMPTY
    const expires: string = this.expiryNotice(item, now)
    const result: CaptureOrganization | undefined = ServiceLocator.prefs.organizationResult(this.organizationScope, item.manifest.clientMediaId)
    let organization: string = ''
    if (result !== undefined) {
      const key: string = result.state === 'ready' ? 'ready' : result.state === 'needs_review' ? 'review' : result.state === 'unknown' ? 'unknown' : 'notApplied'
      organization = tr('organize.' + key)
      if (result.state === 'ready') organization += ' · ' + (result.archiveName ?? result.fileName ?? '')
      if (result.tags.length > 0) organization += ' · ' + result.tags.join(' · ')
    }
    const row: QueueRowVM = {
      key: `${item.id}|${item.state}|${progress}|${error}|${expires}|${organization}`,
      isAudio: item.kind === MediaKind.audio,
      localPath: item.localPath,
      dotColor: Tk.color(TransferStateOps.dotToken(item.state), false),
      detail: uploading ? tr('organize.uploading') : TransferStateOps.detail(item.state),
      organization: organization,
      time: formatHm(item.capturedAtMs()),
      showProgress: uploading,
      progress: progress,
      error: error,
      expires: expires,
      sha: item.manifest.sha256.substring(0, SHA_PREFIX),
    }
    return row
  }

  /** 队列内存里的实时进度优先；没有就用落盘的那一份（进程刚回来时只有它）。 */
  private progressOf(item: CaptureItem): number {
    const live: number | undefined = ServiceLocator.queue.progress.get(item.id)
    const raw: number = live === undefined ? item.progress : live
    const pct: number = Math.round(raw * 100 / PROGRESS_STEP) * PROGRESS_STEP
    if (pct < PROGRESS_FLOOR) return PROGRESS_FLOOR
    return pct > 100 ? 100 : pct
  }

  /** 到期提醒。不该提醒时给空串——渲染那边只判长度，省得再多一个可空分支。 */
  private expiryNotice(item: CaptureItem, now: number): string {
    if (item.state !== TransferState.uploaded) return EMPTY
    const at: string | undefined = this.expiry.get(item.manifest.clientMediaId.toLowerCase())
    const days: number | null = expiryDaysLeft(at === undefined ? null : at, now)
    if (days === null || days >= EXPIRY_WARN_DAYS) return EMPTY
    return tr('queue.expires', { 'days': days })
  }
}
