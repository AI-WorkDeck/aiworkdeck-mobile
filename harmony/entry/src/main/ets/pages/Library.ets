import { fileUri } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppModel } from '../AppModel'
import { GlassBar, StatusDot } from '../design/Components'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { CaptureItem, MediaKind, RelayProject } from '../model/Capture'
import { formatHm } from '../model/Format'
import {
  DaySection, deleteWarning, groupByDay, itemsIn, ProjectChoice, projectsIn,
} from '../model/LibraryGrouping'
import { TransferState, TransferStateOps } from '../model/TransferState'
import { LIBRARY_VIEW_GRID, LIBRARY_VIEW_LIST } from '../services/Prefs'
import { ServiceLocator } from '../services/ServiceLocator'
import { AssignmentRequest } from './AssignmentRequest'
import { ViewerRequest } from './ViewerRequest'

const DOMAIN: number = 0x0000
const TAG: string = 'Library'

/** 格子间的发丝缝。影像之间不留空白，画面才铺得满。 */
const CELL_GAP: number = 2
/** 列表行的缩略图边长。 */
const ROW_THUMB: number = 72
/** 格子上状态点与选中圈的内缩。 */
const CELL_INSET: number = 6
const TICK_SIZE: number = 18
const TRANSPARENT: string = '#00000000'
const WHITE: string = '#FFFFFF'

/**
 * 图集 —— 深色、影像铺满、玻璃条压在影像上。镜像安卓 `LibraryScreen.kt` 与 iOS `LibraryView`。
 *
 * 只看一个项目：默认当前项目，顶栏可切换**看**的对象——切的是看的对象，不是拍摄目标：
 * 已拍的件各自记着自己的项目，从这里切不会把它们搬走。项目内按自然日分段。
 *
 * 列数（2 / 3）只在网格下有意义；网格 / 列表的选择落盘（`Prefs.libraryView`），
 * 进程被杀回来还是用户上次选的那种。
 */
@Component
export struct Library {
  stack: NavPathStack = new NavPathStack()

  /** 正在看的项目标识。空串 = 还没定，syncModel 里落到当前项目或第一个有记录的项目。 */
  @State audioOnly: boolean = false
  @State viewingId: string = ''
  @State viewingName: string = ''
  @State choices: ProjectChoice[] = []
  @State sections: DaySection[] = []
  @State count: number = 0
  @State otherPending: number = 0
  @State columns: number = 2
  @State isGrid: boolean = true
  @State selecting: boolean = false
  @State selected: string[] = []
  /** 顶栏高度实测。内容用它让开——玻璃条压在影像上，让开的量不能靠猜。 */
  @State barHeight: number = 0
  private token: number = -1
  /** 这一屏还在不在。异步回调回来时组件可能已经销毁，往里写 @State 是错误日志甚至崩溃。 */
  private alive: boolean = false

