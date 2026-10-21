/**
 * 单飞上传队列 —— 拍摄 → 留底 → 上传 → 等桌面端接收 的全部状态机。
 *
 * 契约见 docs/specs/2026-08-20-miniprogram-real-api.md §3。持久化在
 * wx.setStorageSync('awd.queue', QueueItem[])，每次变更都落盘并通知订阅者，
 * 页面（index/queue）靠 subscribe 刷新，不自己维护一份队列状态。
 *
 * 轮询节奏由页面控制（onShow 起 5 秒间隔、onHide 清定时器），这里只提供
 * pollStatus() 单次查询。
 */

import { ApiError, getSession, mediaStatus, uploadMedia, uuid, type RelayProject } from './api'
import { projectId, tallyOf, type Tally } from './phase'
import { recover, applyStatus } from './transition'
import { t } from './i18n'
import { RETRY_DELAYS_MS, MAX_AUTO_RETRIES, type QueueState } from './contract/states'

export type { QueueState } from './contract/states'

const STORAGE_KEY = 'awd.queue'

export interface QueueItem {
  /** uuid()，幂等键，重传不产生重复件 */
  clientMediaId: string
  /** 照片_20260820_141516.jpg / 录像_20260820_141516_段1.mp4 / 录音_20260820_141516_段1.mp3 */
  fileName: string
  mediaType: 'image' | 'video' | 'audio'
  /** saveFile 后的沙盒路径；saveFile 失败时是临时路径 */
  filePath: string
  saved: boolean
  deviceId: string
  projectKey: string
  projectUid?: string
  projectName: string
  /** ISO8601 */
  capturedAt: string
  state: QueueState
  errorMessage?: string
  /** uploaded 态由 status 轮询回填 */
  waitingSeconds?: number
  /** 中转区到期时刻（ISO 本地时间字符串），uploaded 未抵达件由 status 轮询回填 */
  expiresAt?: string
  /** 录像/录音分段序号，从 1 起 */
  segmentIndex?: number
  /** Date.now()，列表排序与显示 HH:mm 用 */
  createdAt: number
  /** 已失败的次数，超过 MAX_AUTO_RETRIES 后不再自动重试，只留手动 retry() */
  attempts?: number
}

// ---------- 持久化 + 订阅通知 ----------

const listeners: Array<() => void> = []
const savingIds = new Set<string>()

export function subscribe(cb: () => void): () => void {
  listeners.push(cb)
  return () => {
    const idx = listeners.indexOf(cb)
    if (idx >= 0) listeners.splice(idx, 1)
  }
}

function notify(): void {
  listeners.forEach((cb) => cb())
}

function readItems(): QueueItem[] {
  const v = wx.getStorageSync(STORAGE_KEY)
  return Array.isArray(v) ? (v as QueueItem[]) : []
}

function writeItems(items: QueueItem[]): void {
  wx.setStorageSync(STORAGE_KEY, items)
  notify()
}

function updateItem(clientMediaId: string, mutate: (item: QueueItem) => void): boolean {
  const items = readItems()
  const item = items.find((it) => it.clientMediaId === clientMediaId)
  if (!item) return false
  mutate(item)
  writeItems(items)
  return true
}

// ---------- 查询 ----------

/** 新 → 旧。给 projectId 则只要该项目的。 */
export function listItems(projectIdFilter?: string): QueueItem[] {
  return readItems()
    .filter((it) => !projectIdFilter || projectId(it) === projectIdFilter)
    .sort((a, b) => b.createdAt - a.createdAt)
}

/** 三段计数，只数一个项目——进度跟着项目走。 */
export function tallyFor(projectIdFilter: string): Tally {
  return tallyOf(listItems(projectIdFilter).filter(isAssigned))
}

/** 别的项目里还没落盘的件数。队列页末尾提一句，免得它们被完全藏起来。 */
export function otherPendingCount(projectIdFilter: string): number {
  return readItems().filter((it) => isAssigned(it) && projectId(it) !== projectIdFilter && it.state !== 'arrived').length
}

/** 用户主动删除：原图（留底文件）与记录一起删。记录留着而图没了，图集里会出现永远打不开的空格。 */
export function removeItems(ids: string[]): void {
  const set = new Set(ids)
  const items = readItems()
  for (const it of items) {
    if (set.has(it.clientMediaId) && it.saved) removeSavedFile(it.filePath)
  }
  writeItems(items.filter((it) => !set.has(it.clientMediaId)))
}

