import { ApiError, fileRequest, downloadProjectContent, getSession, backupConsent, uuid, type RelayProject } from './api'
import { previewKind, unsupportedKey, type ProjectFile } from './project-files'
import { t } from './i18n'

interface Transfer { id: number; kind: string; status: string; fileSize?: number; error?: string }
interface Pending { requestId: string; id?: number; path?: string; acknowledged?: boolean }
const KEY = 'awd.filePulls'
const MAX_BYTES = 200 * 1024 * 1024

export function validatePreview(file: ProjectFile): void {
  if (!previewKind(file)) throw new ApiError(-1, t(unsupportedKey(file)))
  if (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > MAX_BYTES) {
    throw new ApiError(-1, t('files.error.tooLarge'))
  }
}
function pullKey(project: RelayProject, file: ProjectFile): string {
  return JSON.stringify([getSession(), project.projectUid, file.uid, file.deviceId ?? project.deviceId,
    file.projectKey ?? project.key, file.id])
}
function ledger(): Record<string, Pending> { return wx.getStorageSync(KEY) || {} }
export function hasPendingPull(project: RelayProject, file: ProjectFile): boolean {
  return !!ledger()[pullKey(project, file)]
}
export async function previewQuote(file: ProjectFile): Promise<number> {
  validatePreview(file)
  const quote = await fileRequest<{ credits: number }>(`/api/mobile/transfer/quote?bytes=${Math.max(1, file.size)}`)
  return quote.credits
}
/** Save the idempotency key before the charged request; retry lost responses with that same key. */
export async function pullPreview(project: RelayProject, file: ProjectFile, active: () => boolean): Promise<string> {
  validatePreview(file)
  const session = getSession()
  const ensureActive = () => { if (!active() || !session || session !== getSession()) throw new ApiError(-1, t('files.error.closed')) }
  ensureActive()
  const key = pullKey(project, file)
  const pending = ledger()[key] ?? { requestId: uuid() }
  const save = () => { ensureActive(); wx.setStorageSync(KEY, { ...ledger(), [key]: pending }) }
  save()
  if (!pending.id) {
    const created = await fileRequest<{ id: number }>('/api/mobile/preview/pull', {
      deviceId: file.deviceId ?? project.deviceId, projectKey: file.projectKey ?? project.key,
      remoteFileId: file.id, fileName: file.name, fileSize: file.size, requestId: pending.requestId,
    })
    pending.id = created.id
    save()
  }
  if (!pending.path) {
    let staged: Transfer | undefined
    for (let i = 0; i < 60; i++) {
      ensureActive()
      const { transfer }: { transfer: Transfer } = await fileRequest<{ transfer: Transfer }>(`/api/mobile/transfer/${pending.id}`)
      if (transfer.id !== pending.id || transfer.kind !== 'PULL') throw new ApiError(-1, t('files.error.response'))
      if (transfer.status === 'STAGED') { staged = transfer; break }
      if (transfer.status === 'FAILED' || transfer.status === 'EXPIRED') {
        const rows = ledger(); delete rows[key]; wx.setStorageSync(KEY, rows)
        throw new ApiError(-1, transfer.error || t('files.error.transferFailed'))
      }
      if (transfer.status !== 'PENDING') throw new ApiError(-1, t('files.error.transferFailed'))
      await new Promise(resolve => setTimeout(resolve, 1000))
    }
    if (!staged) throw new ApiError(-1, t('files.error.timeout'))
    validatePreview({ ...file, size: staged.fileSize ?? -1 })
    const temporary = await downloadProjectContent(`/api/mobile/transfer/${pending.id}/content`, staged.fileSize!)
    ensureActive()
    pending.path = await new Promise<string>((resolve, reject) => {
      wx.getFileSystemManager().saveFile({ tempFilePath: temporary,
        success: result => resolve(result.savedFilePath), fail: reject })
    })
    try { save() } catch (error) {
      wx.getFileSystemManager().unlink({ filePath: pending.path, fail: () => {} })
      throw error
    }
  }
  if (!pending.acknowledged) {
    ensureActive()
    await fileRequest(`/api/mobile/transfer/${pending.id}/ack`, {})
    pending.acknowledged = true
    save()
  }
  ensureActive()
  return pending.path
}
export async function cloudPreview(project: RelayProject, file: ProjectFile, active: () => boolean = () => true): Promise<string> {
  validatePreview(file)
  const session = getSession()
  const consent = await backupConsent()
  if (!active() || !session || session !== getSession()) throw new ApiError(-1, t('files.error.closed'))
  if (!consent.enabled || !consent.subscriptionActive) throw new ApiError(-1, t('files.desktopRequired'))
  if (!project.projectUid || !file.uid) throw new ApiError(-1, t('files.error.response'))
  return downloadProjectContent(`/api/mobile/preview/catalog/${encodeURIComponent(project.projectUid)}/files/${encodeURIComponent(file.uid)}/content`, file.size)
}

/** Completed previews are page-scoped; unresolved charged transfers remain recoverable. */
export function clearCompletedPreviews(session: string | null): void {
  const rows = ledger()
  for (const [key, row] of Object.entries(rows)) {
    if (!row.acknowledged || JSON.parse(key)[0] !== session) continue
    if (row.path) wx.getFileSystemManager().unlink({ filePath: row.path, fail: () => {} })
    delete rows[key]
  }
  wx.setStorageSync(KEY, rows)
}
