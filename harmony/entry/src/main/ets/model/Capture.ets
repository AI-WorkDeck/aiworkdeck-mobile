import { TransferState } from './TransferState'
import { parseIso } from './IsoTime'

export enum MediaKind {
  photo = 'photo',
  video = 'video',
  audio = 'audio',
}

/** ArkTS 不许给 enum 挂方法，扩展名与媒体类型放静态类里。 */
export class MediaKindOps {
  static ext(k: MediaKind): string {
    if (k === MediaKind.photo) return 'jpg'
    if (k === MediaKind.video) return 'mp4'
    return 'm4a'
  }

  static mediaType(k: MediaKind): string {
    if (k === MediaKind.photo) return 'image'
    if (k === MediaKind.video) return 'video'
    return 'audio'
  }
}

/** 取证归档信息，字段与 iOS CaptureManifest.swift / 安卓 CaptureManifest 一致。时刻为 ISO8601 字符串。 */
export interface CaptureManifest {
  clientMediaId: string
  sha256: string
  capturedAt: string
  serverReceivedAt?: string
  latitude?: number
  longitude?: number
  horizontalAccuracy?: number
  deviceModel: string
  osVersion: string
  appVersion: string
  fromCamera: boolean
  tsaToken?: string
}

export interface ProjectLocation {
  kind: string
  deviceId: string
  deviceName?: string
  key: string
  online?: boolean
  archiveOnly?: boolean
}

export interface RelayProject {
  projectUid?: string
  locations?: ProjectLocation[]
  deviceId: string
  deviceName?: string
  key: string
  name: string
}

/** 项目标识。设备 + 项目键，跨设备重名的项目不会被并成一个。 */
export function projectId(p: RelayProject): string {
  return p.projectUid ?? `${p.deviceId}:${p.key}`
}

export function sameProject(a: RelayProject, b: RelayProject): boolean {
  if (a.projectUid !== undefined && b.projectUid !== undefined) return a.projectUid === b.projectUid
  const left: string[] = (a.locations ?? []).map((l: ProjectLocation): string => `${l.deviceId}:${l.key}`)
  left.push(`${a.deviceId}:${a.key}`)
  const right: string[] = (b.locations ?? []).map((l: ProjectLocation): string => `${l.deviceId}:${l.key}`)
  right.push(`${b.deviceId}:${b.key}`)
  return left.some((id: string): boolean => right.includes(id))
}

/** 落盘行，与 iOS StoredRow 同形。state 存正式名字符串。 */
export interface StoredRow {
  kind: string
  state: string
  progress: number
  manifest: CaptureManifest
  lastError?: string
  savedToAlbum?: boolean
  project?: RelayProject
}

export class CaptureItem {
  id: string
  kind: MediaKind
  state: TransferState
  manifest: CaptureManifest
  localPath: string
  progress: number
  lastError: string | null
  savedToAlbum: boolean
  project: RelayProject | null

  constructor(id: string, kind: MediaKind, state: TransferState, manifest: CaptureManifest,
    localPath: string, progress: number, lastError: string | null,
    savedToAlbum: boolean, project: RelayProject | null) {
    this.id = id
    this.kind = kind
    this.state = state
    this.manifest = manifest
    this.localPath = localPath
    this.progress = progress
    this.lastError = lastError
    this.savedToAlbum = savedToAlbum
    this.project = project
  }

  /** 采集时刻。解不出来算 0（纪元），排序时沉到最底，不会顶到列表最前面冒充最新。 */
  capturedAtMs(): number {
    const ms: number | null = parseIso(this.manifest.capturedAt)
    return ms === null ? 0 : ms
  }
}
