import { RelayProject, ProjectLocation } from '../model/Capture'
import { ApiError } from '../model/Envelope'

/**
 * /api/mobile 的响应形状（`contract/api/mobile-v1.yaml`），字段与安卓 ApiTypes.kt 逐字一致。
 *
 * ArkTS 没有 kotlinx.serialization 那样的反射解码，`JSON.parse` 出来的是 `Object`，
 * 只能一个字段一个字段判类型再取——本文件下半段的 decodeXxx 就是这件事。
 * 少一个必填字段就当整条解不出（返回 null / 抛 ApiError），宁可报错也不要拿默认值冒充服务端数据。
 */

export interface AccountUser {
  id: number
  username: string
  displayName: string
  avatarUrl?: string
  role?: string
}

export interface LoginResult {
  sessionId: string
  isNewUser?: boolean
  mustBindPhone?: boolean
  user: AccountUser
}

export interface MediaStatus {
  projectUid?: string
  fileUid?: string
  fileId?: number
  clientMediaId: string
  delivered: boolean
  waitingSeconds: number
  expiresAt?: string
}

export interface MediaUsage {
  usedBytes: number
  quotaBytes: number
  persistentUsedBytes?: number
  persistentQuotaBytes?: number
  persistentQuotaAvailable?: boolean
}

export interface SubscriptionBalance {
  active: boolean
  availableCents: number
  monthlyLimitCents: number
  monthlyUsedCents: number
  weeklyLimitCents: number
  weeklyUsedCents: number
}

export interface UploadResult {
  projectUid?: string
  fileUid?: string
  fileId?: number
  code: number
  id: number
  clientMediaId: string
  delivered: boolean
}

// ---- 取值助手 ----

/** 解析结果是不是一个对象（数组不算）。 */
export function asRecord(v: Object | null | undefined): Record<string, Object> | null {
  if (v === undefined || v === null) return null
  if (v instanceof Array) return null
  if (typeof v !== 'object') return null
  return v as Record<string, Object>
}

export function asArray(v: Object | null | undefined): Object[] | null {
  if (v === undefined || v === null) return null
  if (!(v instanceof Array)) return null
  return v as Object[]
}

export function getString(o: Record<string, Object>, k: string): string | undefined {
  const v: Object | undefined = o[k]
  return typeof v === 'string' ? v as string : undefined
}

export function getNumber(o: Record<string, Object>, k: string): number | undefined {
  const v: Object | undefined = o[k]
  return typeof v === 'number' ? v as number : undefined
}

export function getBoolean(o: Record<string, Object>, k: string): boolean | undefined {
  const v: Object | undefined = o[k]
  return typeof v === 'boolean' ? v as boolean : undefined
}

// ---- 解码 ----

export function decodeRelayProject(o: Record<string, Object>): RelayProject | null {
  const deviceId: string | undefined = getString(o, 'deviceId')
  const key: string | undefined = getString(o, 'key')
  const name: string | undefined = getString(o, 'name')
  if (deviceId === undefined || key === undefined || name === undefined) return null
  const p: RelayProject = {
    deviceId: deviceId, deviceName: getString(o, 'deviceName'), key: key, name: name,
    projectUid: getString(o, 'projectUid'), locations: decodeLocations(o['locations']),
  }
  return p
}

export function decodeRelayProjects(v: Object | null): RelayProject[] {
  const arr: Object[] | null = asArray(v)
  if (arr === null) return []
  const out: RelayProject[] = []
  for (const raw of arr) {
    const o: Record<string, Object> | null = asRecord(raw)
    if (o === null) continue
    const p: RelayProject | null = decodeRelayProject(o)
    if (p !== null) out.push(p)
  }
  return out
}

export function decodeAccountUser(o: Record<string, Object>): AccountUser {
  const u: AccountUser = {
    id: getNumber(o, 'id') ?? 0,
    username: getString(o, 'username') ?? '',
    displayName: getString(o, 'displayName') ?? '',
    avatarUrl: getString(o, 'avatarUrl'),
    role: getString(o, 'role'),
  }
  return u
}

export function decodeLoginResult(data: Record<string, Object>): LoginResult {
  const sessionId: string | undefined = getString(data, 'sessionId')
  if (sessionId === undefined || sessionId.length === 0) throw new ApiError(1, 'login response without sessionId')
  const userObj: Record<string, Object> | null = asRecord(data['user'])
  if (userObj === null || (getNumber(userObj, 'id') ?? 0) <= 0 || getString(userObj, 'username') === undefined || getString(userObj, 'displayName') === undefined) {
    throw new ApiError(1, 'login response without user identity')
  }
  const r: LoginResult = {
    sessionId: sessionId,
    isNewUser: getBoolean(data, 'isNewUser'),
    mustBindPhone: getBoolean(data, 'mustBindPhone'),
    user: decodeAccountUser(userObj),
  }
  return r
}