/** Missing transport identity means local Unassigned media, never a server project. */
export function isAssigned(item: Pick<QueueItem, 'deviceId' | 'projectKey'>): boolean {
  return !!item.deviceId && !!item.projectKey
}

/** Assignment is one-way: an existing destination, even before upload, is immutable here. */
export function assignCapture(id: string, project: RelayProject): boolean {
  if (!project.deviceId || !project.key) return false
  const items = readItems()
  const item = items.find(it => it.clientMediaId === id)
  if (!item || item.deviceId || item.projectKey || item.projectUid || item.state !== 'waiting' || (item.attempts ?? 0) > 0) return false
  Object.assign(item, { deviceId: project.deviceId, projectKey: project.key,
    projectUid: project.projectUid, projectName: project.name })
  writeItems(items)
  processQueue()
  return true
}

// ---------- 文件名 ----------

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n)
}

function fileNameFor(mediaType: 'image' | 'video' | 'audio', at: Date, segmentIndex?: number): string {
  const stamp =
    `${at.getFullYear()}${pad2(at.getMonth() + 1)}${pad2(at.getDate())}_` +
    `${pad2(at.getHours())}${pad2(at.getMinutes())}${pad2(at.getSeconds())}`
  if (mediaType === 'image') {
    return `照片_${stamp}.jpg`
  }
  if (mediaType === 'audio') {
    return `录音_${stamp}_段${segmentIndex ?? 1}.mp3`
  }
  return `录像_${stamp}_段${segmentIndex ?? 1}.mp4`
}

// ---------- 入队 ----------

/**
 * 尝试用 FileSystemManager.saveFile 把临时文件留底到沙盒（不进相册，D4）；
 * 拍摄用的 tempFilePath 在当次运行结束后可能被系统回收，留底失败就继续用
 * 临时路径上传（saved 保持 false，不阻塞流程）。
 */
export function enqueueCapture(
  tempFilePath: string,
  mediaType: 'image' | 'video' | 'audio',
  project: RelayProject | null,
  segmentIndex?: number,
  onSaved?: (saved: boolean) => void,
): QueueItem {
  const now = new Date()
  const item: QueueItem = {
    clientMediaId: uuid(),
    fileName: fileNameFor(mediaType, now, segmentIndex),
    mediaType,
    filePath: tempFilePath,
    saved: false,
    deviceId: project?.deviceId ?? '',
    projectKey: project?.key ?? '',
    projectUid: project?.projectUid,
    projectName: project?.name ?? t('library.unknownProject'),
    capturedAt: now.toISOString(),
    state: 'waiting',
    segmentIndex,
    createdAt: now.getTime(),
  }

  savingIds.add(item.clientMediaId)
  const items = readItems()
  items.push(item)
  writeItems(items)

  let reported = false
  const report = (saved: boolean) => {
    if (reported) return
    reported = true
    savingIds.delete(item.clientMediaId)
    if (!saved && !project && mediaType !== 'audio' && readItems().some(it => it.clientMediaId === item.clientMediaId)) {
      const message = t('capture.saveFailed')
      try { updateItem(item.clientMediaId, it => { it.errorMessage = message }) } catch { /* Still show the failure if metadata cannot be written. */ }
      wx.showModal({ title: t('library.unknownProject'), content: message, showCancel: false })
    }
    onSaved?.(saved)
  }
  try {
    wx.getFileSystemManager().saveFile({
      tempFilePath,
      success: (res) => {
        try {
          const retained = updateItem(item.clientMediaId, (it) => {
            it.filePath = res.savedFilePath
            it.saved = true
          })
          if (!retained) {
            removeSavedFile(res.savedFilePath)
            report(false)
            return
          }
        } catch { report(false); return }
        report(true)
        processQueue()
      },
      fail: () => {
        // 留底失败：保持临时路径继续（saved 已是 false），不影响上传。
        report(false)
        processQueue()
      },
    })
  } catch {
    report(false)
    processQueue()
  }

  return item
}

// ---------- 上传（单飞） ----------

let uploading = false

