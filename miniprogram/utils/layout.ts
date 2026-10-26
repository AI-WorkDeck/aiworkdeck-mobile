/**
 * 全局布局度量 —— 顶部遮挡问题的唯一真相来源。
 *
 * 「顶部菜单栏被遮挡」几乎全部源于每个页面各算各的导航高度。
 * 这里启动时算一次，全局复用；页面只读结果，不许自己再调
 * getMenuButtonBoundingClientRect。
 *
 * 安卓与 iOS 的差异都收在这个文件里：
 *  - statusBarHeight：刘海/挖孔/灵动岛机型差异很大，安卓部分机型还会返回 0
 *  - 胶囊按钮：安卓上的位置和高度与 iOS 不同，且冷启动瞬间可能返回全 0
 *  - 底部：iOS 有 Home Indicator，安卓有导航条或手势条
 */

export interface Metrics {
  /** 状态栏高度 px */
  statusBarHeight: number
  /** 导航栏内容区高度（不含状态栏）px */
  navContentHeight: number
  /** 状态栏 + 导航栏内容区，页面内容必须从这里往下开始 px */
  navTotalHeight: number
  /** 胶囊按钮左边界距屏幕右侧的距离 px —— 导航栏右侧安全留白 */
  capsuleRightInset: number
  /** 底部安全区（Home Indicator / 手势条）px */
  bottomInset: number
  /** 屏幕宽度 px */
  screenWidth: number
  /** 可用窗口高度 px */
  windowHeight: number
  /** 度量是否走了兜底值（真机上出现说明该机型需要单独看） */
  degraded: boolean
}

/** 胶囊拿不到时的兜底：微信规范里导航栏内容区就是 44pt */
const FALLBACK_NAV_CONTENT = 44
const FALLBACK_STATUS_BAR = 20

let cached: Metrics | null = null

export function getMetrics(): Metrics {
  if (cached) return cached

  const win = wx.getWindowInfo()
  let degraded = false

  let statusBarHeight = win.statusBarHeight ?? 0
  if (!statusBarHeight || statusBarHeight <= 0) {
    statusBarHeight = FALLBACK_STATUS_BAR
    degraded = true
  }

  // 冷启动瞬间安卓可能返回全 0，必须校验而不是直接用
  let capsule: WechatMiniprogram.ClientRect | null = null
  try {
    const r = wx.getMenuButtonBoundingClientRect()
    if (r && r.height > 0 && r.bottom > 0) capsule = r
  } catch {
    /* 落到兜底 */
  }

  let navContentHeight: number
  let capsuleRightInset: number

  if (capsule) {
    // 胶囊上下留白对称：内容区 = 胶囊高 + 上留白 * 2
    const gap = capsule.top - statusBarHeight
    navContentHeight = capsule.height + Math.max(gap, 0) * 2
    capsuleRightInset = win.screenWidth - capsule.left
  } else {
    navContentHeight = FALLBACK_NAV_CONTENT
    capsuleRightInset = 96
    degraded = true
  }

  // safeArea.bottom 在无 Home Indicator 的机型上等于 screenHeight，差值即为 0
  const safeArea = win.safeArea
  const bottomInset = safeArea
    ? Math.max(win.screenHeight - safeArea.bottom, 0)
    : 0

  cached = {
    statusBarHeight,
    navContentHeight,
    navTotalHeight: statusBarHeight + navContentHeight,
    capsuleRightInset,
    bottomInset,
    screenWidth: win.screenWidth,
    windowHeight: win.windowHeight,
    degraded,
  }

  if (degraded) {
    // 真机上看到这条，说明该机型的度量需要单独处理，不要忽略
    console.warn('[layout] fallback metrics used', cached)
  }

  return cached
}

/** 供 WXSS 使用的 CSS 变量串，挂在页面根节点的 style 上 */
export function metricsToStyle(m: Metrics = getMetrics()): string {
  return [
    `--nav-total: ${m.navTotalHeight}px`,
    `--nav-content: ${m.navContentHeight}px`,
    `--status-bar: ${m.statusBarHeight}px`,
    `--capsule-inset: ${m.capsuleRightInset}px`,
    `--bottom-inset: ${m.bottomInset}px`,
  ].join(';')
}
