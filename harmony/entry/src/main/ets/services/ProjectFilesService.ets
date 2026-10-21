import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { http } from '@kit.NetworkKit'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { filePreview } from '@kit.PreviewKit'
import { JSON as ArkJson, util } from '@kit.ArkTS'
import { ApiError } from '../model/Envelope'
import { RelayProject, ProjectLocation, sameProject } from '../model/Capture'
import { ProjectFile, FileListing, decodeFileListing, mergeLiveFiles, validatePreview, fileExtension, previewMime, pullIdentity } from '../model/ProjectFiles'
import { asRecord, getNumber, getString } from './ApiTypes'
import { ServiceLocator } from './ServiceLocator'
import { tr } from '../design/L10n'


/** One workspace owns its requests. Session changes and closing the page invalidate every continuation. */
export class ProjectFilesService {
  private active: boolean = true
  private readonly session: string
  private readonly sessionKey: string
  private readonly baseUrl: string
  private readonly directory: string
  private readonly completed: string[] = []
  private client: http.HttpRequest | null = null
  private finishStream: (() => void) | null = null
  private unavailableDesktop: string = ''

  constructor(session: string) {
    this.session = session
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256')
    const input: cryptoFramework.DataBlob = { data: new util.TextEncoder().encodeInto(session) }
    md.updateSync(input)
    this.sessionKey = Array.from(md.digestSync().data).map((v: number): string => v.toString(16).padStart(2, '0')).join('')
    this.baseUrl = ServiceLocator.baseUrl()
    this.directory = `${ServiceLocator.ctx.filesDir}/ProjectPreviews`
    if (!fs.accessSync(this.directory)) fs.mkdirSync(this.directory, true)
    // Completed previews from an earlier killed page are cache, not recoverable charge state.
    for (const name of fs.listFileSync(this.directory)) {
      if (!name.endsWith('.json')) continue
      const path: string = `${this.directory}/${name}`
      const row: Record<string, Object> | null = asRecord(ArkJson.parse(fs.readTextSync(path)))
      if (row !== null && row['acknowledged'] === true) {
        const cached: string | undefined = getString(row, 'path')
        if (cached !== undefined && cached.startsWith(this.directory + '/')) this.remove(cached)
        this.remove(path)
      }
    }
  }

  close(): void {
    this.active = false
    this.finishStream?.()
    this.client?.destroy()
    this.client = null
    for (const path of this.completed) this.remove(path)
  }

  async ensureActive(): Promise<void> {
    if (!this.active || this.session.length === 0 || await ServiceLocator.session.current() !== this.session ||
      ServiceLocator.baseUrl() !== this.baseUrl) throw new ApiError(1, tr('files.error.closed'))
  }

  async load(project: RelayProject): Promise<FileListing> {
    await this.ensureActive()
    this.unavailableDesktop = ''
    const projects: RelayProject[] = await ServiceLocator.backend.myProjects()
    await this.ensureActive()
    const latest: RelayProject | undefined = projects.find((p: RelayProject): boolean => sameProject(p, project))
    if (latest === undefined) throw new ApiError(1, tr('files.error.response'))
    let desktop: ProjectLocation | undefined = latest.locations?.find((l: ProjectLocation): boolean => l.kind === 'desktop' && l.online === true)
    if (latest.locations === undefined && latest.deviceId !== 'cloud') desktop = { kind: 'desktop', deviceId: latest.deviceId, key: latest.key }
    if (desktop !== undefined) {
      try {
        const body: Record<string, Object> = { 'deviceId': desktop.deviceId, 'projectKey': desktop.key, 'requestId': util.generateRandomUUID(false) }
        const created: Record<string, Object> = await this.request('/api/mobile/transfer/list', body)
        const id: number = requiredId(created)
        const listing: FileListing = decodeFileListing(await this.poll(id, 'LIST', 'DONE'))
        for (const f of listing.files) { f.source = 'desktop'; f.deviceId = desktop.deviceId; f.projectKey = desktop.key; f.online = true }
        if (latest.projectUid !== undefined) {
          try {
            const catalog: FileListing = await this.catalog(latest)
            listing.files = mergeLiveFiles(catalog.files, listing.files)
            listing.truncated = listing.truncated || catalog.truncated
          } catch (_) { listing.truncated = true }
        }
        await this.ensureActive()
        return listing
      } catch (e) {
        await this.ensureActive()
        if (latest.projectUid === undefined) throw e as Error
        this.unavailableDesktop = desktop.deviceId + ':' + desktop.key
      }
    }
    return await this.catalog(latest)
  }

