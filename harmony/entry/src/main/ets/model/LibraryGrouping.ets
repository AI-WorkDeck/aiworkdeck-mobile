import { ContractStates } from 'contract'
import { CaptureItem, RelayProject, projectId, sameProject } from './Capture'
import { TransferState, TransferPhase, TransferStateOps } from './TransferState'
import { tr } from '../design/L10n'

export interface DaySection {
  key: string
  title: string
  items: CaptureItem[]
}

export interface ProjectChoice {
  id: string
  name: string
}

/** 没记项目的件的归属桶。它们确实存在，只是不知道归谁，藏起来比放错地方更糟。 */
export const UNKNOWN_PROJECT: string = 'unknown'

export interface DeleteWarn {
  level: string
  n: number
}

function need(table: Record<string, string>, key: string): string {
  const v: string | undefined = table[key]
  if (v === undefined) throw new Error(`contract table has no key: ${key}`)
  return v
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`
}

/** 按本地自然日分段，新的在前；段内按时间倒序。段头「M月d日 · N 件」。 */
export function groupByDay(items: CaptureItem[]): DaySection[] {
  const buckets: Map<string, CaptureItem[]> = new Map<string, CaptureItem[]>()
  const keys: string[] = []
  for (const it of items) {
    const d: Date = new Date(it.capturedAtMs())
    const key: string = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`
    let bucket: CaptureItem[] | undefined = buckets.get(key)
    if (bucket === undefined) {
      bucket = []
      buckets.set(key, bucket)
      keys.push(key)
    }
    bucket.push(it)
  }
  keys.sort()
  keys.reverse()
  const sections: DaySection[] = []
  for (const key of keys) {
    const bucket: CaptureItem[] = buckets.get(key)!
    bucket.sort((a: CaptureItem, b: CaptureItem) => b.capturedAtMs() - a.capturedAtMs())
    const d: Date = new Date(bucket[0].capturedAtMs())
    const vars: Record<string, string | number> = {
      'm': d.getMonth() + 1, 'd': d.getDate(), 'n': bucket.length,
    }
    const section: DaySection = { key: key, title: tr('library.dayTitle', vars), items: bucket }
    sections.push(section)
  }
  return sections
}

/** 一件归哪个桶。没记项目（旧记录、选项目之前拍的）归「未知项目」。 */
function bucketOf(it: CaptureItem): string {
  const p: RelayProject | null = it.project
  return p === null ? UNKNOWN_PROJECT : projectId(p)
}

/** 正在看的那个项目里的件。 */
export function itemsIn(items: CaptureItem[], choiceId: string | null, current: RelayProject | null = null): CaptureItem[] {
  const reference: RelayProject | null = current !== null && projectId(current) === choiceId ? current :
    (items.find((it: CaptureItem): boolean => bucketOf(it) === choiceId)?.project ?? null)
  return items.filter((it: CaptureItem): boolean => reference !== null && it.project !== null
    ? sameProject(reference, it.project) : bucketOf(it) === choiceId)
}

/**
 * 可切换的项目：当前项目永远第一（哪怕它一件都还没有），其余有记录的按名称升序。
 * 名称按码点比，与安卓 `sortedBy { it.name }` 同口径——两端的菜单顺序得一样。
 */
export function projectsIn(items: CaptureItem[], current: RelayProject | null): ProjectChoice[] {
  const currentId: string | null = current === null ? null : projectId(current)
  const seen: Map<string, string> = new Map<string, string>()
  for (const it of items) {
    const id: string = bucketOf(it)
    if (id === currentId || seen.has(id) || (current !== null && it.project !== null && sameProject(current, it.project))) continue
    const p: RelayProject | null = it.project
    seen.set(id, p === null ? tr('library.unknownProject') : p.name)
  }
  const rest: ProjectChoice[] = []
  seen.forEach((name: string, id: string): void => {
    const choice: ProjectChoice = { id: id, name: name }
    rest.push(choice)
  })
  rest.sort((a: ProjectChoice, b: ProjectChoice): number => a.name < b.name ? -1 : (a.name > b.name ? 1 : 0))
  if (current === null) return rest
  const head: ProjectChoice = { id: projectId(current), name: current.name }
  return [head].concat(rest)
}

/** 删除确认等级：按所选里最坏的桶说话。n = 该桶件数；landed 时 n = 总数。 */
export function deleteWarningLevel(states: TransferState[]): DeleteWarn {
  for (const phase of ContractStates.deleteWarnOrder) {
    if (phase === 'landed') break
    let n: number = 0
    for (const s of states) {
      const p: string = TransferStateOps.phaseOf(s)
      if (p === phase) n++
    }
    if (n > 0) {
      const worst: DeleteWarn = { level: need(ContractStates.deleteWarnLevel, phase), n: n }
      return worst
    }
  }
  const landed: DeleteWarn = { level: need(ContractStates.deleteWarnLevel, 'landed'), n: states.length }
  return landed
}

export function deleteWarning(states: TransferState[]): string {
  const w: DeleteWarn = deleteWarningLevel(states)
  const vars: Record<string, string | number> = { 'n': w.n }
  return tr(need(ContractStates.deleteWarnKey, w.level), vars)
}
