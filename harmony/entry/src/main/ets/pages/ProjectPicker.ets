import { AppModel } from '../AppModel'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { RelayProject, projectId, sameProject } from '../model/Capture'
import { Unauthorized } from '../model/Envelope'
import { formatDay } from '../model/Format'
import { ScreenshotMode } from '../ScreenshotMode'
import { ServiceLocator } from '../services/ServiceLocator'
import { AssignmentRequest } from './AssignmentRequest'
import { ProjectFilesRequest } from './ProjectFilesRequest'
import { errorText, toast } from './Feedback'

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
  assigning: boolean = false
  @State projects: RelayProject[] = []
  @State loading: boolean = true
  @State failure: string = ''
  @State query: string = ''
  @State recentIds: string[] = []

  aboutToAppear(): void {
    this.load()
  }

  build() {
    NavDestination() {
      Column() {
        // 页头压紧：这一页只做一件事——尽快点到要的项目（对位 iOS #91）
        Column({ space: Tk.Sp.s1 }) {
          Text(tr('project.title'))
            .fontSize(Tk.Ty.heading)
            .fontColor(Tk.L.fg)
          Text(tr('project.hint', { 'date': formatDay(ScreenshotMode.archiveMs(Date.now())) }))
            .fontSize(Tk.Ty.micro)
            .fontColor(Tk.L.fgFaint)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: Tk.Sp.s4, bottom: Tk.Sp.s3 })

        if (!this.loading && this.projects.length > 0) {
          TextInput({ text: this.query, placeholder: tr('workspace.searchProjects') })
            .width('100%')
            .margin({ bottom: Tk.Sp.s2 })
            .onChange((value: string): void => { this.query = value })
        }

        // 临时项目是一行，不是一个孤零零的链接；有搜索词时收起来
        if (!this.assigning && this.query.trim().length === 0) {
          this.row(tr('project.none'), tr('project.noneHint'), AppModel.shared.selectedProject?.isDefault === true, (): void => {
            if (this.loading) return
            this.loading = true
            ServiceLocator.backend.defaultProject().then((project: RelayProject): Promise<void> => AppModel.shared.selectProject(project))
              .then((): void => { if (this.switching) this.stack.pop() })
              .catch((error: Error): void => { this.failure = errorText(error) })
              .finally((): void => { this.loading = false })
          })
          Divider().color(Tk.L.rule)
        }

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
      if (this.recent().length > 0) {
        ListItem() { this.sectionTitle(tr('project.recent')) }
        ForEach(this.recent(), (p: RelayProject): void => {
          ListItem() { this.projectRow(p) }
        }, (p: RelayProject): string => 'recent:' + projectId(p))
        ListItem() { this.sectionTitle(tr('personal.allProjects')) }
      }
      ForEach(this.matches(), (p: RelayProject): void => {
        ListItem() { this.projectRow(p) }
      }, (p: RelayProject): string => projectId(p))
      if (this.matches().length === 0) {
        ListItem() {
          Text(tr('project.noMatch'))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.L.fgMuted)
            .height(Tk.touchMin)
        }
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(Tk.Ty.nano)
      .fontColor(Tk.L.fgMuted)
      .margin({ top: Tk.Sp.s4, bottom: Tk.Sp.s1 })
  }

  @Builder
  projectRow(p: RelayProject) {
    Column() {
      // 电脑名只在项目分布在多台电脑上时才帮得上忙；内部 id 不给用户看
      this.row(p.name, this.showsDevice() ? (p.deviceName ?? '') : '', this.isCurrent(p), (): void => this.pick(p))
      if (!this.assigning) {
        Text(tr('project.files')).height(Tk.touchMin).fontColor(Tk.L.accent)
          .onClick((): void => {
            ProjectFilesRequest.project = p
            this.stack.pushPath(new NavPathInfo('ProjectFiles', ''))
          })
      }
      Divider().color(Tk.L.rule)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一行：名称（可带一行副标题），当前项目右侧打勾。 */
  @Builder
  row(title: string, subtitle: string, current: boolean, action: () => void) {
    Row({ space: Tk.Sp.s3 }) {
      Column({ space: Tk.Sp.s1 }) {
        Text(title)
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.L.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.L.fgFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (current) {
        Text('✓')
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.L.accent)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: Tk.touchMin })
    .alignItems(VerticalAlign.Center)
    .onClick(action)
  }

  /** 有搜索词时只留名字匹配的。 */
  private matches(): RelayProject[] {
    const q: string = this.query.trim().toLowerCase()
    if (q.length === 0) return this.projects
    return this.projects.filter((p: RelayProject): boolean => p.name.toLowerCase().includes(q))
  }

  /** 最近用过的（最多 5 个）。项目不多时一眼就能看完，不必再分一段。 */
  private recent(): RelayProject[] {
    if (this.query.trim().length > 0 || this.projects.length <= 6) return []
    const out: RelayProject[] = []
    for (const id of this.recentIds) {
      const hit: RelayProject | undefined = this.projects.find((p: RelayProject): boolean => projectId(p) === id)
      if (hit !== undefined) out.push(hit)
    }
    return out
  }

  private showsDevice(): boolean {
    const names: Set<string> = new Set<string>()
    for (const p of this.projects) {
      if (p.deviceName !== undefined && p.deviceName.length > 0) names.add(p.deviceName)
    }
    return names.size > 1
  }

  private isCurrent(p: RelayProject): boolean {
    const current: RelayProject | null = AppModel.shared.selectedProject
    return !this.assigning && current !== null && sameProject(current, p)
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
      this.projects = (await ServiceLocator.backend.myProjects()).filter((p: RelayProject): boolean => this.assigning || p.isDefault !== true)
      this.recentIds = await ServiceLocator.prefs.recentProjectIds().catch((): string[] => [])
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

  private async assign(p: RelayProject): Promise<void> {
    for (const id of AssignmentRequest.ids) await ServiceLocator.store.setProject(id, p)
    AssignmentRequest.ids = []
    await AppModel.shared.refresh()
    this.stack.pop()
    if (!ScreenshotMode.enabled) await ServiceLocator.queue.kick()
  }

  private pick(p: RelayProject): void {
    ServiceLocator.prefs.useRecentProject(projectId(p)).catch((): void => {})
    if (this.assigning) {
      this.assign(p).catch((): void => toast(this.getUIContext(), tr('library.assignFailed')))
      return
    }
    AppModel.shared.selectProject(p).then((): void => {
      // 换项目是从设置页进来的一次往返，选完退回设置；登录后的那次由路由接管
      if (this.switching) this.stack.pop()
    }).catch((): void => {})
  }
}
