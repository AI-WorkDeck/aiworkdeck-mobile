import { takePersonalPreview } from '../../utils/api'
import { getSelectedProject, getSession, myProjects, fileRequest, uuid, type RelayProject } from '../../utils/api'
import { folderEntries, mergeLiveFiles, previewKind, extension, type ProjectFile, type FileEntry } from '../../utils/project-files'
import { validatePreview, previewQuote, hasPendingPull, pullPreview, cloudPreview, clearCompletedPreviews } from '../../utils/file-preview'
import { sameProject } from '../../utils/project-catalog'
import type { Metrics } from '../../utils/layout'
import { t } from '../../utils/i18n'

interface Listing { files: ProjectFile[]; truncated?: boolean }
Page({
  data: {
    metrics: {} as Metrics, title: '', folder: '', entries: [] as FileEntry[], loading: false,
    error: '', busy: false, videoPath: '', audioPlaying: false, truncated: false,
    rootText: t('files.root'), parentText: t('files.parent'), emptyText: t('files.empty'),
    loadingText: t('workspace.loading'), retryText: t('project.retry'), limitText: t('workspace.limit'),
    audioText: t('home.mode.audio'),
  },
  project: null as RelayProject | null,
  files: [] as ProjectFile[],
  active: false,
  unavailableDesktop: '',
  session: null as string | null,
  audio: null as WechatMiniprogram.InnerAudioContext | null,

  onLoad() {
    this.active = true
    this.session = getSession()
    this.project = takePersonalPreview() ?? getSelectedProject()
    this.setData({
      metrics: getApp<{ globalData: { metrics: Metrics } }>().globalData.metrics,
      title: this.project?.name ?? t('project.files'),
      rootText: t('files.root'), parentText: t('files.parent'), emptyText: t('files.empty'),
      loadingText: t('workspace.loading'), retryText: t('project.retry'), limitText: t('workspace.limit'),
      audioText: t('home.mode.audio'),
    })
    this.loadFiles()
  },
  alive() { return this.active && this.session === getSession() },
  async onPullDownRefresh() {
    try { await this.loadFiles() } finally { wx.stopPullDownRefresh() }
  },
  onHide() { this.audio?.pause(); this.setData({ audioPlaying: false, videoPath: '' }) },
  onUnload() { this.active = false; this.audio?.destroy(); this.audio = null; clearCompletedPreviews(this.session) },
  async loadFiles() {
    if (!this.project || this.data.loading) return
    this.setData({ loading: true, error: '' })
    this.unavailableDesktop = ''
    try {
      const projects = await myProjects()
      if (!this.alive()) return
      const project = projects.find(p => sameProject(p, this.project!))
      if (!project) throw new Error(t('files.error.response'))
      this.project = project
      const desktop = project.locations?.find(l => l.kind === 'desktop' && l.online)
      let listing: Listing
      if (desktop) {
        try {
          const { id } = await fileRequest<{ id: number }>('/api/mobile/transfer/list', {
            deviceId: desktop.deviceId, projectKey: desktop.key, requestId: uuid(),
          })
          listing = await this.pollListing(id)
          listing.files = listing.files.map(f => ({ ...f, source: 'desktop', deviceId: desktop.deviceId, projectKey: desktop.key, online: true }))
          if (project.projectUid) {
            try {
              const catalog = await fileRequest<Listing>(`/api/mobile/catalog/${encodeURIComponent(project.projectUid)}/files`, undefined, true)
              listing = { files: mergeLiveFiles(catalog.files, listing.files),
                truncated: (listing.truncated ?? listing.files.length >= 2000) || (catalog.truncated ?? catalog.files.length >= 2000) }
            } catch {
              // A successful live list remains useful; the partial-list notice covers unavailable catalog sources.
              listing.truncated = true
            }
          }
        } catch (error) {
          if (!project.projectUid) throw error
          this.unavailableDesktop = desktop.deviceId + ':' + desktop.key
          listing = await fileRequest<Listing>(`/api/mobile/catalog/${encodeURIComponent(project.projectUid)}/files`, undefined, true)
        }
      } else {
        if (!project.projectUid) throw new Error(t('files.desktopRequired'))
        listing = await fileRequest<Listing>(`/api/mobile/catalog/${encodeURIComponent(project.projectUid)}/files`, undefined, true)
      }
      if (!this.alive()) return
      this.files = listing.files
      this.setData({ folder: '', entries: folderEntries(this.files), truncated: listing.truncated ?? this.files.length >= 2000 })
    } catch (error) { if (this.alive()) this.setData({ error: (error as Error).message }) }
    finally { if (this.alive()) this.setData({ loading: false }) }
  },
  async pollListing(id: number): Promise<Listing> {
    for (let attempt = 0; attempt < 60; attempt++) {
      if (!this.alive()) throw new Error(t('files.error.closed'))
      const { transfer } = await fileRequest<{ transfer: Listing & { id: number; kind: string; status: string } }>(`/api/mobile/transfer/${id}`)
      if (transfer.id !== id || transfer.kind !== 'LIST') throw new Error(t('files.error.response'))
      if (transfer.status === 'DONE' && Array.isArray(transfer.files)) return transfer
      if (transfer.status !== 'PENDING') throw new Error(t('files.error.transferFailed'))
      await new Promise(resolve => setTimeout(resolve, 1000))
    }
    throw new Error(t('files.error.timeout'))
  },
  onParent() {
    const folder = this.data.folder.split('/').slice(0, -1).join('/')
    this.setData({ folder, entries: folderEntries(this.files, folder) })
  },
  async onEntry(e: { currentTarget: { dataset: { index: number } } }) {
    if (this.data.busy) return
    const entry = this.data.entries[e.currentTarget.dataset.index]
    if (entry.folder) { this.setData({ folder: entry.path, entries: folderEntries(this.files, entry.path) }); return }
    let file = entry.file!
    this.setData({ busy: true, error: '', videoPath: '' })
    this.audio?.destroy(); this.audio = null
    try {
      validatePreview(file) // Before consent lookup, quote, transfer creation or byte download.
      const project = this.project!
      const latest = (await myProjects()).find(p => sameProject(p, project))
      const desktopOnline = latest?.locations?.some(l => l.kind === 'desktop' && l.online &&
        l.deviceId === file.deviceId && l.key === file.projectKey) === true
      if (file.source === 'backup' && desktopOnline) file = { ...file, source: 'desktop' }
      let path: string
      if (file.source === 'cloud' || file.source === 'backup') {
        path = await cloudPreview(project, file, () => this.alive())
      } else {
        if (this.unavailableDesktop === `${file.deviceId}:${file.projectKey}`) throw new Error(t('files.desktopRequired'))
        if (!desktopOnline) {
          throw new Error(t('files.desktopRequired'))
        }
        if (!hasPendingPull(project, file)) {
          const credits = await previewQuote(file)
          if (!this.alive()) return
          const result = await wx.showModal({ title: t('workspace.download'),
            content: t('workspace.quote', { name: file.name, credits }) })
          if (!result.confirm) return
        }
        path = await pullPreview(project, file, () => this.alive())
      }
      if (!this.alive()) return
      const kind = previewKind(file)
      const fail = () => { if (this.alive()) this.setData({ error: t('files.previewFailed') }) }
      if (kind === 'image') wx.previewImage({ urls: [path], fail })
      else if (kind === 'document') wx.openDocument({ filePath: path, fileType: extension(file.name) as 'docx' | 'pptx' | 'xlsx' | 'pdf', showMenu: false, fail })
      else if (kind === 'video') this.setData({ videoPath: path })
      else {
        this.audio = wx.createInnerAudioContext()
        this.audio.src = path
        this.audio.onError(fail)
        this.audio.onEnded(() => this.setData({ audioPlaying: false }))
        this.audio.play(); this.setData({ audioPlaying: true })
      }
    } catch (error) { if (this.alive()) this.setData({ error: (error as Error).message }) }
    finally { if (this.alive()) this.setData({ busy: false }) }
  },
  onStopAudio() { this.audio?.stop(); this.setData({ audioPlaying: false }) },
  onPreviewError() { this.setData({ error: t('files.previewFailed') }) },
})
