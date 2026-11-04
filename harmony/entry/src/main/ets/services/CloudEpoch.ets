import { Prefs } from './Prefs'
import { EvidenceStore } from './EvidenceStore'
import { CaptureItem } from '../model/Capture'
import { TransferState } from '../model/TransferState'
import { http } from '@kit.NetworkKit'
import { JSON as ArkJson } from '@kit.ArkTS'
import { asRecord } from './ApiTypes'
import { ApiError } from '../model/Envelope'
import { tr } from '../design/L10n'

let prefs: Prefs | null = null
let evidence: EvidenceStore | null = null
let launchAt: number = Date.now()
let generation: number = 0
export function configureCloudEpoch(p: Prefs, store: EvidenceStore): void {
  prefs = p; evidence = store; launchAt = Date.now(); invalidateCloudEpoch()
}
export function cloudGeneration(): number { return generation }
export async function cloudAccountChanged(): Promise<void> { invalidateCloudEpoch(); if (evidence !== null) await pauseCloud() }
export function invalidateCloudEpoch(): void { generation++; snapshots.clear() }
async function pauseCloud(): Promise<void> {
  const store: EvidenceStore | null = evidence
  if (store === null) throw new ApiError(1, tr('postpaid.refresh'))
  for (const item of await store.loadAll()) if (item.state === TransferState.waiting || item.state === TransferState.uploading || item.state === TransferState.failed) {
    await store.updateState(item.id, TransferState.failed, 0, null, true)
  }
}
export async function reconnectCloud(origin: string, sid: string, language: string): Promise<void> {
  invalidateCloudEpoch(); await pauseCloud(); await cloudEpoch(origin, sid, language, true)
}
const snapshots: Map<string, Promise<string | null>> = new Map<string, Promise<string | null>>()
export function requiresCloudEpoch(path: string, method: http.RequestMethod): boolean {
  return method !== http.RequestMethod.GET && !/^\/api\/(auth|account|feedback|mobile\/billing)(\/|$)/.test(path)
}
export async function cloudEpoch(origin: string, sid: string, language: string, explicit: boolean = false, expectedGeneration?: number): Promise<string | null> {
  const revision: number = expectedGeneration ?? generation
  if (revision !== generation) throw new ApiError(1, tr('postpaid.refresh'))
  const key: string = origin + '\n' + sid
  let pending: Promise<string | null> | undefined = snapshots.get(key)
  if (pending === undefined || explicit) {
    pending = loadEpoch(origin, sid, language)
    snapshots.set(key, pending)
  }
  try {
    const epoch: string | null = await pending
    const user: number = await accountId(origin, sid, language)
    const p: Prefs | null = prefs
    const store: EvidenceStore | null = evidence
    if (p === null || store === null || revision !== generation) throw new ApiError(1, tr('postpaid.refresh'))
    const scope: string = origin + ':' + String(user)
    const old: string = await p.cloudEpochBinding(scope)
    const current: string = epoch ?? 'legacy'
    const rows: CaptureItem[] = await store.loadAll()
    const legacy: boolean = rows.some((item: CaptureItem): boolean => (item.state === TransferState.waiting || item.state === TransferState.uploading || item.state === TransferState.failed) && item.capturedAtMs() < launchAt)
    if (revision !== generation) throw new ApiError(1, tr('postpaid.refresh'))
    if (!explicit && ((old !== '' && old !== current) || (old === '' && legacy))) {
      await pauseCloud(); throw new ApiError(1, tr('postpaid.refresh'))
    }
    await p.setCloudEpochBinding(scope, current, (): boolean => revision === generation)
    if (revision !== generation) throw new ApiError(1, tr('postpaid.refresh'))
    return epoch
  } catch (error) { if (snapshots.get(key) === pending) snapshots.delete(key); throw error as Error }
}
async function loadEpoch(origin: string, sid: string, language: string): Promise<string | null> {
  const client: http.HttpRequest = http.createHttp()
  try {
    const header: Record<string, string> = { 'X-Session-Id': sid, 'X-App-Language': language }
    const response: http.HttpResponse = await client.request(origin + '/api/mobile/billing/cloud-state', {
      method: http.RequestMethod.GET, header: header, expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000, readTimeout: 30000, maxRedirects: 0,
    })
    if (response.responseCode === 404) return null
    const root: Record<string, Object> | null = typeof response.result === 'string' ? asRecord(ArkJson.parse(response.result as string)) : null
    const access: Record<string, Object> | null = root === null ? null : asRecord(root['cloudAccess'])
    const epoch: number = access === null ? -1 : access['epoch'] as number
    if (response.responseCode !== 200 || !Number.isSafeInteger(epoch) || epoch < 0) throw new ApiError(1, tr('postpaid.refresh'))
    return String(epoch)
  } finally { client.destroy() }
}

async function accountId(origin: string, sid: string, language: string): Promise<number> {
  const client: http.HttpRequest = http.createHttp()
  try {
    const response: http.HttpResponse = await client.request(origin + '/api/auth/me', {
      method: http.RequestMethod.GET, header: { 'X-Session-Id': sid, 'X-App-Language': language },
      expectDataType: http.HttpDataType.STRING, connectTimeout: 15000, readTimeout: 30000, maxRedirects: 0,
    })
    const root: Record<string, Object> | null = typeof response.result === 'string' ? asRecord(ArkJson.parse(response.result as string)) : null
    const data: Record<string, Object> | null = root === null ? null : asRecord(root['data'])
    const id: number = data === null ? 0 : data['id'] as number
    if (response.responseCode !== 200 || root === null || root['code'] !== 0 || !Number.isSafeInteger(id) || id <= 0) throw new ApiError(1, tr('error.unauthorized'))
    return id
  } finally { client.destroy() }
}
