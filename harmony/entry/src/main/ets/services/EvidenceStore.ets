import { fileIo as fs, hash } from '@kit.CoreFileKit'
import { JSON as ArkJson, util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import {
  CaptureItem, CaptureManifest, MediaKind, MediaKindOps, RelayProject, StoredRow,
} from '../model/Capture'
import { TransferState, TransferStateOps } from '../model/TransferState'
import { formatIso } from '../model/IsoTime'
import { Loc } from '../model/Loc'
import { DeviceFacts } from './DeviceFacts'
import { asRecord, decodeRelayProject, getBoolean, getNumber, getString } from './ApiTypes'

const DOMAIN: number = 0x0000
const TAG: string = 'EvidenceStore'
const KINDS: MediaKind[] = [MediaKind.photo, MediaKind.video, MediaKind.audio]

function parseKind(s: string): MediaKind | null {
  for (const k of KINDS) {
    const raw: string = k
    if (raw === s) return k
  }
  return null
}

function baseName(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.')
  return dot <= 0 ? fileName : fileName.substring(0, dot)
}

function decodeManifest(o: Record<string, Object>): CaptureManifest | null {
  const clientMediaId: string | undefined = getString(o, 'clientMediaId')
  const capturedAt: string | undefined = getString(o, 'capturedAt')
  if (clientMediaId === undefined || capturedAt === undefined) return null
  const m: CaptureManifest = {
    clientMediaId: clientMediaId,
    sha256: getString(o, 'sha256') ?? '',
    capturedAt: capturedAt,
    serverReceivedAt: getString(o, 'serverReceivedAt'),
    latitude: getNumber(o, 'latitude'),
    longitude: getNumber(o, 'longitude'),
    horizontalAccuracy: getNumber(o, 'horizontalAccuracy'),
    deviceModel: getString(o, 'deviceModel') ?? '',
    osVersion: getString(o, 'osVersion') ?? '',
    appVersion: getString(o, 'appVersion') ?? '',
    fromCamera: getBoolean(o, 'fromCamera') ?? true,
    tsaToken: getString(o, 'tsaToken'),
  }
  return m
}

function decodeRow(o: Record<string, Object>): StoredRow | null {
  const kind: string | undefined = getString(o, 'kind')
  const state: string | undefined = getString(o, 'state')
  const manifestObj: Record<string, Object> | null = asRecord(o['manifest'])
  if (kind === undefined || state === undefined || manifestObj === null) return null
  if (parseKind(kind) === null) return null
  const manifest: CaptureManifest | null = decodeManifest(manifestObj)
  if (manifest === null) return null
  const projectObj: Record<string, Object> | null = asRecord(o['project'])
  const project: RelayProject | null = projectObj === null ? null : decodeRelayProject(projectObj)
  const row: StoredRow = {
    kind: kind,
    state: state,
    progress: getNumber(o, 'progress') ?? 0,
    manifest: manifest,
    lastError: getString(o, 'lastError'),
    savedToAlbum: getBoolean(o, 'savedToAlbum'),
    project: project === null ? undefined : project,
  }
  return row
}

/**
 * 影像与归档信息的本地仓库。与 iOS / 安卓 EvidenceStore 同一套硬规矩：
 * 落盘顺序是「先原件、再算哈希、最后写 manifest」——manifest 存在即代表这条记录完整可信，
 * 中途崩溃只会留下孤儿原件，下次启动 sweepOrphans 扫掉。
 *
 * ArkTS 没有协程与互斥量，串行靠一把 Promise 链锁（run）：所有公开方法排成一条链，
 * 同一时刻只有一段在跑，链上某一段抛错也不会把后面的都带崩（chain 只记完成，不记结果）。
 */
export class EvidenceStore {
  private readonly root: string
  private readonly mediaDir: string
  private readonly manifestDir: string
  private readonly facts: DeviceFacts
  private chain: Promise<void> = Promise.resolve()
  private dirsReady: boolean = false

  constructor(root: string, facts: DeviceFacts) {
    this.root = root
    this.mediaDir = `${root}/media`
    this.manifestDir = `${root}/manifest`
    this.facts = facts
  }

  async save(kind: MediaKind, tempPath: string, capturedAtMs: number, loc: Loc | null,
    project: RelayProject | null): Promise<CaptureItem> {
    return await this.run<CaptureItem>(async (): Promise<CaptureItem> => {
      this.ensureDirs()
      const id: string = util.generateRandomUUID(false).toLowerCase()
      const dst: string = `${this.mediaDir}/${id}.${MediaKindOps.ext(kind)}`
      // Keep audio's source until its manifest commits, so a failed save is retryable.
      if (kind === MediaKind.audio) {
        await fs.copyFile(tempPath, dst)
      } else {
        // 1. 原件先落盘（同卷 move 优先；跨卷才退化到拷贝 + 删源）
        try {
          await fs.moveFile(tempPath, dst, 0)
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'moveFile fell back to copy: %{public}s', (e as Error).message)
          await fs.copyFile(tempPath, dst)
          try {
            await fs.unlink(tempPath)
          } catch (e2) {
            hilog.warn(DOMAIN, TAG, 'temp unlink failed: %{public}s', (e2 as Error).message)
          }
        }
      }
      // 2. 对落盘后的文件算哈希——要证明的是「磁盘上这个文件」没被改过，不是内存里的临时数据。
      //    hash.hash 由系统流式算，几百 MB 的录像也不进内存。
      const sha: string = (await hash.hash(dst, 'sha256')).toLowerCase()
      const manifest: CaptureManifest = {
        clientMediaId: id,
        sha256: sha,
        capturedAt: formatIso(capturedAtMs),
        latitude: loc === null ? undefined : loc.lat,
        longitude: loc === null ? undefined : loc.lon,
        horizontalAccuracy: loc === null || loc.accuracy === null ? undefined : loc.accuracy,
        deviceModel: this.facts.model,
        osVersion: this.facts.osVersion,
        appVersion: this.facts.appVersion,
        fromCamera: true,
      }
      const row: StoredRow = {
        kind: kind, state: TransferState.waiting, progress: 0, manifest: manifest,
        savedToAlbum: false, project: project === null ? undefined : project,
      }
      // 3. manifest 最后写：存在即完整
      this.writeRow(id, row)
      if (kind === MediaKind.audio) {
        try { await fs.unlink(tempPath) } catch (_) { /* committed copy is authoritative */ }
      }
      return this.toItem(id, row)
    })
  }

  /** 按采集时刻降序。解析不了的 manifest 跳过并记日志——不把坏记录变成界面上的空格子。 */
  async loadAll(): Promise<CaptureItem[]> {
    return await this.run<CaptureItem[]>(async (): Promise<CaptureItem[]> => this.loadAllLocked())
  }

  async updateState(id: string, to: TransferState, progress: number, error: string | null): Promise<void> {
    await this.run<void>(async (): Promise<void> => {
      const row: StoredRow | null = this.readRow(id)
      if (row === null) return
      // 成功时清掉旧的失败原因，否则界面会一直挂着上次那条已经不成立的错
      const updated: StoredRow = {
        kind: row.kind, state: to, progress: progress, manifest: row.manifest,
        lastError: to === TransferState.failed && error !== null ? error : undefined,
        savedToAlbum: row.savedToAlbum, project: row.project,
      }
      this.writeRow(id, updated)
    })
  }

  /** 旧记录上传时补记实际去向。只在 project 为空时写，不覆盖已有归属。 */
  async setProject(id: string, p: RelayProject): Promise<void> {
    await this.run<void>(async (): Promise<void> => {
      const row: StoredRow | null = this.readRow(id)
      if (row === null || row.project !== undefined || row.state !== TransferState.waiting) return
      const updated: StoredRow = {
        kind: row.kind, state: row.state, progress: row.progress, manifest: row.manifest,
        lastError: row.lastError, savedToAlbum: row.savedToAlbum, project: p,
      }
      this.writeRow(id, updated)
    })
  }

  async markSavedToAlbum(id: string): Promise<void> {
    await this.run<void>(async (): Promise<void> => {
      const row: StoredRow | null = this.readRow(id)
      if (row === null) return
      const updated: StoredRow = {
        kind: row.kind, state: row.state, progress: row.progress, manifest: row.manifest,
        lastError: row.lastError, savedToAlbum: true, project: row.project,
      }
      this.writeRow(id, updated)
    })
  }

  /** 用户主动删除：原件与 manifest 一起删。记录留着而原件没了，图集里会出现永远打不开的空格。 */
  async remove(ids: string[]): Promise<void> {
    await this.run<void>(async (): Promise<void> => {
      this.ensureDirs()
      const doomed: Set<string> = new Set<string>(ids)
      for (const name of this.list(this.mediaDir)) {
        if (doomed.has(baseName(name))) this.unlinkQuiet(`${this.mediaDir}/${name}`)
      }
      for (const id of ids) this.unlinkQuiet(`${this.manifestDir}/${id}.json`)
    })
  }

  /**
   * 清理孤儿原件：有文件没 manifest，说明上次写到一半崩了；没有哈希与采集环境，留着只会误导。
   *
   * 保留名单按磁盘上的 manifest **文件名**算，而不是 loadAll 解析出来的记录：解析不了的
   * manifest（写坏了、字段对不上）会被 loadAll 跳过，照那份名单扫就等于把还有 manifest 的
   * 原件也删了——现场不可复现，宁可留着一份待人工捞的原件。
   */
  async sweepOrphans(): Promise<number> {
    return await this.run<number>(async (): Promise<number> => {
      this.ensureDirs()
      const known: Set<string> = new Set<string>()
      for (const name of this.list(this.manifestDir)) {
        if (name.endsWith('.json')) known.add(baseName(name))
      }
      let removed: number = 0
      for (const name of this.list(this.mediaDir)) {
        if (known.has(baseName(name))) continue
        this.unlinkQuiet(`${this.mediaDir}/${name}`)
        removed++
      }
      return removed
    })
  }

  // ---- 内部 ----

  /** 一把 Promise 链锁。前一段无论成败都放行下一段，返回值仍走各自的 Promise。 */
  private run<R>(work: () => Promise<R>): Promise<R> {
    const result: Promise<R> = this.chain.then(work)
    this.chain = result.then((): void => {}, (): void => {})
    return result
  }

  private ensureDirs(): void {
    if (this.dirsReady) return
    for (const dir of [this.root, this.mediaDir, this.manifestDir]) {
      try {
        if (!fs.accessSync(dir)) fs.mkdirSync(dir, true)
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'mkdir failed: %{public}s', (e as Error).message)
      }
    }
    this.dirsReady = true
  }

  private list(dir: string): string[] {
    try {
      return fs.listFileSync(dir)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'listFile failed: %{public}s', (e as Error).message)
      return []
    }
  }

  private unlinkQuiet(path: string): void {
    try {
      fs.unlinkSync(path)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'unlink failed: %{public}s', (e as Error).message)
    }
  }

  private loadAllLocked(): CaptureItem[] {
    this.ensureDirs()
    const items: CaptureItem[] = []
    for (const name of this.list(this.manifestDir)) {
      if (!name.endsWith('.json')) continue
      const row: StoredRow | null = this.readRow(baseName(name))
      if (row === null) continue
      items.push(this.toItem(row.manifest.clientMediaId, row))
    }
    items.sort((a: CaptureItem, b: CaptureItem): number => b.capturedAtMs() - a.capturedAtMs())
    return items
  }

  private readRow(id: string): StoredRow | null {
    const path: string = `${this.manifestDir}/${id}.json`
    try {
      if (!fs.accessSync(path)) return null
      const o: Record<string, Object> | null = asRecord(ArkJson.parse(fs.readTextSync(path)))
      if (o === null) return null
      const row: StoredRow | null = decodeRow(o)
      if (row === null) hilog.warn(DOMAIN, TAG, 'skipped unreadable manifest %{public}s', id)
      return row
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'skipped unreadable manifest: %{public}s', (e as Error).message)
      return null
    }
  }

  private writeRow(id: string, row: StoredRow): void {
    const target: string = `${this.manifestDir}/${id}.json`
    const tmp: string = `${target}.tmp`
    const file: fs.File = fs.openSync(tmp,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, ArkJson.stringify(row))
    } finally {
      fs.closeSync(file)
    }
    try {
      fs.renameSync(tmp, target)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'rename fell back to copy: %{public}s', (e as Error).message)
      fs.copyFileSync(tmp, target)
      this.unlinkQuiet(tmp)
    }
  }

  /**
   * 解不出的 state（既非正式名也非别名）视为 failed，并把原始值记进 lastError 方便排查。
   * 这条 lastError 会显示在队列页上，故意写英文：它是内部诊断串，不是词典里的界面文案。
   */
  private toItem(id: string, row: StoredRow): CaptureItem {
    const state: TransferState | null = TransferStateOps.fromRaw(row.state)
    const kind: MediaKind | null = parseKind(row.kind)
    const resolvedKind: MediaKind = kind === null ? MediaKind.photo : kind
    const lastError: string | null = state === null
      ? `unknown state: ${row.state}`
      : (row.lastError === undefined ? null : row.lastError)
    return new CaptureItem(
      id,
      resolvedKind,
      state === null ? TransferState.failed : state,
      row.manifest,
      `${this.mediaDir}/${id}.${MediaKindOps.ext(resolvedKind)}`,
      row.progress,
      lastError,
      row.savedToAlbum === true,
      row.project === undefined ? null : row.project,
    )
  }
}
