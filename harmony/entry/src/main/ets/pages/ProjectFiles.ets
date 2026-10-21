import { RelayProject } from '../model/Capture'
import { FileEntry, ProjectFile, folderEntries, FileListing } from '../model/ProjectFiles'
import { ProjectFilesService } from '../services/ProjectFilesService'
import { ServiceLocator } from '../services/ServiceLocator'
import { ProjectFilesRequest } from './ProjectFilesRequest'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { errorText } from './Feedback'

@Component
export struct ProjectFiles {
  stack: NavPathStack = new NavPathStack()
  @State titleText: string = ''
  @State folder: string = ''
  @State entries: FileEntry[] = []
  @State loading: boolean = false
  @State busy: boolean = false
  @State failure: string = ''
  @State truncated: boolean = false
  private files: ProjectFile[] = []
  private project: RelayProject | null = null
  private service: ProjectFilesService | null = null
  private alive: boolean = false

  aboutToAppear(): void {
    this.alive = true
    this.project = ProjectFilesRequest.project
    this.titleText = this.project?.name ?? tr('workspace.files')
    this.initialize().catch((e: Object): void => { if (this.alive) this.failure = errorText(e) })
  }
  aboutToDisappear(): void { this.alive = false; this.service?.close() }
  private async initialize(): Promise<void> {
    const session: string | null = await ServiceLocator.session.current()
    if (!this.alive) return
    if (session === null) { this.failure = tr('files.error.closed'); return }
    this.service = new ProjectFilesService(session)
    this.load()
  }
  private load(): void {
    if (this.loading || this.busy || this.project === null || this.service === null) return
    this.loading = true
    this.failure = ''
    this.service.load(this.project).then((result: FileListing): void => {
      if (!this.alive) return
      this.files = result.files
      this.folder = ''
      this.entries = folderEntries(this.files)
      this.truncated = result.truncated
    }).catch((e: Object): void => { if (this.alive) this.failure = errorText(e) })
      .finally((): void => { if (this.alive) this.loading = false })
  }
  private open(entry: FileEntry): void {
    if (this.busy || this.loading) return
    if (entry.folder) { this.folder = entry.path; this.entries = folderEntries(this.files, this.folder); return }
    if (entry.file === undefined) return
    this.busy = true
    this.failure = ''
    this.preview(entry.file).catch((e: Object): void => { if (this.alive) this.failure = errorText(e) })
      .finally((): void => { if (this.alive) this.busy = false })
  }
  private async preview(file: ProjectFile): Promise<void> {
    const service: ProjectFilesService | null = this.service
    const project: RelayProject | null = this.project
    if (service === null || project === null) return
    await service.canOpen(file)
    const desktop: boolean = await service.useDesktop(project, file)
    if (desktop && !service.hasPending(project, file)) {
      const credits: number = await service.quote(file)
      await service.ensureActive()
      const confirmed: boolean = await new Promise<boolean>((resolve: (v: boolean) => void): void => {
        this.getUIContext().showAlertDialog({ title: tr('workspace.download'),
          message: tr('workspace.quote', { 'name': file.name, 'credits': credits }), autoCancel: true,
          cancel: (): void => resolve(false),
          primaryButton: { value: tr('common.cancel'), action: (): void => resolve(false) },
          secondaryButton: { value: tr('workspace.download'), action: (): void => resolve(true) } })
      })
      if (!confirmed) return
    }
    await service.ensureActive()
    await service.preview(project, file, desktop)
  }
  build() {
    NavDestination() {
      Column({ space: Tk.Sp.s2 }) {
        Row() {
          Text('‹').width(Tk.touchMin).height(Tk.touchMin).fontSize(Tk.Ty.title)
            .onClick((): void => { this.stack.pop() })
          Text(this.titleText).fontSize(Tk.Ty.heading).layoutWeight(1).maxLines(1)
          Text(tr('project.reload')).height(Tk.touchMin).onClick((): void => this.load())
        }.width('100%')
        Text(this.folder.length > 0 ? this.folder : tr('files.root')).fontSize(Tk.Ty.small)
        if (this.folder.length > 0) {
          Text(tr('files.parent')).height(Tk.touchMin).onClick((): void => {
            this.folder = this.folder.split('/').slice(0, -1).join('/')
            this.entries = folderEntries(this.files, this.folder)
          })
        }
        if (this.loading || this.busy) {
          LoadingProgress().width(Tk.touchMin).height(Tk.touchMin)
          Text(tr(this.loading ? 'workspace.loading' : 'workspace.downloading')).fontSize(Tk.Ty.small)
        }
        if (this.failure.length > 0) { Text(this.failure).fontColor(Tk.S.failed) }
        if (this.truncated) { Text(tr('workspace.limit')).fontSize(Tk.Ty.micro) }
        if (!this.loading && this.entries.length === 0) { Text(tr('files.empty')) }
        List() {
          ForEach(this.entries, (entry: FileEntry): void => {
            ListItem() {
              Row({ space: Tk.Sp.s2 }) {
                Text(entry.folder ? '▸' : '·')
                Text(entry.name).layoutWeight(1).maxLines(2)
              }.width('100%').constraintSize({ minHeight: Tk.touchMin })
            }.onClick((): void => this.open(entry))
          }, (entry: FileEntry): string => entry.key)
        }.layoutWeight(1).width('100%')
      }.padding(Tk.Sp.gutter).width('100%').height('100%').alignItems(HorizontalAlign.Start)
    }.hideTitleBar(true).backgroundColor(Tk.L.bg)
  }
}
