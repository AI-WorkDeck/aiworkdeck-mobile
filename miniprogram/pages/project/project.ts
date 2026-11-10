import { defaultProject, getSelectedProject, myProjects, persistentCloudWritable, setSelectedProject } from '../../utils/api'
import type { ApiError, RelayProject } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import { Icon } from '../../utils/icons'
import { t } from '../../utils/i18n'
import { assignCapture } from '../../utils/queue'
import { sameProject } from '../../utils/project-catalog'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

interface ProjectRow {
  id: string
  project: RelayProject
  /** 当前拍摄目标打勾（指定归属时不打） */
  current: boolean
}

interface ProjectGroup {
  id: string
  title: string
  items: ProjectRow[]
}

/** 最近用过的项目（只存 id，最多 5 个）。项目条目不是凭据，存本地即可。 */
const KEY_RECENT = 'awd.recentProjects'

function projectKey(p: RelayProject): string {
  return p.projectUid || `${p.deviceId}:${p.key}`
}

function recentIds(): string[] {
  const v = wx.getStorageSync(KEY_RECENT)
  return Array.isArray(v) ? v : []
}

function useRecent(p: RelayProject): void {
  const id = projectKey(p)
  wx.setStorageSync(KEY_RECENT, [id, ...recentIds().filter((x) => x !== id)].slice(0, 5))
}

/**
 * 选择页只做一件事：尽快点到要的项目。
 * 顺序：最近用过（项目多于 6 个且没有搜索词时）→ 全部；有搜索词时只显示匹配。
 * 一个账号目录只列一次项目；实际存储地址留在模型中供上传路由使用。
 */
function buildGroups(list: RelayProject[], query: string, assigning: boolean): ProjectGroup[] {
  const selected = assigning ? null : getSelectedProject()
  const row = (p: RelayProject): ProjectRow => ({ id: projectKey(p), project: p, current: !!selected && !selected.isDefault && sameProject(p, selected) })
  const q = query.trim().toLowerCase()
  const matches = q ? list.filter((p) => p.name.toLowerCase().includes(q)) : list
  const recent = !q && list.length > 6
    ? recentIds().map((id) => list.find((p) => projectKey(p) === id)).filter((p): p is RelayProject => !!p)
    : []
  const groups: ProjectGroup[] = []
  if (recent.length) groups.push({ id: 'recent', title: t('project.recent'), items: recent.map(row) })
  if (matches.length) groups.push({ id: 'all', title: recent.length ? t('personal.allProjects') : '', items: matches.map(row) })
  return groups
}

Page({
  data: {
    Icon,
    ddTitle: t('dd.title'),
    ddOpen: t('dd.open'),
    emptyText: t('empty.projects'),
    navTitle: t('project.title'),
    defaultText: t('project.none'),
    noneHint: t('project.noneHint'),
    defaultCurrent: false,
    searchText: t('workspace.searchProjects'),
    noMatchText: t('project.noMatch'),
    query: '',
    total: 0,
    /** 只有项目分布在多台电脑上时，电脑名才帮得上忙 */
    showDevice: false,
    loadingText: t('common.loading'),
    refreshText: t('common.refresh'),
    retryText: t('project.retry'),
    filesText: t('project.files'),
    metrics: {} as Metrics,
    showBack: false,
    assigning: false,
    scrollTop: 0,
    loading: true,
    errorMessage: '',
    groups: [] as ProjectGroup[],
  },

  assignmentId: '',
  projects: [] as RelayProject[],

  onLoad(options: { assign?: string } = {}) {
    this.assignmentId = options.assign ?? ''
    const app = getApp<AppGlobal>()
    this.setData({
      metrics: app.globalData.metrics,
      assigning: !!this.assignmentId,
      ddTitle: t('dd.title'),
      ddOpen: t('dd.open'),
      emptyText: t('empty.projects'),
      navTitle: this.assignmentId ? t('library.assign') : t('project.title'),
      loadingText: t('common.loading'),
      refreshText: t('common.refresh'),
      retryText: t('project.retry'),
      filesText: t('project.files'),
      defaultText: t('project.none'),
      noneHint: t('project.noneHint'),
      searchText: t('workspace.searchProjects'),
      noMatchText: t('project.noMatch'),
      // 从 index「切换项目」navigateTo 过来时页面栈里还有上一页，可以返回；
      // 登录后的守门 reLaunch 过来时本页是栈底，不给返回按钮。
      showBack: getCurrentPages().length > 1,
    })
  },

  onOpenDd() { wx.navigateTo({ url: '/pages/dd-client/dd-client' }) },

  onShow() {
    this.setData({
      defaultText: t('project.none'),
      noneHint: t('project.noneHint'),
      searchText: t('workspace.searchProjects'),
      noMatchText: t('project.noMatch'),
      defaultCurrent: !this.assignmentId && (getSelectedProject() === null || getSelectedProject()?.isDefault === true),
    })
    this.loadProjects()
  },

  onQuery(e: { detail: { value: string } }) {
    this.setData({ query: e.detail.value, groups: buildGroups(this.projects, e.detail.value, !!this.assignmentId) })
  },

  onPageScroll(e: { scrollTop: number }) {
    const crossed = e.scrollTop > 4
    if (crossed !== (this.data.scrollTop > 4)) {
      this.setData({ scrollTop: e.scrollTop })
    }
  },

  onPullDownRefresh() {
    this.loadProjects(() => wx.stopPullDownRefresh())
  },

  loadProjects(done?: () => void) {
    this.setData({ loading: true, errorMessage: '' })
    myProjects()
      .then((list) => {
        this.projects = this.assignmentId ? list : list.filter(p => !p.isDefault)
        this.setData({
          loading: false,
          total: this.projects.length,
          showDevice: new Set(this.projects.map((p) => p.deviceName).filter(Boolean)).size > 1,
          groups: buildGroups(this.projects, this.data.query, !!this.assignmentId),
        })
      })
      .catch((err: ApiError) => {
        this.setData({ loading: false, errorMessage: err.message })
      })
      .finally(() => done?.())
  },

  async onDefault() {
    if (this.data.loading) return
    this.setData({ loading: true, errorMessage: '' })
    try {
      // Without persistent cloud storage the cloud scratch project refuses uploads: keep captures local.
      setSelectedProject(await persistentCloudWritable() ? await defaultProject() : null)
      wx.reLaunch({ url: '/pages/index/index' })
    } catch (err) { this.setData({ errorMessage: (err as ApiError).message }) }
    finally { this.setData({ loading: false }) }
  },

  onRetry() {
    this.loadProjects()
  },

  onRefresh() {
    this.loadProjects()
  },

  onOpenFiles(e: { currentTarget: { dataset: { gi: number; ii: number } } }) {
    const { gi, ii } = e.currentTarget.dataset
    setSelectedProject(this.data.groups[gi].items[ii].project)
    wx.navigateTo({ url: '/pages/files/files' })
  },

  onSelectProject(e: { currentTarget: { dataset: { gi: number; ii: number } } }) {
    const { gi, ii } = e.currentTarget.dataset
    const project = this.data.groups[gi].items[ii].project
    if (this.assignmentId) {
      if (assignCapture(this.assignmentId, project)) { useRecent(project); wx.navigateBack() }
      else wx.showToast({ title: t('library.assignFailed'), icon: 'none' })
      return
    }
    setSelectedProject(project)
    useRecent(project)
    wx.reLaunch({ url: '/pages/index/index' })
  },
})