  aboutToAppear(): void {
    this.alive = true
    this.token = AppModel.shared.subscribe((): void => this.syncModel())
    this.syncModel()
    ServiceLocator.prefs.libraryView().then((v: string): void => {
      if (!this.alive) return
      this.isGrid = v !== LIBRARY_VIEW_LIST
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'libraryView failed: %{public}s', `${e}`)
    })
  }

  aboutToDisappear(): void {
    this.alive = false
    if (this.token >= 0) AppModel.shared.unsubscribe(this.token)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          Column() {
            if (this.count === 0) {
              this.emptyState()
            } else if (this.isGrid) {
              this.grid()
            } else {
              this.list()
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ top: this.barHeight })

          if (this.selecting) {
            this.dock()
          }
        }
        .width('100%')
        .height('100%')

        // 外面套一层 Column 是为了挂 onAreaChange：自定义组件（GlassBar）后面不接通用属性
        Column() {
          GlassBar() {
            this.topBar()
          }
        }
        .width('100%')
        .onAreaChange((_old: Area, now: Area): void => {
          if (typeof now.height === 'number') this.barHeight = now.height as number
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(Tk.D.bg)
  }

  // MARK: - 顶栏

  @Builder
  topBar() {
    Column() {
      Row({ space: Tk.Sp.s3 }) {
        Text(tr('library.all'))
          .fontColor(this.audioOnly ? Tk.D.fgMuted : Tk.D.fg)
          .height(Tk.touchMin)
          .onClick((): void => { this.audioOnly = false; this.selected = []; this.syncModel() })
        Text(tr('library.audio'))
          .fontColor(this.audioOnly ? Tk.D.fg : Tk.D.fgMuted)
          .height(Tk.touchMin)
          .onClick((): void => { this.audioOnly = true; this.selected = []; this.syncModel() })
      }

      Row({ space: Tk.Sp.s1 }) {
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

        // 项目名就是菜单入口：点标题换看的对象，不另起一个图标
        Row({ space: Tk.Sp.s1 }) {
          Text(this.viewingName)
            .fontSize(Tk.Ty.heading)
            .fontColor(Tk.D.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('▾')
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fgMuted)
        }
        .layoutWeight(1)
        .height(Tk.touchMin)
        .alignItems(VerticalAlign.Center)
        .bindMenu(this.projectMenu())

        // 列数只在网格下有意义；多选时把工具收起来，顶栏留给「取消」
        if (!this.selecting && this.isGrid) {
          Text(tr('library.columns', { 'n': this.columns }))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fg)
            .height(Tk.touchMin)
            .padding({ left: Tk.Sp.s1, right: Tk.Sp.s1 })
            .onClick((): void => {
              this.columns = this.columns >= 3 ? 2 : 3
            })
        }
        if (!this.selecting) {
          // 写的是**切过去**的那一档，与列数按钮写当前档不同：这个是二选一的开关
          Text(this.isGrid ? tr('library.viewList') : tr('library.viewGrid'))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fg)
            .height(Tk.touchMin)
            .padding({ left: Tk.Sp.s1, right: Tk.Sp.s1 })
            .onClick((): void => this.toggleView())
        }
        Text(this.selecting ? tr('common.cancel') : tr('library.select'))
          .fontSize(Tk.Ty.small)
          .fontColor(this.count > 0 ? Tk.D.fg : Tk.D.fgMuted)
          .height(Tk.touchMin)
          .padding({ left: Tk.Sp.s1, right: Tk.Sp.s1 })
          .enabled(this.count > 0)
          .onClick((): void => {
            this.selecting = !this.selecting
            this.selected = []
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: Tk.Sp.s2, right: Tk.Sp.s3 })

      Divider().color(Tk.D.rule)
    }
    .width('100%')
  }

  // MARK: - 内容

  @Builder
  emptyState() {
    Column({ space: Tk.Sp.s2 }) {
      Text(tr('library.empty'))
        .fontSize(Tk.Ty.body)
        .fontColor(Tk.D.fg)
      if (this.otherPending > 0) {
        this.otherPendingLine()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s10 })
  }

  @Builder
  grid() {
    Grid() {
      ForEach(this.sections, (s: DaySection): void => {
        // 段头独占一行：整行跨列，格子才不会被挤到段头旁边
        GridItem() {
          this.dayHeader(s.title)
        }
        .columnStart(0)
        .columnEnd(this.columns - 1)

        ForEach(s.items, (it: CaptureItem): void => {
          GridItem() {
            this.cell(it)
          }
          .onClick((): void => this.tap(s, it))
          .gesture(LongPressGesture().onAction((): void => {
            this.selecting = true
            this.selected = [it.id]
          }))
        }, (it: CaptureItem): string => it.id)
      }, (s: DaySection): string => s.key)

      if (this.otherPending > 0) {
        GridItem() {
          this.otherPendingLine()
        }
        .columnStart(0)
        .columnEnd(this.columns - 1)
      }
    }
    .columnsTemplate(this.columns === 3 ? '1fr 1fr 1fr' : '1fr 1fr')
    .columnsGap(CELL_GAP)
    .rowsGap(CELL_GAP)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  list() {
    List() {
      ForEach(this.sections, (s: DaySection): void => {
        ListItem() {
          this.dayHeader(s.title)
        }

        ForEach(s.items, (it: CaptureItem): void => {
          ListItem() {
            this.listRow(it)
          }
          .onClick((): void => this.tap(s, it))
          .gesture(LongPressGesture().onAction((): void => {
            this.selecting = true
            this.selected = [it.id]
          }))
        }, (it: CaptureItem): string => it.id)
      }, (s: DaySection): string => s.key)

      if (this.otherPending > 0) {
        ListItem() {
          this.otherPendingLine()
        }
      }
    }
    .divider({ strokeWidth: 1, color: Tk.D.rule })
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  dayHeader(title: string) {
    Text(title)
      .fontSize(Tk.Ty.nano)
      .fontColor(Tk.D.fgMuted)
      .width('100%')
      .backgroundColor(Tk.D.bg)
      .padding({
        left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s2, bottom: Tk.Sp.s2,
      })
  }

  /** 一格：缩略图 + 右下角状态点；多选时左上角打勾、边框点亮。 */
  @Builder
  cell(item: CaptureItem) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.thumb(item)
        if (this.selecting) {
          Row()
            .width(TICK_SIZE)
            .height(TICK_SIZE)
            .borderRadius(TICK_SIZE / 2)
            .borderWidth(1.5)
            .borderColor(this.checked(item) ? Tk.S.movingOnDark : Tk.D.fg)
            .backgroundColor(this.checked(item) ? Tk.S.movingOnDark : TRANSPARENT)
            .margin(CELL_INSET)
        }
      }
      .width('100%')
      .height('100%')

      StatusDot({ color: Tk.color(TransferStateOps.dotToken(item.state), true) })
        .margin(CELL_INSET)
    }
    .width('100%')
    .aspectRatio(1)
    .backgroundColor(Tk.D.surface)
    .borderWidth(this.selecting && this.checked(item) ? 2 : 0)
    .borderColor(Tk.S.movingOnDark)
    .accessibilityText(TransferStateOps.caption(item.state))
  }

  /** 列表一行：格子看画面，列表看核对信息——状态、时刻、类别都摊开。 */
  @Builder
  listRow(item: CaptureItem) {
    Row({ space: Tk.Sp.s3 }) {
      if (this.selecting) {
        Row()
          .width(TICK_SIZE)
          .height(TICK_SIZE)
          .borderRadius(TICK_SIZE / 2)
          .borderWidth(1.5)
          .borderColor(this.checked(item) ? Tk.S.movingOnDark : Tk.D.fgMuted)
          .backgroundColor(this.checked(item) ? Tk.S.movingOnDark : TRANSPARENT)
      }
      Stack() {
        this.thumb(item)
      }
      .width(ROW_THUMB)
      .height(ROW_THUMB)
      .backgroundColor(Tk.D.surface)

      Column({ space: Tk.Sp.s1 }) {
        Row({ space: Tk.Sp.s1 }) {
          StatusDot({ color: Tk.color(TransferStateOps.dotToken(item.state), true) })
          Text(TransferStateOps.caption(item.state))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fg)
          Text(formatHm(item.capturedAtMs()))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.D.fgMuted)
        }
        .alignItems(VerticalAlign.Center)

        Text(kindLabel(item.kind))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.D.fgMuted)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s2, bottom: Tk.Sp.s2,
    })
  }

  /** 缩略图。录音没有画面，用音符占位（时长不在这一屏算）。 */
  @Builder
  thumb(item: CaptureItem) {
    if (item.kind === MediaKind.audio) {
      Text('♪')
        .fontSize(Tk.Ty.heading)
        .fontColor(Tk.D.fgMuted)
        .width('100%')
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor(Tk.D.surface)
    } else {
      Image(fileUri.getUriFromPath(item.localPath))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    }
  }

  /** 别的项目里还没落盘的件不能完全藏起来——「没显示」和「没有」是两回事。 */
  @Builder
  otherPendingLine() {
    Text(tr('library.otherPending', { 'n': this.otherPending }))
      .fontSize(Tk.Ty.micro)
      .fontColor(Tk.D.fgMuted)
      .width('100%')
      .padding({
        left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s4, bottom: Tk.Sp.s4,
      })
  }

  /** 删除底座。一件都没选时按钮是暗的，左边那行字说清楚为什么暗。 */
  @Builder
  dock() {
    GlassBar() {
      Row() {
        Text(this.selected.length === 0
          ? tr('library.selectHint')
          : tr('library.selectedCount', { 'n': this.selected.length }))
          .fontSize(Tk.Ty.small)
          .fontColor(Tk.D.fgMuted)
          .layoutWeight(1)

        if (this.assignable()) {
          Text(tr('library.assign')).fontColor(Tk.D.fg).height(Tk.touchMin)
            .onClick((): void => {
              AssignmentRequest.ids = this.selected.slice()
              this.stack.pushPath(new NavPathInfo('ProjectAssign', ''))
            })
        }
        Text(tr('library.delete'))
          .fontSize(Tk.Ty.small)
          .fontColor(WHITE)
          .height(Tk.touchMin)
          .padding({ left: Tk.Sp.s4, right: Tk.Sp.s4 })
          .textAlign(TextAlign.Center)
          .backgroundColor(Tk.S.failed)
          .opacity(this.selected.length > 0 ? 1 : 0.4)
          .enabled(this.selected.length > 0)
          .onClick((): void => this.confirmDelete())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: Tk.Sp.gutter, right: Tk.Sp.gutter, top: Tk.Sp.s2, bottom: Tk.Sp.s2,
      })
    }
  }

  // MARK: - 行为

  private assignable(): boolean {
    const items: CaptureItem[] = AppModel.shared.items.filter((it: CaptureItem): boolean => this.selected.includes(it.id))
    return items.length > 0 && items.every((it: CaptureItem): boolean => it.project === null && it.state === TransferState.waiting)
  }

  private checked(item: CaptureItem): boolean {
    return this.selected.includes(item.id)
  }

  private projectMenu(): MenuElement[] {
    const menu: MenuElement[] = []
    for (const c of this.choices) {
      const entry: MenuElement = {
        value: c.name,
        action: (): void => {
          this.viewingId = c.id
          this.selected = []
          this.syncModel()
        },
      }
      menu.push(entry)
    }
    return menu
  }

  private toggleView(): void {
    this.isGrid = !this.isGrid
    const v: string = this.isGrid ? LIBRARY_VIEW_GRID : LIBRARY_VIEW_LIST
    ServiceLocator.prefs.setLibraryView(v).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'setLibraryView failed: %{public}s', `${e}`)
    })
  }

  /** 点一格：多选态下是打勾 / 取消，平时是进查看器看这一天的这一件。 */
  private tap(section: DaySection, item: CaptureItem): void {
    if (this.selecting) {
      this.selected = this.checked(item)
        ? this.selected.filter((id: string): boolean => id !== item.id)
        : this.selected.concat([item.id])
      return
    }
    ViewerRequest.ids = section.items.map((i: CaptureItem): string => i.id)
    ViewerRequest.index = section.items.findIndex((i: CaptureItem): boolean => i.id === item.id)
    this.stack.pushPath(new NavPathInfo('Viewer', ''))
  }

  /**
   * 删除确认。正文按所选里**最坏的桶**说话：还没送出去的和电脑已经收了的，
   * 删掉的后果差得远，用一句通用的「无法恢复」等于没说。
   */
  private confirmDelete(): void {
    const ids: string[] = this.selected
    if (ids.length === 0) return
    const states: TransferState[] = []
    for (const s of this.sections) {
      for (const it of s.items) {
        if (ids.includes(it.id)) states.push(it.state)
      }
    }
    this.getUIContext().showAlertDialog({
      title: tr('delete.title', { 'n': ids.length }),
      message: deleteWarning(states),
      autoCancel: true,
      primaryButton: {
        value: tr('common.cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: tr('library.delete'),
        fontColor: Tk.S.failed,
        action: (): void => this.remove(ids),
      },
    })
  }

  /** 删本地原件 + 删记录。记录留着而原件没了，图集里会出现永远打不开的空格。 */
  private remove(ids: string[]): void {
    ServiceLocator.store.remove(ids).then((): Promise<void> => ServiceLocator.prefs.removeOrganizationResults(ids)).then((): Promise<void> => AppModel.shared.refresh())
      .then((): void => {
        this.selected = []
        this.selecting = false
      })
      .catch((e: Object): void => {
        hilog.error(DOMAIN, TAG, 'remove failed: %{public}s', `${e}`)
      })
  }

  // MARK: - 同步

  private syncModel(): void {
    const model: AppModel = AppModel.shared
    const current: RelayProject | null = model.selectedProject
    const choices: ProjectChoice[] = projectsIn(model.items, current)
    this.choices = choices
    // 正在看的项目若已经没有记录了（刚被删空），退回第一项，别停在一个空标题上
    let viewing: ProjectChoice | null = null
    for (const c of choices) {
      if (c.id === this.viewingId) viewing = c
    }
    if (viewing === null && choices.length > 0) viewing = choices[0]
    this.viewingId = viewing === null ? '' : viewing.id
    this.viewingName = viewing === null ? '' : viewing.name

    const items: CaptureItem[] = itemsIn(model.items, viewing === null ? null : viewing.id, model.selectedProject)
      .filter((it: CaptureItem): boolean => !this.audioOnly || it.kind === MediaKind.audio)
    this.sections = groupByDay(items)
    this.count = items.length
    this.otherPending = model.otherPending()
    if (this.count === 0 && this.selecting) {
      this.selecting = false
      this.selected = []
    }
  }
}

function kindLabel(kind: MediaKind): string {
  if (kind === MediaKind.photo) return tr('home.mode.photo')
  return kind === MediaKind.video ? tr('home.mode.video') : tr('home.mode.audio')
}