  private async catalog(project: RelayProject): Promise<FileListing> {
    if (project.projectUid === undefined) throw new ApiError(1, tr('files.desktopRequired'))
    return decodeFileListing(await this.request(`/api/mobile/catalog/${encodeURIComponent(project.projectUid)}/files`))
  }

  /** SDK canPreview checks existence + extension. Probe is local only; no network or charge precedes it. */
  async canOpen(file: ProjectFile): Promise<void> {
    validatePreview(file)
    await this.ensureActive()
    const path: string = `${this.directory}/probe-${util.generateRandomUUID(false)}.${fileExtension(file.name)}`
    const fd: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
    fs.closeSync(fd)
    try {
      if (!await filePreview.canPreview(ServiceLocator.ctx, fileUri.getUriFromPath(path))) throw new ApiError(1, tr('files.noPreviewApp'))
    } finally { this.remove(path) }
    await this.ensureActive()
  }

  async quote(file: ProjectFile): Promise<number> {
    validatePreview(file)
    const quote: Record<string, Object> = await this.request(`/api/mobile/transfer/quote?bytes=${Math.max(1, file.size)}`)
    const credits: number | undefined = getNumber(quote, 'credits')
    if (credits === undefined || !Number.isFinite(credits) || credits < 0) throw new ApiError(1, tr('files.error.response'))
    return credits
  }

  /** Returns whether desktop download is needed after refreshing physical source availability. */
  async useDesktop(project: RelayProject, file: ProjectFile): Promise<boolean> {
    const projects: RelayProject[] = await ServiceLocator.backend.myProjects()
    await this.ensureActive()
    const latest: RelayProject | undefined = projects.find((p: RelayProject): boolean => sameProject(p, project))
    if (latest === undefined) throw new ApiError(1, tr('files.error.response'))
    const online: boolean = latest.locations?.some((l: ProjectLocation): boolean => l.kind === 'desktop' && l.online === true &&
      l.deviceId === (file.deviceId ?? project.deviceId) && l.key === (file.projectKey ?? project.key)) === true
    if (file.source === 'cloud' || (file.source === undefined && project.deviceId === 'cloud') || file.source === 'backup') return false
    if ((!online && latest.locations !== undefined) || this.unavailableDesktop === `${file.deviceId}:${file.projectKey}`) throw new ApiError(1, tr('files.desktopRequired'))
    return true
  }

  private ledgerPath(project: RelayProject, file: ProjectFile): string {
    // Hash the session before persisting: cached charge identity must not expose a reusable credential.
    const identity: string = pullIdentity(this.baseUrl, this.sessionKey, project, file)
    // UUID filenames avoid filesystem name limits; ledger lookup compares complete identities.
    for (const name of fs.listFileSync(this.directory)) {
      if (!name.endsWith('.json')) continue
      const path: string = `${this.directory}/${name}`
      const o: Record<string, Object> | null = asRecord(ArkJson.parse(fs.readTextSync(path)))
      if (o !== null && getString(o, 'identity') === identity) return path
    }
    const path: string = `${this.directory}/${util.generateRandomUUID(false)}.json`
    const body: Record<string, Object> = { 'deviceId': file.deviceId ?? project.deviceId, 'projectKey': file.projectKey ?? project.key,
      'remoteFileId': file.id, 'fileName': file.name, 'fileSize': file.size, 'requestId': util.generateRandomUUID(false) }
    const row: Record<string, Object> = { 'identity': identity, 'body': body }
    this.writeLedger(path, row)
    return path
  }

