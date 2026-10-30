import { Icon } from '../../utils/icons'
import type { Metrics } from '../../utils/layout'
import { getSelectedProject, captureOrganizationCaption, personalAccountScope } from '../../utils/api'
import { listItems, otherPendingCount, subscribe, pollStatus, retry, isAssigned, type QueueItem } from '../../utils/queue'
import { dotClass, phaseOf, projectId, stateText } from '../../utils/phase'
import { thumbFor, markThumbBroken } from '../../utils/thumbs'
import { t } from '../../utils/i18n'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

/** 队列轮询节奏：5 秒一次，见实施契约 §3 */
const POLL_INTERVAL = 5000

/** 一条队列记录在页面上展示用的精简结构 */
interface DisplayItem {
  clientMediaId: string
  /** 真实缩略图路径（照片原图 / 录像帧图），空串走占位色块 + 图标 */
  thumb: string
  /** 占位色块的媒体类别（沿用 doc/scene/audio 的既有配色） */
  kind: 'doc' | 'scene' | 'audio'
  kindIcon: string
  fileName: string
  time: string
  statusText: string
  waitingText: string
  /** failed 态的服务端/网络层可读错误原文（如「云端空间已满」），空串不渲染 */
  errorText: string
  /** 快到期的黄字提醒，空串不渲染 */
  expiresText: string
  dotClass: string
  canRetry: boolean
}

interface Section {
  title: string
  items: DisplayItem[]
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  const hh = `${d.getHours()}`.padStart(2, '0')
  const mm = `${d.getMinutes()}`.padStart(2, '0')
  return `${hh}:${mm}`
}

/** 桌面端离线不可隐瞒：uploaded 态等待超过 60 秒要明说等了多久 */
function waitingText(item: QueueItem): string {
  if (item.state !== 'uploaded') return ''
  const seconds = item.waitingSeconds ?? 0
  if (seconds < 60) return ''
  return t('home.desktop.waited', { t: t('time.minutesDuration', { n: Math.floor(seconds / 60) }) })
}

/** iOS 的 JSC 解析不带时区的 ISO 字符串不可靠，手工拆字段按本地时间构造 */
function parseLocalIso(s: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/.exec(s)
  if (!m) return null
  return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || '0')).getTime()
}

/** 已上传未抵达且剩余保存期不足 3 天：黄字催收，过期即删不可隐瞒 */
function expiresText(item: QueueItem): string {
  if (item.state !== 'uploaded' || !item.expiresAt) return ''
  const ts = parseLocalIso(item.expiresAt)
  if (ts === null) return ''
  if (ts - Date.now() >= 3 * 24 * 3600 * 1000) return ''
  const d = new Date(ts)
  return t('queue.expiresOn', { date: t('time.monthDay', { m: d.getMonth() + 1, d: d.getDate() }) })
}

function kindOf(mediaType: QueueItem['mediaType']): DisplayItem['kind'] {
  if (mediaType === 'video') return 'scene'
  if (mediaType === 'audio') return 'audio'
  return 'doc'
}

function kindIcon(mediaType: QueueItem['mediaType']): string {
  if (mediaType === 'video') return Icon.videoSlate
  if (mediaType === 'audio') return Icon.micSlate
  return Icon.imageSlate
}

function toDisplayItem(item: QueueItem): DisplayItem {
  return {
    clientMediaId: item.clientMediaId,
    thumb: thumbFor(item),
    kind: kindOf(item.mediaType),
    kindIcon: kindIcon(item.mediaType),
    fileName: item.organization && item.organizationScope === personalAccountScope() ? [captureOrganizationCaption(item.organization), item.organization.state === 'ready' ? item.organization.archiveName ?? item.organization.fileName ?? item.fileName : item.fileName, ...(item.organization.tags ?? [])].filter(Boolean).join(' · ') : item.fileName,
    time: formatTime(item.createdAt),
    statusText: item.state === 'uploading' ? t('organize.uploading') : stateText(item.state),
    waitingText: waitingText(item),
    errorText: item.state === 'failed' ? item.errorMessage || '' : '',
    expiresText: expiresText(item),
    dotClass: dotClass(item.state),
    canRetry: item.state === 'failed',
  }
}

Page({
  data: {
    metrics: {} as Metrics,
    scrollTop: 0,
    projectName: '',
    sections: [] as Section[],
    otherPending: 0,
    otherPendingText: '',
    titleText: t('queue.title'),
    retryText: t('project.retry'),
    emptyText: t('library.empty'),
  },

  unsubscribe: null as (() => void) | null,
  pollTimer: null as number | null,

  onLoad() {
    const app = getApp<AppGlobal>()
    this.setData({ metrics: app.globalData.metrics })
  },

  onShow() {
    this.refresh()
    if (!this.unsubscribe) {
      this.unsubscribe = subscribe(() => this.refresh())
    }
    this.startPolling()
  },

  onHide() {
    this.stopPolling()
  },

  onUnload() {
    this.stopPolling()
    if (this.unsubscribe) {
      this.unsubscribe()
      this.unsubscribe = null
    }
  },

  startPolling() {
    this.stopPolling()
    this.pollTimer = setInterval(() => {
      pollStatus()
    }, POLL_INTERVAL)
  },

  stopPolling() {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  },

  /** 只列当前项目，分四区；别的项目的未落盘件在末尾提一句，不完全藏起来 */
  refresh() {
    const project = getSelectedProject()
    const pid = projectId({ deviceId: project?.deviceId ?? '', projectKey: project?.key ?? '', projectUid: project?.projectUid })
    const all = listItems(pid).filter(isAssigned)
    const pick = (f: (it: QueueItem) => boolean) => all.filter(f).map(toDisplayItem)
    const sections: Section[] = [
      { title: t('queue.section.failed'), items: pick((it) => it.state === 'failed') },
      { title: t('queue.section.uploading'), items: pick((it) => it.state === 'waiting' || it.state === 'uploading') },
      { title: t('queue.section.staged'), items: pick((it) => phaseOf(it.state) === 'staged') },
      { title: t('queue.section.landed'), items: pick((it) => phaseOf(it.state) === 'landed') },
    ].filter((s) => s.items.length > 0)
    const otherPending = otherPendingCount(pid)
    this.setData({
      sections,
      projectName: project?.name ?? t('library.unknownProject'),
      otherPending,
      otherPendingText: t('library.otherPending', { n: otherPending }),
      titleText: t('queue.title'),
      retryText: t('project.retry'),
      emptyText: t('library.empty'),
    })
  },

  onPageScroll(e: { scrollTop: number }) {
    // 只在跨过阈值时 setData，避免每帧都触发渲染层通信
    const crossed = e.scrollTop > 4
    if (crossed !== (this.data.scrollTop > 4)) {
      this.setData({ scrollTop: e.scrollTop })
    }
  },

  onRetry(e: WechatMiniprogram.BaseEvent<WechatMiniprogram.IAnyObject, { id: string }>) {
    retry(e.currentTarget.dataset.id)
  },

  /** 缩略图渲染失败（临时文件被回收等）：记为 broken，刷新后回落占位 */
  onThumbError(e: WechatMiniprogram.BaseEvent<WechatMiniprogram.IAnyObject, { id: string }>) {
    markThumbBroken(e.currentTarget.dataset.id)
    this.refresh()
  },
})
