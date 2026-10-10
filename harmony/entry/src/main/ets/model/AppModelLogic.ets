import { CaptureItem, RelayProject, sameProject } from './Capture'
import { TransferState } from './TransferState'

/** 桌面端在线的判定窗口。项目列表由桌面端每分钟上报一次，三分钟没见着就当它离线了。 */
export const DESKTOP_ONLINE_WINDOW_MS: number = 180000

/**
 * 别的项目里还没落盘的件数。队列页末尾提一句，免得切了项目之后它们被完全藏起来
 * ——「没显示」和「没有」在现场是两件后果差很远的事。
 *
 * 没记项目的件（旧记录、选项目之前拍的）也算「别处」：它们同样不在当前项目的视图里。
 */
export function otherPendingCount(items: CaptureItem[], selected: RelayProject | null): number {
  let n: number = 0
  for (const it of items) {
    const matches: boolean = selected === null ? it.project === null :
      (it.project !== null && sameProject(it.project, selected))
    if (!matches && it.state !== TransferState.arrived) n++
  }
  return n
}

/**
 * 桌面端是否在线。lastSeenMs 是最近一次 myProjects() 成功、且返回里含当前项目所在设备的时刻；
 * 从没见过（null）一律离线。
 *
 * 宁可说离线也不要假装在线——用户看到「在线」会以为照片已经在往电脑走。
 */
export function isDesktopOnline(lastSeenMs: number | null, nowMs: number): boolean {
  if (lastSeenMs === null) return false
  const age: number = nowMs - lastSeenMs
  return age >= 0 && age < DESKTOP_ONLINE_WINDOW_MS
}
