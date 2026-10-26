import { getMetrics, metricsToStyle, type Metrics } from './utils/layout'
import { getGlassMode, type GlassMode } from './utils/capability'
import { recoverOnLaunch } from './utils/queue'
import { reportDiag } from './utils/diag'
import { initLocale, t } from './utils/i18n'

interface GlobalData {
  metrics: Metrics
  metricsStyle: string
  glassMode: GlassMode
}

App<{ globalData: GlobalData }>({
  globalData: {} as GlobalData,

  onLaunch() {
    initLocale()
    // 布局度量与渲染能力在启动时各算一次，全局复用。
    // 页面不许自己再调 getMenuButtonBoundingClientRect —— 那是顶部遮挡 bug 的来源。
    const metrics = getMetrics()
    this.globalData = {
      metrics,
      metricsStyle: metricsToStyle(metrics),
      glassMode: getGlassMode(),
    }

    // 上传队列的断点恢复：上次运行被杀时卡在上传中的条目回拨待上传接着传。
    recoverOnLaunch()

    // 真机诊断：体验版把脚本错误原文弹出来（dev-board#536 白屏定位）
    wx.onError((msg) => reportDiag(t('diag.scriptError'), String(msg)))
    wx.onUnhandledRejection((res) => reportDiag(t('diag.unhandledRejection'), String(res && res.reason)))
  },
})
