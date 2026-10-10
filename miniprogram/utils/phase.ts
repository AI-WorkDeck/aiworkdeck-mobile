/**
 * 传输阶段的展示层 —— 纯函数，不碰 wx。名称与文案全部来自 contract/（生成物在 ./contract/）。
 */
import {
  PHASE_OF, PHASE_LABEL_KEY, PHASE_DOT, FAILED_DOT, STATE_TEXT_KEY, STATE_DETAIL_KEY, DELETE_WARN_ORDER,
  DELETE_WARN_LEVEL, DELETE_WARN_KEY, type QueueState, type Phase,
} from './contract/states'
import { t } from './i18n'

export type { QueueState, Phase }

export const PHASE_LABEL: Record<Phase, string> = {
  uploading: t(PHASE_LABEL_KEY.uploading),
  staged: t(PHASE_LABEL_KEY.staged),
  landed: t(PHASE_LABEL_KEY.landed),
}

export function phaseOf(state: QueueState): Phase {
  return PHASE_OF[state]
}

/** 长形式：给有空间的行用（uploaded 出「已暂存 · 等待桌面端接收」）。 */
export function stateText(state: QueueState): string {
  return t(STATE_DETAIL_KEY[state])
}

/** 短形式：给窄行标签用（uploaded 只出「已暂存」）。 */
export function stateShortText(state: QueueState): string {
  return t(STATE_TEXT_KEY[state])
}

/** 点色类名由契约的令牌名派生：S.waiting → dot--waiting */
export function dotClass(state: QueueState): string {
  const token = state === 'failed' ? FAILED_DOT : PHASE_DOT[phaseOf(state)]
  return `dot--${token.split('.')[1]}`
}

export interface Tally { uploading: number; failed: number; staged: number; landed: number }

export function tallyOf(items: Array<{ state: QueueState }>): Tally {
  const tl: Tally = { uploading: 0, failed: 0, staged: 0, landed: 0 }
  for (const it of items) {
    tl[phaseOf(it.state)]++
    if (it.state === 'failed') tl.failed++
  }
  return tl
}

export function tallyTotal(tl: Tally): number {
  return tl.uploading + tl.staged + tl.landed
}

/** 项目标识：key 是桌面机本地 id，跨机同号不同物，必须连 deviceId。与 iOS RelayProject.id 同构。 */
export function projectId(p: { deviceId: string; projectKey: string; projectUid?: string }): string {
  return p.projectUid ?? `${p.deviceId}:${p.projectKey}`
}

export interface DaySection<T> {
  key: string
  title: string
  items: T[]
}

/** 按本机自然日分段，新的在前；段内按时间倒序。 */
export function groupByDay<T extends { createdAt: number }>(items: T[]): DaySection<T>[] {
  const map = new Map<string, { day: Date; items: T[] }>()
  for (const it of items) {
    const d = new Date(it.createdAt)
    const key = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`
    let g = map.get(key)
    if (!g) {
      g = { day: new Date(d.getFullYear(), d.getMonth(), d.getDate()), items: [] }
      map.set(key, g)
    }
    g.items.push(it)
  }
  return Array.from(map.entries())
    .sort((a, b) => b[1].day.getTime() - a[1].day.getTime())
    .map(([key, g]) => {
      const list = g.items.slice().sort((a, b) => b.createdAt - a.createdAt)
      return { key, title: t('library.dayTitle', { m: g.day.getMonth() + 1, d: g.day.getDate(), n: list.length }), items: list }
    })
}

/** 删除确认等级：按所选里最坏的桶说话。n = 该桶件数；landed 时 n = 总数。 */
export function deleteWarningLevel(states: QueueState[]): { level: 'unsent' | 'staged' | 'landed'; n: number } {
  for (const phase of DELETE_WARN_ORDER) {
    if (phase === 'landed') break
    const n = states.filter((s) => phaseOf(s) === phase).length
    if (n > 0) return { level: DELETE_WARN_LEVEL[phase], n }
  }
  return { level: 'landed', n: states.length }
}

export function deleteWarning(states: QueueState[]): string {
  const { level, n } = deleteWarningLevel(states)
  return t(DELETE_WARN_KEY[level], { n })
}

/** 可切换的项目：当前项目永远第一（哪怕还没拍），其余有记录的按名称排。 */
export function projectsIn(
  items: Array<{ deviceId: string; projectKey: string; projectName: string }>,
  current: { deviceId: string; key: string; name: string; projectUid?: string },
): Array<{ id: string; name: string }> {
  const curId = projectId({ deviceId: current.deviceId, projectKey: current.key, projectUid: current.projectUid })
  const seen = new Map<string, string>()
  for (const it of items) seen.set(projectId(it), it.projectName)
  seen.delete(curId)
  const rest = Array.from(seen.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN'))
  return [{ id: curId, name: current.name }, ...rest]
}
