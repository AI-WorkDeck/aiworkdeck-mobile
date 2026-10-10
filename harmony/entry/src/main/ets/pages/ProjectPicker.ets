import { AppModel } from '../AppModel'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { RelayProject, projectId } from '../model/Capture'
import { Unauthorized } from '../model/Envelope'
import { formatDay } from '../model/Format'
import { ScreenshotMode } from '../ScreenshotMode'
import { ServiceLocator } from '../services/ServiceLocator'
import { errorText } from './Feedback'

/**
 * 选归档目标。登录后必走一次——不选项目就不知道照片该往哪去，与其让人先拍完再问，
 * 不如进门就定。镜像安卓 `ProjectPickerScreen.kt` 与 iOS `ProjectPickerView`。
 *
 * 两种来路：登录后（switching = false，选完由 AppModel 把路由推去取景器）；
 * 设置里换项目（switching = true，选完退回设置页，路由不动）。
 */
@Component
export struct ProjectPicker {
  stack: NavPathStack = new NavPathStack()
  switching: boolean = false
  @State projects: RelayProject[] = []
  @State loading: boolean = true
  @State failure: string = ''

  aboutToAppear(): void {
    this.load()
  }

  build() {
    NavDestination() {
      Column() {
        Column({ space: Tk.Sp.s2 }) {
          Text(tr('project.eyebrow'))
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.L.fgMuted)
          Text(tr('project.title'))
            .fontSize(Tk.Ty.display)
            .fontColor(Tk.L.fg)
          Text(tr('project.hint', { 'date': formatDay(ScreenshotMode.archiveMs(Date.now())) }))
            .fontSize(Tk.Ty.micro)
            .fontColor(Tk.L.fgFaint)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: Tk.Sp.s10, bottom: Tk.Sp.s6 })

        // 内容区吃掉中间所有空间，页脚（退出登录）永远贴在底下
        Column() {
          if (this.loading) {
            this.loadingState()
          } else if (this.failure.length > 0) {
            this.failureState()
          } else if (this.projects.length === 0) {
            this.emptyState()
          } else {
            this.list()
          }
        }
        .layoutWeight(1)
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Divider().color(Tk.L.rule)
        Text(tr('common.signOut'))
          .fontSize(Tk.Ty.small)
          .fontColor(Tk.L.fgMuted)
          .height(Tk.touchMin)
          .margin({ bottom: Tk.Sp.s4 })
          .onClick((): void => {
            AppModel.shared.signOut().catch((): void => {})
          })
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter })
    }
    .hideTitleBar(true)
    .backgroundColor(Tk.L.bg)
  }

  @Builder
  loadingState() {
    Row({ space: Tk.Sp.s2 }) {
      LoadingProgress().width(Tk.Ty.title).height(Tk.Ty.title).color(Tk.L.fgMuted)
      Text(tr('project.loading'))
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fgMuted)
    }
    .height(Tk.touchMin)
  }

  @Builder
  failureState() {
    Column({ space: Tk.Sp.s3 }) {
      Text(this.failure)
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.S.failed)
      this.action(tr('project.retry'))
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  emptyState() {
    Column({ space: Tk.Sp.s2 }) {
      Text(tr('project.emptyTitle'))
        .fontSize(Tk.Ty.body)
        .fontColor(Tk.L.fg)
      // 说实话：列表来自桌面端的自动同步，前提是桌面端开着且登录同一账号
      Text(tr('empty.projects'))
        .fontSize(Tk.Ty.micro)
        .fontColor(Tk.L.fgFaint)
      this.action(tr('project.reload'))
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  action(label: string) {
    Text(label)
      .fontSize(Tk.Ty.small)
      .fontColor(Tk.L.accent)
      .height(Tk.touchMin)
      .onClick((): void => this.load())
  }

  @Builder
  list() {
    List() {
      ForEach(this.projects, (p: RelayProject): void => {
        ListItem() {
          Column() {
            Row() {
              Column({ space: Tk.Sp.s1 }) {
                Text(p.name)
                  .fontSize(Tk.Ty.body)
                  .fontColor(Tk.L.fg)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(p.projectUid !== undefined ? tr('project.unifiedIdentity', { 'id': p.projectUid }) : (p.deviceName ?? p.deviceId))
                  .fontSize(Tk.Ty.nano)
                  .fontColor(Tk.L.fgFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('›')
                .fontSize(Tk.Ty.body)
                .fontColor(Tk.L.fgFaint)
            }
            .width('100%')
            .constraintSize({ minHeight: Tk.touchMin })
            .alignItems(VerticalAlign.Center)

            Divider().color(Tk.L.rule)
          }
          .width('100%')
          .onClick((): void => this.pick(p))
        }
      }, (p: RelayProject): string => projectId(p))
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  private load(): void {
    this.loading = true
    this.failure = ''
    this.loadAsync().catch((e: Object): void => {
      this.loading = false
      this.failure = errorText(e)
    })
  }

  private async loadAsync(): Promise<void> {
    // 截图机器上没有桌面端，项目列表本来是空态；截图模式给三条演示项目
    if (ScreenshotMode.enabled) {
      this.projects = ScreenshotMode.projects
      this.loading = false
      return
    }
    try {
      this.projects = await ServiceLocator.backend.myProjects()
    } catch (e) {
      // 会话在别处失效了：回登录页比留在这儿干瞪眼有用
      if (e instanceof Unauthorized) {
        await AppModel.shared.signOut()
        return
      }
      throw e as Error
    }
    this.loading = false
  }

  private pick(p: RelayProject): void {
    AppModel.shared.selectProject(p).then((): void => {
      // 换项目是从设置页进来的一次往返，选完退回设置；登录后的那次由路由接管
      if (this.switching) this.stack.pop()
    }).catch((): void => {})
  }
}
