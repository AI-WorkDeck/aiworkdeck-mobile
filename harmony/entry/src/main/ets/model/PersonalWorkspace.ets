// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { RelayProject, ProjectLocation } from './Capture'

export class PersonalSource {
  deviceId: string = ''; projectKey: string = ''; projectName: string = ''; sourceUpdatedAt: string = ''
}
export class PersonalEvent extends PersonalSource {
  id: string = ''; projectUid: string = ''; title: string = ''; dueDate: string = ''; dueTime: string = ''
  timeZone: string = ''; remindAt: string = ''; status: string = ''; files: string[] = []
  identity(): string { return this.projectUid || `${this.deviceId}:${this.projectKey}` }
}
export class PersonalMessage {
  role: string; content: string
  constructor(role: string, content: string) { this.role = role; this.content = content }
}
export class PersonalConversation {
  desktopCopy: PersonalDesktopCopy | null = null
  conversationId: string = ''; pendingId: string = ''; pendingText: string = ''; pendingConversationId: string = ''
  static from(raw: Record<string, Object>): PersonalConversation {
    const value: PersonalConversation = new PersonalConversation()
    value.conversationId = stringField(raw, 'conversationId'); value.pendingId = stringField(raw, 'pendingId')
    value.pendingText = stringField(raw, 'pendingText'); value.pendingConversationId = stringField(raw, 'pendingConversationId')
    value.desktopCopy = PersonalDesktopCopy.from(raw['desktopCopy'])
    return value
  }
}
export function personalMessages(value: Object | undefined): PersonalMessage[] {
  if (!Array.isArray(value)) return []
  return (value as Object[]).map((item: Object): PersonalMessage => {
    const raw: Record<string, Object> = item as Record<string, Object>
    return new PersonalMessage(stringField(raw, 'role'), stringField(raw, 'content'))
  }).filter((message: PersonalMessage): boolean => message.role === 'user' || message.role === 'assistant')
}
export function personalHistorySources(value: Object | undefined): PersonalSource[] {
  if (!Array.isArray(value)) return []
  const messages: Object[] = value as Object[]
  for (let index: number = messages.length - 1; index >= 0; index--) {
    const raw: Record<string, Object> = messages[index] as Record<string, Object>
    if (stringField(raw, 'role') === 'assistant') return personalSources(raw['sources'])
  }
  return []
}
export function personalSourceDate(value: string, locale: string): string {
  const date: Date = new Date(value)
  if (!Number.isFinite(date.getTime())) return ''
  return date.toLocaleString(locale, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}
export function stringField(raw: Record<string, Object>, name: string): string { return typeof raw[name] === 'string' ? raw[name] as string : '' }
export function personalSources(value: Object | undefined): PersonalSource[] {
  if (!Array.isArray(value)) return []
  return (value as Object[]).map((item: Object): PersonalSource => {
    const raw: Record<string, Object> = item as Record<string, Object>; const source: PersonalSource = new PersonalSource()
    source.deviceId = stringField(raw, 'deviceId'); source.projectKey = stringField(raw, 'projectKey')
    source.projectName = stringField(raw, 'projectName'); source.sourceUpdatedAt = stringField(raw, 'sourceUpdatedAt'); return source
  })
}
export function personalEvents(value: Object | undefined): PersonalEvent[] {
  if (!Array.isArray(value)) return []
  return (value as Object[]).map((item: Object): PersonalEvent => {
    const raw: Record<string, Object> = item as Record<string, Object>; const event: PersonalEvent = new PersonalEvent()
    event.id = stringField(raw, 'id'); event.deviceId = stringField(raw, 'deviceId'); event.projectKey = stringField(raw, 'projectKey')
    event.projectUid = stringField(raw, 'projectUid'); event.projectName = stringField(raw, 'projectName'); event.title = stringField(raw, 'title')
    event.dueDate = stringField(raw, 'dueDate'); event.dueTime = stringField(raw, 'dueTime'); event.timeZone = stringField(raw, 'timeZone')
    event.remindAt = stringField(raw, 'remindAt'); event.status = stringField(raw, 'status')
    if (Array.isArray(raw['files'])) event.files = (raw['files'] as Object[]).map((f: Object): string => stringField(f as Record<string, Object>, 'fileName'))
    return event
  })
}
export function upcomingEvents(events: PersonalEvent[], days: number, identity: string, now: Date = new Date()): PersonalEvent[] {
  return events.filter((event: PersonalEvent): boolean => {
    if (event.status !== 'OPEN' || (identity.length > 0 && event.identity() !== identity)) return false
    let local: string = ''
    try { local = now.toLocaleDateString('en-CA', { timeZone: event.timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }) }
    catch (_) { local = now.toISOString().slice(0, 10) }
    const end: Date = new Date(local + 'T00:00:00Z'); end.setUTCDate(end.getUTCDate() + days)
    return Number.isFinite(end.getTime()) && event.dueDate >= local && event.dueDate < end.toISOString().slice(0, 10)
  }).sort((a: PersonalEvent, b: PersonalEvent): number => (a.dueDate + a.dueTime).localeCompare(b.dueDate + b.dueTime))
}


export class PersonalCopyTarget {
  project: RelayProject
  desktop: ProjectLocation | null
  cloudId: number
  constructor(project: RelayProject, desktop: ProjectLocation | null, cloudId: number = 0) {
    this.project = project; this.desktop = desktop; this.cloudId = cloudId
  }
}
export function desktopCopyEligible(location: ProjectLocation): boolean {
  return location.kind === 'desktop' && location.archiveOnly !== true && location.owned === true &&
    (location.projectUid ?? '').length > 0 && (location.projectType ?? '').length > 0 &&
    location.projectType !== 'SCRATCH' && location.projectType !== 'LOOSE_FILES' && location.deviceId.length > 0 && location.key.length > 0
}
export function personalCopyTargets(projects: RelayProject[]): PersonalCopyTarget[] {
  const result: PersonalCopyTarget[] = []
  for (const project of projects) {
    if (project.isDefault === true) continue
    for (const location of project.locations ?? []) {
      if (desktopCopyEligible(location)) result.push(new PersonalCopyTarget(project, location))
      else if (location.kind === 'cloud' && location.archiveOnly !== true && project.projectType !== 'SCRATCH' && project.projectType !== 'LOOSE_FILES' && /^[1-9][0-9]*$/.test(location.key)) {
        const id: number = Number(location.key)
        if (Number.isSafeInteger(id)) result.push(new PersonalCopyTarget(project, null, id))
      }
    }
  }
  return result
}
export function copyNeedsUpgrade(projects: RelayProject[]): boolean {
  return projects.some((project: RelayProject): boolean => (project.locations ?? []).some((location: ProjectLocation): boolean =>
    location.kind === 'desktop' && (location.owned === undefined || (location.projectUid ?? '').length === 0 || (location.projectType ?? '').length === 0)))
}
export class DesktopCopyRequest {
  requestId: string = ''; sourceConversationId: string = ''; targetProjectUid: string = ''; targetDeviceId: string = ''; targetProjectKey: string = ''
  body(): Record<string, Object> { return { 'requestId': this.requestId, 'targetProjectUid': this.targetProjectUid, 'targetDeviceId': this.targetDeviceId, 'targetProjectKey': this.targetProjectKey } }
  sameTarget(other: DesktopCopyRequest): boolean { return this.sourceConversationId === other.sourceConversationId && this.targetProjectUid === other.targetProjectUid && this.targetDeviceId === other.targetDeviceId && this.targetProjectKey === other.targetProjectKey }
  static from(raw: Record<string, Object>): DesktopCopyRequest | null {
    const request: DesktopCopyRequest = new DesktopCopyRequest()
    request.requestId = stringField(raw, 'requestId'); request.sourceConversationId = stringField(raw, 'sourceConversationId')
    request.targetProjectUid = stringField(raw, 'targetProjectUid'); request.targetDeviceId = stringField(raw, 'targetDeviceId'); request.targetProjectKey = stringField(raw, 'targetProjectKey')
    return request.requestId.length > 0 && request.sourceConversationId.length > 0 && request.targetProjectUid.length > 0 && request.targetDeviceId.length > 0 && request.targetProjectKey.length > 0 ? request : null
  }
}
export class DesktopCopyReceipt {
  request: DesktopCopyRequest; status: string; conversationId: string; messageCount: number; expiresAt: string
  constructor(request: DesktopCopyRequest, status: string, conversationId: string, messageCount: number, expiresAt: string) {
    this.request = request; this.status = status; this.conversationId = conversationId; this.messageCount = messageCount; this.expiresAt = expiresAt
  }
  terminal(): boolean { return this.status === 'DELIVERED' || this.status === 'EXPIRED' || this.status === 'FAILED' }
  static from(raw: Record<string, Object>, expected: DesktopCopyRequest | null = null): DesktopCopyReceipt | null {
    const request: DesktopCopyRequest | null = DesktopCopyRequest.from(raw)
    const status: string = stringField(raw, 'status'), conversation: string = stringField(raw, 'conversationId')
    if (request === null || raw['sourcePreserved'] !== true || raw['filesCopied'] !== false || conversation.length === 0 || !['QUEUED', 'DELIVERED', 'EXPIRED', 'FAILED'].includes(status)) return null
    if (expected !== null && (request.requestId !== expected.requestId || !request.sameTarget(expected))) return null
    const count: number = typeof raw['messageCount'] === 'number' ? raw['messageCount'] as number : -1
    const expires: string = stringField(raw, 'expiresAt')
    if (!Number.isSafeInteger(count) || count < 0 || !Number.isFinite(new Date(expires).getTime())) return null
    return new DesktopCopyReceipt(request, status, conversation, count, expires)
  }
  wire(): Record<string, Object> {
    return { 'requestId': this.request.requestId, 'sourceConversationId': this.request.sourceConversationId,
      'targetProjectUid': this.request.targetProjectUid, 'targetDeviceId': this.request.targetDeviceId, 'targetProjectKey': this.request.targetProjectKey,
      'sourcePreserved': true, 'filesCopied': false, 'status': this.status, 'conversationId': this.conversationId, 'messageCount': this.messageCount, 'expiresAt': this.expiresAt }
  }
}
export class PersonalDesktopCopy {
  request: DesktopCopyRequest; receipt: DesktopCopyReceipt | null = null
  constructor(request: DesktopCopyRequest) { this.request = request }
  statusKey(): string { const status: string = this.receipt === null ? 'unknown' : this.receipt.status.toLowerCase(); return 'personal.copy.' + status }
  canRetry(): boolean { return this.receipt === null || this.receipt.status === 'FAILED' || this.receipt.status === 'EXPIRED' }
  static from(value: Object | undefined): PersonalDesktopCopy | null {
    if (value === undefined || value === null || typeof value !== 'object') return null
    const raw: Record<string, Object> = value as Record<string, Object>
    if (raw['request'] === undefined || raw['request'] === null || typeof raw['request'] !== 'object') return null
    const request: DesktopCopyRequest | null = DesktopCopyRequest.from(raw['request'] as Record<string, Object>)
    if (request === null) return null
    const result: PersonalDesktopCopy = new PersonalDesktopCopy(request)
    if (raw['receipt'] !== undefined && raw['receipt'] !== null && typeof raw['receipt'] === 'object') result.receipt = DesktopCopyReceipt.from(raw['receipt'] as Record<string, Object>, request)
    return result
  }
}