/** 失败后延迟回拨成 waiting 再续队列；不是忙循环。 */
function scheduleRetry(clientMediaId: string, attempts: number): void {
  const delay = RETRY_DELAYS_MS[attempts - 1]
  setTimeout(() => {
    updateItem(clientMediaId, (it) => {
      if (it.state === 'failed') it.state = 'waiting'
    })
    processQueue()
  }, delay)
}

/**
 * 启动恢复（app.onLaunch 调一次）：单飞锁只在内存里，上次运行在上传途中被杀的话
 * 条目会永远卡在 uploading 态——回拨成 waiting 接着传。未登录时不动队列，
 * 免得启动期就触发 4010 跳转，登录后守门页面自然会带起 processQueue。
 */
export function recoverOnLaunch(): void {
  const items = readItems()
  let changed = false
  for (const it of items) {
    const to = recover(it.state, it.attempts ?? 0)
    if (to !== it.state) { it.state = to; changed = true }
  }
  if (changed) writeItems(items)
  if (getSession()) processQueue()
}

/** 逐个（单飞）把 waiting → uploading → uploaded；失败 → failed，继续下一个。 */
export function processQueue(): void {
  if (uploading) return
  const next = readItems().find((it) => it.state === 'waiting' && isAssigned(it) && !savingIds.has(it.clientMediaId))
  if (!next) return

  uploading = true
  updateItem(next.clientMediaId, (it) => {
    it.state = 'uploading'
    it.errorMessage = undefined
  })

  uploadMedia({
    filePath: next.filePath,
    deviceId: next.deviceId,
    projectKey: next.projectKey,
    clientMediaId: next.clientMediaId,
    fileName: next.fileName,
    mediaType: next.mediaType,
    capturedAt: next.capturedAt,
  })
    .then(() => {
      updateItem(next.clientMediaId, (it) => {
        it.state = 'uploaded'
      })
      uploading = false
      processQueue()
    })
    .catch((e: unknown) => {
      uploading = false
      if (e instanceof ApiError && e.code === 4010) {
        // api 层已经清会话并 reLaunch 到登录页了，这里停住即可，
        // 不重复弹窗、不继续处理队列（登录后由页面重新触发）。
        return
      }
      const attempts = (next.attempts ?? 0) + 1
      updateItem(next.clientMediaId, (it) => {
        it.state = 'failed'
        it.errorMessage = e instanceof Error ? e.message : t('state.failed')
        it.attempts = attempts
      })
      if (attempts <= MAX_AUTO_RETRIES) {
        scheduleRetry(next.clientMediaId, attempts)
      }
      processQueue()
    })
}

export function retry(clientMediaId: string): void {
  updateItem(clientMediaId, (it) => {
    if (it.state === 'failed') {
      it.state = 'waiting'
      it.errorMessage = undefined
      it.attempts = 0
    }
  })
  processQueue()
}

// ---------- 状态轮询 ----------

function removeSavedFile(filePath: string): void {
  try {
    wx.getFileSystemManager().removeSavedFile({
      filePath,
      fail: () => {
        /* 留底文件删不掉不影响主流程，忽略 */
      },
    })
  } catch {
    /* 忽略 */
  }
}

/**
 * 只对 state === 'uploaded' 的项查状态；没有这类项直接 resolve(false)，不发请求。
 * delivered → arrived（本地留底**不自动删**——现场不可复现，与 iOS 同一口径，
 * 删除只由用户在图集里主动做）；未 delivered → 回填 waitingSeconds。
 * 返回值：这批查询里是否还有项未抵达（供页面判断要不要继续等）。
 */
export function pollStatus(): Promise<boolean> {
  const uploaded = readItems().filter((it) => it.state === 'uploaded')
  if (uploaded.length === 0) return Promise.resolve(false)

  return mediaStatus(uploaded.map((it) => it.clientMediaId)).then((statuses) => {
    const byId = new Map(statuses.map((s) => [s.clientMediaId, s]))
    let stillPending = false

    for (const it of uploaded) {
      const status = byId.get(it.clientMediaId)
      if (!status) continue
      const merged = applyStatus(it.state, status)
      updateItem(it.clientMediaId, (x) => {
        x.state = merged.state
        if (merged.waitingSeconds === null) delete x.waitingSeconds; else x.waitingSeconds = merged.waitingSeconds
        if (merged.expiresAt === null) delete x.expiresAt; else x.expiresAt = merged.expiresAt
      })
      if (merged.state === 'uploaded') stillPending = true
    }

    return stillPending
  })
}