  hasPending(project: RelayProject, file: ProjectFile): boolean {
    // A ledger without a server id still represents an uncertain charged request; retry its key.
    const identity: string = pullIdentity(this.baseUrl, this.sessionKey, project, file)
    return fs.listFileSync(this.directory).some((name: string): boolean => {
      if (!name.endsWith('.json')) return false
      const o: Record<string, Object> | null = asRecord(ArkJson.parse(fs.readTextSync(`${this.directory}/${name}`)))
      return o !== null && getString(o, 'identity') === identity
    })
  }

  async preview(project: RelayProject, file: ProjectFile, desktop: boolean): Promise<void> {
    validatePreview(file)
    await this.ensureActive()
    let path: string
    if (desktop) {
      path = await this.pull(project, file)
    } else {
      const consent = await ServiceLocator.backend.backupConsent()
      await this.ensureActive()
      if (!consent.enabled || !consent.subscriptionActive) throw new ApiError(1, tr('files.desktopRequired'))
      if (project.projectUid === undefined || file.uid === undefined) throw new ApiError(1, tr('files.error.response'))
      path = await this.download(`/api/mobile/preview/catalog/${encodeURIComponent(project.projectUid)}/files/${encodeURIComponent(file.uid)}/content`, file.size, fileExtension(file.name))
      this.completed.push(path)
    }
    await this.ensureActive()
    const info: filePreview.PreviewInfo = { uri: fileUri.getUriFromPath(path), title: file.name, mimeType: previewMime(path) }
    await filePreview.openPreview(ServiceLocator.ctx, info)
  }

  private async pull(project: RelayProject, file: ProjectFile): Promise<string> {
    const ledger: string = this.ledgerPath(project, file)
    const row: Record<string, Object> = asRecord(ArkJson.parse(fs.readTextSync(ledger)))!
    const body: Record<string, Object> | null = asRecord(row['body'])
    const originalName: string | undefined = body === null ? undefined : getString(body, 'fileName')
    if (body === null || originalName === undefined) throw new ApiError(1, tr('files.error.response'))
    let id: number | undefined = getNumber(row, 'id')
    if (id === undefined) {
      const created: Record<string, Object> = await this.request('/api/mobile/preview/pull', body)
      id = requiredId(created)
      row['id'] = id
      this.writeLedger(ledger, row)
    }
    let path: string | undefined = getString(row, 'path')
    if (path === undefined || !fs.accessSync(path)) {
      let transfer: Record<string, Object>
      try { transfer = await this.poll(id, 'PULL', 'STAGED') } catch (e) {
        if (e instanceof ApiError && e.code === 410) this.remove(ledger)
        throw e as Error
      }
      const size: number | undefined = getNumber(transfer, 'fileSize')
      if (size === undefined || !Number.isSafeInteger(size) || size < 0 || size > 200 * 1024 * 1024) throw new ApiError(1, tr('files.error.tooLarge'))
      path = await this.download(`/api/mobile/transfer/${id}/content`, size, fileExtension(originalName))
      row['path'] = path
      this.writeLedger(ledger, row)
    }
    if (row['acknowledged'] !== true) {
      const empty: Record<string, Object> = {}
      await this.request(`/api/mobile/transfer/${id}/ack`, empty)
      row['acknowledged'] = true
      this.writeLedger(ledger, row)
    }
    this.completed.push(path)
    this.completed.push(ledger)
    return path
  }

  private writeLedger(path: string, row: Record<string, Object>): void {
    const tmp: string = path + '.tmp'
    const fd: fs.File = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try { fs.writeSync(fd.fd, ArkJson.stringify(row)) } finally { fs.closeSync(fd) }
    fs.renameSync(tmp, path)
  }

  private async request(path: string, body: Record<string, Object> | null = null): Promise<Record<string, Object>> {
    await this.ensureActive()
    const result: Record<string, Object> = await ServiceLocator.backend.fileRequest(path, body, this.session)
    await this.ensureActive()
    return result
  }

