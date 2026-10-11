import { PREVIEW_EXTENSIONS, MINIPROGRAM_PREVIEW_EXTENSIONS } from './contract/capabilities'

export interface ProjectFile {
  id: string
  uid?: string
  name: string
  path: string
  size: number
  source?: 'desktop' | 'cloud' | 'backup'
  deviceId?: string
  projectKey?: string
  online?: boolean
  isFolder?: boolean
}
export interface FileEntry { key: string; name: string; path: string; folder: boolean; file?: ProjectFile }
export type PreviewKind = 'image' | 'document' | 'audio' | 'video'
export function extension(name: string): string { return name.split('.').pop()?.toLowerCase() ?? '' }
export function previewKind(file: ProjectFile): PreviewKind | null {
  const ext = extension(file.name)
  if (file.isFolder || !MINIPROGRAM_PREVIEW_EXTENSIONS.includes(ext)) return null
  if (['docx', 'pptx', 'xlsx', 'pdf'].includes(ext)) return 'document'
  if (['m4a', 'mp3', 'wav', 'aac'].includes(ext)) return 'audio'
  if (ext === 'mp4') return 'video'
  return 'image'
}
export function unsupportedKey(file: ProjectFile): string {
  return PREVIEW_EXTENSIONS.includes(extension(file.name)) ? 'files.platformUnsupported' : 'files.unsupported'
}
export function normalizedPath(path: string): string {
  return path.replace(/\\/g, '/').split('/').filter(p => p && p !== '.' && p !== '..').join('/')
}
/** Render one level while retaining explicit empty folders and old desktop path-only listings. */
export function folderEntries(files: ProjectFile[], folder = ''): FileEntry[] {
  const prefix = folder ? folder + '/' : ''
  const entries = new Map<string, FileEntry>()
  for (const file of files) {
    const path = normalizedPath(file.path || file.name)
    if (!path.startsWith(prefix) || path === folder) continue
    const relative = path.slice(prefix.length)
    const segments = relative.split('/')
    if (segments.length > 1 || file.isFolder) {
      const child = prefix + segments[0]
      entries.set('folder:' + child, { key: 'folder:' + child, name: segments[0], path: child, folder: true })
    } else {
      const key = 'file:' + (file.uid ?? `${file.deviceId ?? ''}:${file.projectKey ?? ''}:${file.id}`)
      entries.set(key, { key, name: file.name, path, folder: false, file })
    }
  }
  return [...entries.values()].sort((a, b) => Number(b.folder) - Number(a.folder) || a.name.localeCompare(b.name))
}

/** Catalog keeps other sources; live rows replace their matching physical/canonical file only. */
export function mergeLiveFiles(catalog: ProjectFile[], live: ProjectFile[]): ProjectFile[] {
  const result = [...catalog]
  for (const file of live) {
    const index = result.findIndex(existing =>
      (file.uid && existing.uid === file.uid) ||
      (existing.id === file.id && existing.deviceId === file.deviceId && existing.projectKey === file.projectKey))
    if (index < 0) result.push(file)
    else result[index] = { ...result[index], ...file, uid: file.uid ?? result[index].uid }
  }
  return result
}
