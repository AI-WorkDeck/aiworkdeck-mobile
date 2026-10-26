import { isRecording } from '../../utils/recorder'
/**
 * 图集 —— 影像浏览走深色（D7）。只看一个项目：默认当前项目，点标题切换看别的项目
 * （只切看的对象，不切拍摄目标）。项目内按自然日分段。列数、网格/列表、多选删除都在这一页。
 * 队列契约不动，本页只读 listItems / 调 removeItems。
 */

import { Icon } from '../../utils/icons'
import type { Metrics } from '../../utils/layout'
import { getSelectedProject } from '../../utils/api'
import { listItems, removeItems, subscribe, pollStatus, isAssigned, type QueueItem } from '../../utils/queue'
import {
  deleteWarning, dotClass, groupByDay, phaseLabels, projectsIn, stateText, tallyOf, PHASE_LABEL, type Tally,
} from '../../utils/phase'
import { thumbFor, markThumbBroken } from '../../utils/thumbs'
import { t } from '../../utils/i18n'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

/** 与队列页同一节奏：开着图集时状态变化要在眼前翻过来 */
const POLL_INTERVAL = 5000
const KEY_COLS = 'awd.gallery.cols'
const KEY_VIEW = 'awd.gallery.view'

interface Cell {
  clientMediaId: string
  mediaType: QueueItem['mediaType']
  /** 原件路径（留底路径或临时路径），全屏预览 / 播放用 */
  filePath: string
  thumb: string
  kindIcon: string
  time: string
  statusText: string
  errorText: string
  dotClass: string
  fileName: string
  createdAt: number
  checked: boolean
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  return `${`${d.getHours()}`.padStart(2, '0')}:${`${d.getMinutes()}`.padStart(2, '0')}`
}

function kindIcon(mediaType: QueueItem['mediaType']): string {
  if (mediaType === 'video') return Icon.videoWhite
  if (mediaType === 'audio') return Icon.micWhite
  return Icon.imageWhite
}

function readCols(): number {
  const v = wx.getStorageSync(KEY_COLS)
  return v === 2 || v === 3 || v === 4 ? v : 3
}

function readView(): 'grid' | 'list' {
  return wx.getStorageSync(KEY_VIEW) === 'list' ? 'list' : 'grid'
}

function viewLabelFor(view: 'grid' | 'list'): string {
  return view === 'grid' ? t('library.viewList') : t('library.viewGrid')
}

/** 视图切换按钮的无障碍标签：与按钮文字一样，说的是切过去的那一档 */
function viewA11yFor(view: 'grid' | 'list'): string {
  return view === 'grid' ? t('library.toList.a11y') : t('library.toGrid.a11y')
}

function colsA11yFor(cols: number): string {
  return t('library.columns.a11y', { n: cols })
}

function colsLabelFor(cols: number): string {
  return t('library.columns', { n: cols })
}