  private async poll(id: number, kind: string, done: string): Promise<Record<string, Object>> {
    for (let attempt: number = 0; attempt < 60; attempt++) {
      const root: Record<string, Object> = await this.request(`/api/mobile/transfer/${id}`)
      const transfer: Record<string, Object> | null = asRecord(root['transfer'])
      if (transfer === null || getNumber(transfer, 'id') !== id || getString(transfer, 'kind') !== kind) throw new ApiError(1, tr('files.error.response'))
      if (getString(transfer, 'status') === done) return transfer
      if (getString(transfer, 'status') !== 'PENDING') throw new ApiError(getString(transfer, 'status') === 'FAILED' || getString(transfer, 'status') === 'EXPIRED' ? 410 : 1, tr('files.error.transferFailed'))
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 1000) })
    }
    throw new ApiError(1, tr('files.error.timeout'))
  }

  /** Streaming keeps the 200 MB limit off the JS heap and rejects non-byte/error responses before preview. */
  private async download(endpoint: string, size: number, ext: string): Promise<string> {
    await this.ensureActive()
    let used: number = 0
    for (const name of fs.listFileSync(this.directory)) {
      if (!name.endsWith('.json') && !name.endsWith('.tmp')) used += fs.statSync(`${this.directory}/${name}`).size
    }
    if (used + size > 200 * 1024 * 1024) throw new ApiError(1, tr('files.error.cacheFull'))
    const path: string = `${this.directory}/${util.generateRandomUUID(false)}.${ext}`
    const fd: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
    const client: http.HttpRequest = http.createHttp()
    this.client = client
    let complete: () => void = (): void => {}
    const ended: Promise<void> = new Promise<void>((resolve: () => void): void => { complete = resolve })
    this.finishStream = complete
    let streamEnded: boolean = false
    client.on('dataEnd', (): void => { streamEnded = true; complete() })
    const deadline: number = setTimeout((): void => { client.destroy(); complete() }, 60000)
    let bytes: number = 0
    let validHeaders: boolean = false
    let failed: boolean = false
    client.on('headersReceive', (headers: Object): void => {
      const values: Record<string, Object> = headers as Record<string, Object>
      for (const name of Object.keys(values)) {
        if (name.toLowerCase() === 'content-type') validHeaders = `${values[name]}`.split(';')[0].trim().toLowerCase() === 'application/octet-stream'
      }
      if (!validHeaders) { failed = true; client.destroy(); complete() }
    })
    client.on('dataReceive', (data: ArrayBuffer): void => {
      if (!this.active || !validHeaders || bytes + data.byteLength > size) { failed = true; client.destroy(); complete(); return }
      try {
        let offset: number = 0
        while (offset < data.byteLength) {
          const wrote: number = fs.writeSync(fd.fd, data.slice(offset))
          if (wrote <= 0) throw new Error('short write')
          offset += wrote
        }
        bytes += data.byteLength
      } catch (_) { failed = true; client.destroy(); complete() }
    })
    try {
      const header: Record<string, string> = { 'X-Session-Id': this.session }
      const options: http.HttpRequestOptions = { method: http.RequestMethod.GET, header: header, connectTimeout: 15000, readTimeout: 60000, maxRedirects: 0 }
      const status: number = await client.requestInStream(this.baseUrl + endpoint, options)
      await ended
      await this.ensureActive()
      if (status !== 200 || !streamEnded || failed || !validHeaders || bytes !== size) throw new ApiError(1, tr('files.error.transferFailed'))
      return path
    } catch (e) {
      this.remove(path)
      throw e as Error
    } finally { clearTimeout(deadline); fs.closeSync(fd); client.destroy(); if (this.client === client) this.client = null; this.finishStream = null }
  }

  private remove(path: string): void {
    try { if (fs.accessSync(path)) fs.unlinkSync(path) } catch (_) {}
  }
}

function requiredId(o: Record<string, Object>): number {
  const id: number | undefined = getNumber(o, 'id')
  if (id === undefined || !Number.isSafeInteger(id) || id <= 0) throw new ApiError(1, tr('files.error.response'))
  return id
}
