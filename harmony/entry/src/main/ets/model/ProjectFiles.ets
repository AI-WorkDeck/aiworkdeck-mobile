import { RelayProject } from './Capture'
import { ContractCapabilities } from 'contract'
import { tr } from '../design/L10n'
import { ApiError } from './Envelope'
import { asArray, asRecord, getBoolean, getNumber, getString } from '../services/ApiTypes'

export const MAX_PREVIEW_BYTES: number = 200 * 1024 * 1024
export interface ProjectFile {
  id: string
  uid?: string
  name: string
  path: string
  size: number
  source?: string
  deviceId?: string
  projectKey?: string
  online?: boolean
  isFolder?: boolean
}
export interface FileListing { files: ProjectFile[]; truncated: boolean }
export interface FileEntry { key: string; name: string; path: string; folder: boolean; file?: ProjectFile }
export interface BackupConsent { enabled: boolean; decided: boolean; subscriptionActive: boolean }

export function fileExtension(name: string): string {
  const dot: number = name.lastIndexOf('.')
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase()
}
export function validatePreview(file: ProjectFile): void {
  if (file.isFolder || !ContractCapabilities.previewExtensions.includes(fileExtension(file.name))) {
    throw new ApiError(1, tr('files.unsupported'))
  }
  if (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > MAX_PREVIEW_BYTES) {
    throw new ApiError(1, tr('files.error.tooLarge'))
  }
}
export function normalizedPath(path: string): string {
  return path.replace(/\\/g, '/').split('/').filter((p: string): boolean => p.length > 0 && p !== '.' && p !== '..').join('/')
}
export function folderEntries(files: ProjectFile[], folder: string = ''): FileEntry[] {
  const prefix: string = folder.length > 0 ? folder + '/' : ''
  const entries: Map<string, FileEntry> = new Map<string, FileEntry>()
  for (const file of files) {
    const path: string = normalizedPath(file.path || file.name)
    if (!path.startsWith(prefix) || path === folder) continue
    const parts: string[] = path.substring(prefix.length).split('/')
    if (parts.length > 1 || file.isFolder) {
      const child: string = prefix + parts[0]
      const entry: FileEntry = { key: 'folder:' + child, name: parts[0], path: child, folder: true }
      entries.set(entry.key, entry)
    } else {
      const key: string = 'file:' + (file.uid ?? `${file.deviceId ?? ''}:${file.projectKey ?? ''}:${file.id}`)
      const entry: FileEntry = { key: key, name: file.name, path: path, folder: false, file: file }
      entries.set(key, entry)
    }
  }
  return Array.from(entries.values()).sort((a: FileEntry, b: FileEntry): number =>
    Number(b.folder) - Number(a.folder) || a.name.localeCompare(b.name))
}
export function decodeFileListing(value: Object | null): FileListing {
  const root: Record<string, Object> | null = asRecord(value)
  const rows: Object[] | null = root === null ? null : asArray(root['files'])
  if (root === null || rows === null) throw new ApiError(1, tr('files.error.response'))
  const files: ProjectFile[] = []
  for (const row of rows) {
    const o: Record<string, Object> | null = asRecord(row)
    if (o === null) throw new ApiError(1, tr('files.error.response'))
    const id: string | undefined = getString(o, 'id')
    const name: string | undefined = getString(o, 'name')
    const size: number | undefined = getNumber(o, 'size')
    if (id === undefined || name === undefined || size === undefined || !Number.isSafeInteger(size) || size < 0) {
      throw new ApiError(1, tr('files.error.response'))
    }
    const file: ProjectFile = { id: id, name: name, size: size, path: getString(o, 'path') ?? name,
      uid: getString(o, 'uid'), source: getString(o, 'source'), deviceId: getString(o, 'deviceId'),
      projectKey: getString(o, 'projectKey'), online: getBoolean(o, 'online'), isFolder: getBoolean(o, 'isFolder') }
    files.push(file)
  }
  return { files: files, truncated: getBoolean(root, 'truncated') ?? files.length >= 2000 }
}
export function mergeLiveFiles(catalog: ProjectFile[], live: ProjectFile[]): ProjectFile[] {
  const files: ProjectFile[] = catalog.slice()
  for (const file of live) {
    const at: number = files.findIndex((other: ProjectFile): boolean =>
      (file.uid !== undefined && file.uid === other.uid) ||
      (file.id === other.id && file.deviceId === other.deviceId && file.projectKey === other.projectKey))
    if (at < 0) files.push(file)
    else {
      if (file.uid === undefined) file.uid = files[at].uid
      files[at] = file
    }
  }
  return files
}
export function decodeBackupConsent(value: Object | null): BackupConsent {
  const o: Record<string, Object> | null = asRecord(value)
  if (o === null || getBoolean(o, 'enabled') === undefined || getBoolean(o, 'decided') === undefined ||
    getBoolean(o, 'subscriptionActive') === undefined) throw new ApiError(1, tr('backup.error'))
  return { enabled: getBoolean(o, 'enabled')!, decided: getBoolean(o, 'decided')!, subscriptionActive: getBoolean(o, 'subscriptionActive')! }
}

export function previewMime(name: string): string {
  const types: Record<string, string> = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'bmp': 'image/bmp',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'pdf': 'application/pdf',
    'm4a': 'audio/mp4a-latm', 'mp3': 'audio/mpeg', 'wav': 'audio/x-wav', 'aac': 'audio/aac', 'mp4': 'video/mp4',
  }
  return types[fileExtension(name)] ?? 'application/octet-stream'
}

export function pullIdentity(baseUrl: string, sessionKey: string, project: RelayProject, file: ProjectFile): string {
  return JSON.stringify([baseUrl, sessionKey, project.projectUid ?? `${project.deviceId}:${project.key}`,
    file.uid ?? `${file.deviceId ?? project.deviceId}:${file.projectKey ?? project.key}:${file.id}`])
}