export function decodeMediaStatuses(v: Object | null): MediaStatus[] {
  const arr: Object[] | null = asArray(v)
  if (arr === null) return []
  const out: MediaStatus[] = []
  for (const raw of arr) {
    const o: Record<string, Object> | null = asRecord(raw)
    if (o === null) continue
    const id: string | undefined = getString(o, 'clientMediaId')
    if (id === undefined) continue
    const s: MediaStatus = {
      clientMediaId: id,
      delivered: getBoolean(o, 'delivered') ?? false,
      waitingSeconds: getNumber(o, 'waitingSeconds') ?? 0,
      expiresAt: getString(o, 'expiresAt'),
      projectUid: getString(o, 'projectUid'), fileUid: getString(o, 'fileUid'), fileId: getNumber(o, 'fileId'),
    }
    out.push(s)
  }
  return out
}

export function decodeMediaUsage(v: Object | null): MediaUsage {
  const o: Record<string, Object> | null = asRecord(v)
  if (o === null) throw new ApiError(1, 'usage response is not an object')
  const u: MediaUsage = {
    usedBytes: getNumber(o, 'usedBytes') ?? 0,
    quotaBytes: getNumber(o, 'quotaBytes') ?? 0,
    persistentUsedBytes: getNumber(o, 'persistentUsedBytes'),
    persistentQuotaBytes: getNumber(o, 'persistentQuotaBytes'),
    persistentQuotaAvailable: getBoolean(o, 'persistentQuotaAvailable'),
  }
  return u
}

/** 上传响应。服务端返回的是裸 UploadResult（含 code 0），缺字段时按调用方给的兜底补齐。 */
export function decodeUploadResult(o: Record<string, Object>, clientMediaId: string): UploadResult {
  const r: UploadResult = {
    code: getNumber(o, 'code') ?? 0,
    id: getNumber(o, 'id') ?? 0,
    clientMediaId: getString(o, 'clientMediaId') ?? clientMediaId,
    projectUid: getString(o, 'projectUid'), fileUid: getString(o, 'fileUid'), fileId: getNumber(o, 'fileId'),
    delivered: getBoolean(o, 'delivered') ?? false,
  }
  return r
}

function decodeLocations(value: Object | null | undefined): ProjectLocation[] {
  const result: ProjectLocation[] = []
  const entries: Object[] = asArray(value) ?? []
  for (const entry of entries) {
    const o: Record<string, Object> | null = asRecord(entry)
    if (o === null) throw new ApiError(1, 'Invalid project location')
    const kind: string | undefined = getString(o, 'kind')
    const device: string | undefined = getString(o, 'deviceId')
    const key: string | undefined = getString(o, 'key')
    if (kind === undefined || device === undefined || key === undefined) throw new ApiError(1, 'Invalid project location')
    const location: ProjectLocation = { kind: kind, deviceId: device, key: key,
      deviceName: getString(o, 'deviceName'), online: getBoolean(o, 'online'), archiveOnly: getBoolean(o, 'archiveOnly') }
    result.push(location)
  }
  return result
}

export function decodeCatalog(v: Object | null): RelayProject[] {
  const entries: Object[] | null = asArray(v)
  if (entries === null) throw new ApiError(1, 'Invalid project catalog')
  const result: RelayProject[] = []
  for (const entry of entries) {
    const o: Record<string, Object> | null = asRecord(entry)
    if (o === null) throw new ApiError(1, 'Invalid project')
    const uid: string | undefined = getString(o, 'projectUid')
    const name: string | undefined = getString(o, 'name')
    const locations: ProjectLocation[] = decodeLocations(o['locations'])
    const source: ProjectLocation | undefined = locations.find((l: ProjectLocation): boolean => l.kind === 'cloud' && l.archiveOnly !== true)
      ?? locations.find((l: ProjectLocation): boolean => l.kind === 'desktop' && l.online === true)
      ?? locations.find((l: ProjectLocation): boolean => l.kind === 'desktop') ?? locations[0]
    if (uid === undefined || name === undefined || source === undefined) throw new ApiError(1, 'Invalid project')
    const project: RelayProject = { deviceId: source.deviceId, key: source.key, deviceName: source.deviceName,
      name: name, projectUid: uid, locations: locations }
    result.push(project)
  }
  return result
}

/** Missing legacy subscription is distinct from an empty allowance. */
export function decodeSubscriptionBalance(v: Object | null): SubscriptionBalance | null {
  const root: Record<string, Object> | null = asRecord(v)
  const o: Record<string, Object> | null = root === null ? null : asRecord(root['subscription'])
  if (o === null) return null
  const active: boolean | undefined = getBoolean(o, 'active')
  const available: number | undefined = getNumber(o, 'availableCents')
  const monthlyLimit: number | undefined = getNumber(o, 'monthlyLimitCents')
  const monthlyUsed: number | undefined = getNumber(o, 'monthlyUsedCents')
  const weeklyLimit: number | undefined = getNumber(o, 'weeklyLimitCents')
  const weeklyUsed: number | undefined = getNumber(o, 'weeklyUsedCents')
  if (active === undefined || available === undefined || monthlyLimit === undefined || monthlyUsed === undefined || weeklyLimit === undefined || weeklyUsed === undefined) {
    throw new ApiError(1, 'Invalid subscription balance')
  }
  return { active: active, availableCents: available, monthlyLimitCents: monthlyLimit,
    monthlyUsedCents: monthlyUsed, weeklyLimitCents: weeklyLimit, weeklyUsedCents: weeklyUsed }
}