Page({
  data: {
    Icon,
    audioOnly: false,
    allLabel: t('library.all'),
    audioLabel: t('library.audio'),
    phaseLabel: PHASE_LABEL,
    metrics: {} as Metrics,
    scrollTop: 0,
    viewingId: '',
    viewingName: '',
    viewingUnassigned: false,
    unassignedHint: t('workspace.unassignedHint'),
    switchProjectHint: t('library.switchProjectHint'),
    projects: [] as Array<{ id: string; name: string }>,
    tally: { uploading: 0, failed: 0, staged: 0, landed: 0 } as Tally,
    failedSuffix: '',
    days: [] as Array<{ key: string; title: string; items: Cell[] }>,
    cols: 3,
    colsLabel: colsLabelFor(3),
    colsA11y: colsA11yFor(3),
    view: 'grid' as 'grid' | 'list',
    viewA11y: viewA11yFor('grid'),
    /** 按钮写的是切过去的那一档 */
    viewLabel: t('library.viewList'),
    selecting: false,
    selectedCount: 0,
    dockText: t('library.selectHint'),
    deleteLabel: '',
    selectLabel: t('library.select'),
    emptyText: t('library.empty'),
    emptyHint: t('library.emptyHint'),
  },

  unsubscribe: null as (() => void) | null,
  pollTimer: null as number | null,
  selected: new Set<string>(),
  /** 正在播放的录音（同一时刻最多一条） */
  audio: null as WechatMiniprogram.InnerAudioContext | null,
  audioId: '',

  onLoad() {
    const app = getApp<AppGlobal>()
    const view = readView()
    const cols = readCols()
    this.setData({
      metrics: app.globalData.metrics,
      cols,
      colsLabel: colsLabelFor(cols),
      colsA11y: colsA11yFor(cols),
      view,
      viewLabel: viewLabelFor(view),
      viewA11y: viewA11yFor(view),
    })
  },

  onShow() {
    this.refresh()
    if (!this.unsubscribe) this.unsubscribe = subscribe(() => this.refresh())
    this.onHide()
    this.pollTimer = setInterval(() => pollStatus(), POLL_INTERVAL)
  },

  onHide() {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
    this.stopAudio()
  },

  onUnload() {
    this.onHide()
    if (this.unsubscribe) {
      this.unsubscribe()
      this.unsubscribe = null
    }
  },

  onPageScroll(e: { scrollTop: number }) {
    const crossed = e.scrollTop > 4
    if (crossed !== (this.data.scrollTop > 4)) this.setData({ scrollTop: e.scrollTop })
  },

  refresh() {
    const current = getSelectedProject()
    const projects = projectsIn(listItems(), current ?? { deviceId: '', key: '', name: t('library.unknownProject') })
    const viewingId = projects.some((p) => p.id === this.data.viewingId)
      ? this.data.viewingId
      : projects[0].id
    const viewingName = projects.find((p) => p.id === viewingId)!.name
    const items = listItems(viewingId).filter((it) => !this.data.audioOnly || it.mediaType === 'audio')
    const cells: Cell[] = items.map((it) => ({
      clientMediaId: it.clientMediaId,
      mediaType: it.mediaType,
      filePath: it.filePath,
      thumb: thumbFor(it),
      kindIcon: kindIcon(it.mediaType),
      time: formatTime(it.createdAt),
      statusText: isAssigned(it) ? stateText(it.state) : t('library.unknownProject'),
      errorText: it.errorMessage || '',
      dotClass: dotClass(it.state),
      fileName: it.fileName,
      createdAt: it.createdAt,
      checked: this.selected.has(it.clientMediaId),
    }))
    const tally = tallyOf(items.filter(isAssigned))
    this.setData({
      allLabel: t('library.all'),
      audioLabel: t('library.audio'),
      phaseLabel: phaseLabels(),
      unassignedHint: t('workspace.unassignedHint'),
      switchProjectHint: t('library.switchProjectHint'),
      colsLabel: colsLabelFor(this.data.cols),
      colsA11y: colsA11yFor(this.data.cols),
      viewLabel: viewLabelFor(this.data.view),
      viewA11y: viewA11yFor(this.data.view),
      emptyText: t('library.empty'),
      emptyHint: t('library.emptyHint'),
      projects,
      viewingId,
      viewingName,
      viewingUnassigned: viewingId === ':',
      tally,
      failedSuffix: tally.failed > 0 ? t('tally.failedSuffix', { m: tally.failed }) : '',
      days: groupByDay(cells),
      selectedCount: this.selected.size,
      dockText: this.selected.size
        ? t('library.selectedCount', { n: this.selected.size })
        : t('library.selectHint'),
      deleteLabel: t('delete.title', { n: this.selected.size }),
      selectLabel: this.data.selecting ? t('common.cancel') : t('library.select'),
    })
  },

  // ---------- 切换看的项目 ----------

  onTitleTap() {
    const names = this.data.projects.map((p) => p.name)
    if (names.length <= 1) return
    // showActionSheet 最多 6 项；现场同时有记录的项目很少超过这个数
    wx.showActionSheet({
      itemList: names.slice(0, 6),
      success: (res) => {
        this.selected.clear()
        this.setData({ viewingId: this.data.projects[res.tapIndex].id, selecting: false })
        this.refresh()
      },
    })
  },

  // ---------- 列数 / 视图 ----------

  onToggleCols() {
    const cols = this.data.cols >= 4 ? 2 : this.data.cols + 1
    wx.setStorageSync(KEY_COLS, cols)
    this.setData({ cols, colsLabel: colsLabelFor(cols), colsA11y: colsA11yFor(cols) })
  },

  onToggleView() {
    const view = this.data.view === 'grid' ? 'list' : 'grid'
    wx.setStorageSync(KEY_VIEW, view)
    this.setData({ view, viewLabel: viewLabelFor(view), viewA11y: viewA11yFor(view) })
  },

  // ---------- 多选删除 ----------

  onToggleSelecting() {
    this.selected.clear()
    this.setData({ selecting: !this.data.selecting })
    this.refresh()
  },

  onTapCell(e: WechatMiniprogram.BaseEvent<WechatMiniprogram.IAnyObject, { id: string }>) {
    const id = e.currentTarget.dataset.id
    if (!this.data.selecting) {
      this.openViewer(id)
      return
    }
    if (this.selected.has(id)) this.selected.delete(id)
    else this.selected.add(id)
    this.refresh()
  },

  onAssign(e: WechatMiniprogram.BaseEvent<WechatMiniprogram.IAnyObject, { id: string }>) {
    const item = listItems().find(it => it.clientMediaId === e.currentTarget.dataset.id)
    if (!item || isAssigned(item)) return
    wx.navigateTo({ url: `/pages/project/project?assign=${encodeURIComponent(item.clientMediaId)}` })
  },

  // ---------- 全屏看大图：走系统接口（dev-board#387） ----------

  /**
   * 照片与录像用 wx.previewMedia：系统级全屏、左右滑同一天的其他件、缩放。
   * 它显示不了状态与哈希——核对在列表视图里看；全屏页的任务是看清画面。
   * 录音 previewMedia 不支持，用 InnerAudioContext 点播/点停。
   */
  openViewer(id: string) {
    const day = this.data.days.find((d) => d.items.some((c) => c.clientMediaId === id))
    const cell = day?.items.find((c) => c.clientMediaId === id)
    if (!day || !cell) return

    if (cell.mediaType === 'audio') {
      this.toggleAudio(cell)
      return
    }
    if (!cell.filePath) {
      wx.showToast({ title: t('library.fileMissing'), icon: 'none' })
      return
    }
    // previewMedia 最多 50 项；按同一天里能预览的件组
    const sources = day.items
      .filter((c) => c.mediaType !== 'audio' && c.filePath)
      .slice(0, 50)
      .map((c) => ({ url: c.filePath, type: c.mediaType as 'image' | 'video' }))
    const current = Math.max(0, sources.findIndex((s) => s.url === cell.filePath))
    wx.previewMedia({
      sources,
      current,
      fail: () => wx.showToast({ title: t('library.openFailed'), icon: 'none' }),
    })
  },

  onFilterAudio(e: WechatMiniprogram.TouchEvent) {
    this.setData({ audioOnly: e.currentTarget.dataset.audio === 'true' })
    this.selected.clear()
    this.stopAudio()
    this.refresh()
  },

  toggleAudio(cell: Cell) {
    if (isRecording()) {
      wx.showToast({ title: t('player.stopRecordingFirst'), icon: 'none' })
      return
    }
    if (this.audio && this.audioId === cell.clientMediaId) {
      this.stopAudio()
      return
    }
    this.stopAudio()
    if (!cell.filePath) {
      wx.showToast({ title: t('player.fileMissing'), icon: 'none' })
      return
    }
    const ctx = wx.createInnerAudioContext()
    ctx.obeyMuteSwitch = false
    ctx.src = cell.filePath
    ctx.onEnded(() => this.stopAudio())
    ctx.onError(() => {
      this.stopAudio()
      wx.showToast({ title: t('player.playFailed'), icon: 'none' })
    })
    ctx.play()
    this.audio = ctx
    this.audioId = cell.clientMediaId
    wx.showToast({ title: t('player.playingToast', { time: cell.time }), icon: 'none', duration: 2000 })
  },

  stopAudio() {
    if (this.audio) {
      this.audio.stop()
      this.audio.destroy()
      this.audio = null
      this.audioId = ''
    }
  },

  onDelete() {
    if (this.selected.size === 0) return
    const ids = Array.from(this.selected)
    const states = listItems(this.data.viewingId)
      .filter((it) => this.selected.has(it.clientMediaId))
      .map((it) => it.state)
    wx.showModal({
      title: t('delete.title', { n: ids.length }),
      content: deleteWarning(states),
      confirmText: t('library.delete'),
      confirmColor: '#B5483C', // danger（dev-board#731 #732 #733；原生 API 参数无法用 CSS 变量）
      success: (res) => {
        if (!res.confirm) return
        removeItems(ids)
        this.selected.clear()
        this.setData({ selecting: false })
        this.refresh()
      },
    })
  },

  onThumbError(e: WechatMiniprogram.BaseEvent<WechatMiniprogram.IAnyObject, { id: string }>) {
    markThumbBroken(e.currentTarget.dataset.id)
    this.refresh()
  },
})
