import { myProjects, setSelectedProject } from '../../utils/api'
import type { ApiError, RelayProject } from '../../utils/api'
import type { Metrics } from '../../utils/layout'
import { Icon } from '../../utils/icons'
import { t } from '../../utils/i18n'

interface AppGlobal {
  globalData: { metrics: Metrics }
}

interface ProjectGroup {
  deviceId: string
  deviceName: string
  items: RelayProject[]
}

/** 一个账号目录只列一次项目；实际存储地址留在模型中供上传路由使用。 */
function catalogGroup(list: RelayProject[]): ProjectGroup[] {
  return list.length ? [{ deviceId: 'catalog', deviceName: t('project.title'), items: list }] : []
}

Page({
  data: {
    Icon,
    emptyText: t('empty.projects'),
    navTitle: t('project.title'),
    retryText: t('project.retry'),
    filesText: t('project.files'),
    metrics: {} as Metrics,
    showBack: false,
    scrollTop: 0,
    loading: true,
    errorMessage: '',
    groups: [] as ProjectGroup[],
  },

  onLoad() {
    const app = getApp<AppGlobal>()
    this.setData({
      metrics: app.globalData.metrics,
      // 从 index「切换项目」navigateTo 过来时页面栈里还有上一页，可以返回；
      // 登录后的守门 reLaunch 过来时本页是栈底，不给返回按钮。
      showBack: getCurrentPages().length > 1,
    })
  },

  onShow() {
    this.loadProjects()
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
        this.setData({ loading: false, groups: catalogGroup(list) })
      })
      .catch((err: ApiError) => {
        this.setData({ loading: false, errorMessage: err.message })
      })
      .finally(() => done?.())
  },

  onRetry() {
    this.loadProjects()
  },

  onRefresh() {
    this.loadProjects()
  },

  onOpenFiles(e: { currentTarget: { dataset: { gi: number; ii: number } } }) {
    const { gi, ii } = e.currentTarget.dataset
    setSelectedProject(this.data.groups[gi].items[ii])
    wx.navigateTo({ url: '/pages/files/files' })
  },

  onSelectProject(e: { currentTarget: { dataset: { gi: number; ii: number } } }) {
    const { gi, ii } = e.currentTarget.dataset
    const project = this.data.groups[gi].items[ii]
    setSelectedProject(project)
    wx.reLaunch({ url: '/pages/index/index' })
  },
})
