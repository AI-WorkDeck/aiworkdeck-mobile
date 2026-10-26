import { MAX_AUTO_RETRIES, TRANSITIONS, type QueueState, type TransferEvent } from './contract/states'

function guardOk(guard: string | undefined, attempts: number): boolean {
  if (!guard) return true
  if (guard === 'attempts <= maxAutoRetries') return attempts <= MAX_AUTO_RETRIES
  throw new Error(`contract guard unknown: ${guard}`)
}

/** 迁移表驱动。无匹配规则 → null（非法迁移，调用方应拒绝并记日志）；有规则但 guard 不满足 → 原态。 */
export function next(state: QueueState, event: TransferEvent, attempts = 0): QueueState | null {
  const rules = TRANSITIONS.filter((r) => r.from === state && r.event === event)
  if (rules.length === 0) return null
  for (const r of rules) if (guardOk(r.guard, attempts)) return r.to
  return state
}

/** 冷启动回拨 = app_launch 事件；不适用的状态原样返回。 */
export function recover(state: QueueState, attempts = 0): QueueState {
  return next(state, 'app_launch', attempts) ?? state
}

export interface StatusResponse { delivered: boolean; waitingSeconds: number; expiresAt?: string }
export interface StatusMerge { state: QueueState; waitingSeconds: number | null; expiresAt: string | null }

/** status 轮询只对 uploaded 件有意义；delivered 清掉等待字段，pending 回填。 */
export function applyStatus(state: QueueState, status: StatusResponse): StatusMerge {
  if (state !== 'uploaded') return { state, waitingSeconds: null, expiresAt: null }
  if (status.delivered) return { state: next(state, 'status_delivered') ?? state, waitingSeconds: null, expiresAt: null }
  return { state: next(state, 'status_pending') ?? state, waitingSeconds: status.waitingSeconds, expiresAt: status.expiresAt ?? null }
}
