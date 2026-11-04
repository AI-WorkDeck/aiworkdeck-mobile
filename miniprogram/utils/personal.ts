// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
export interface AssistantStatus { cloudAccess?: import('./cloud-access').CloudAccess; enabled: boolean; subscriptionActive: boolean; backupEnabled: boolean; summaryCount: number; reason?: string; consentEnabled?: boolean }
export interface PersonalSource { deviceId: string; projectKey: string; projectName: string; sourceUpdatedAt?: string }
export interface PersonalReply { status?: 'running' | 'completed' | 'failed'; conversationId: string; requestId: string; answer: string; sources: PersonalSource[] }
export interface PersonalQuestion { conversationId?: string; requestId: string; message: string }
export interface CalendarEvent extends PersonalSource {
  id: string; projectUid?: string; title: string; dueDate: string; dueTime?: string; timeZone: string;
  remindAt?: string; status: 'OPEN' | 'DONE'; updatedAt?: string; files: { fileId: string | number; fileName: string }[]
}
export interface CalendarSnapshot { cloudAccess?: import('./cloud-access').CloudAccess; enabled: boolean; subscriptionActive: boolean; events: CalendarEvent[]; syncedAt?: string }
export interface PersonalMessage { role: string; content: string }
export function projectIdentity(event: CalendarEvent): string { return event.projectUid ?? `${event.deviceId}:${event.projectKey}` }
export function upcoming(events: CalendarEvent[], days: number, project = '', now = new Date()): CalendarEvent[] {
  return events.filter(event => {
    if (event.status !== 'OPEN' || (project && projectIdentity(event) !== project)) return false
    let today: string
    try {
      const parts = new Intl.DateTimeFormat('en-CA', { timeZone: event.timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(now)
      today = ['year', 'month', 'day'].map(key => parts.find(p => p.type === key)?.value).join('-')
    } catch { today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}` }
    const end = new Date(today + 'T00:00:00Z'); end.setUTCDate(end.getUTCDate() + days)
    return event.dueDate >= today && event.dueDate < end.toISOString().slice(0, 10)
  }).sort((a, b) => (a.dueDate + (a.dueTime ?? '')).localeCompare(b.dueDate + (b.dueTime ?? '')))
}
/** Only successful responses consume a pending question; retries preserve its UUID. */
export class PersonalConversation {
  conversationId?: string
  pending?: PersonalQuestion
  desktopCopy?: PersonalDesktopCopy
  messages: PersonalMessage[] = []
  sources: PersonalSource[] = []
  busy = false
  question(message: string, makeId: () => string): PersonalQuestion {
    if (this.pending?.message !== message) this.pending = { conversationId: this.conversationId, requestId: makeId(), message }
    return this.pending
  }
  accept(reply: PersonalReply): boolean {
    if (reply.status !== 'completed' || !this.pending || reply.requestId !== this.pending.requestId) return false
    this.messages.push({ role: 'user', content: this.pending.message }, { role: 'assistant', content: reply.answer })
    this.conversationId = reply.conversationId; this.sources = reply.sources; this.pending = undefined
    return true
  }
}

export interface PersonalCopyResult { mode: string; sourcePreserved: boolean; sourceConversationId: string; conversationId: string; targetProjectId: number; messageCount: number; filesCopied: boolean }
export function personalCopyTarget(project: import('./api').RelayProject): number | undefined {
  if (project.isDefault || project.projectType === 'SCRATCH' || project.projectType === 'LOOSE_FILES') return undefined
  const key = project.locations?.find(location => location.kind === 'cloud' && !location.archiveOnly)?.key
  if (!key || !/^[1-9][0-9]*$/.test(key)) return undefined
  const id = Number(key)
  return Number.isSafeInteger(id) ? id : undefined
}

export interface DesktopCopyRequest {
  requestId: string; sourceConversationId: string; targetProjectUid: string; targetDeviceId: string; targetProjectKey: string
}
export interface DesktopCopyReceipt extends DesktopCopyRequest {
  status: 'QUEUED' | 'DELIVERED' | 'EXPIRED' | 'FAILED'; sourcePreserved: boolean; filesCopied: boolean;
  conversationId: string; messageCount: number; expiresAt: string; error?: string | null
}
export interface PersonalDesktopCopy { request: DesktopCopyRequest; receipt?: DesktopCopyReceipt }
export interface PersonalCopyDestination {
  id: string; name: string; project: import('./api').RelayProject; desktop?: import('./project-catalog').ProjectLocation
}
export function desktopCopyEligible(location: import('./project-catalog').ProjectLocation): boolean {
  return location.kind === 'desktop' && !location.archiveOnly && location.owned === true && !!location.projectUid && !!location.projectType && !['SCRATCH', 'LOOSE_FILES'].includes(location.projectType)
}
export function personalCopyDestinations(projects: import('./api').RelayProject[], cloudLabel: string): PersonalCopyDestination[] {
  return projects.flatMap(project => {
    const cloud = personalCopyTarget(project)
    const values: PersonalCopyDestination[] = cloud ? [{ id: `cloud:${cloud}`, name: `${project.name} · ${cloudLabel}`, project }] : []
    if (!project.isDefault) for (const location of project.locations ?? []) {
      if (desktopCopyEligible(location)) values.push({ id: `desktop:${location.deviceId}:${location.key}`, name: `${project.name} · ${location.deviceName ?? location.deviceId}`, project, desktop: location })
    }
    return values
  })
}
export function desktopCopyNeedsUpgrade(projects: import('./api').RelayProject[]): boolean {
  return projects.some(project => project.locations?.some(location => location.kind === 'desktop' && (location.owned == null || !location.projectType || !location.projectUid)))
}
export function desktopCopyTerminal(receipt?: DesktopCopyReceipt): boolean { return !!receipt && ['DELIVERED', 'EXPIRED', 'FAILED'].includes(receipt.status) }
export function desktopCopyStatusKey(value?: PersonalDesktopCopy): string {
  if (!value?.receipt) return 'personal.copy.unknown'
  return 'personal.copy.' + ({ QUEUED: 'queued', DELIVERED: 'delivered', EXPIRED: 'expired', FAILED: 'failed' }[value.receipt.status] ?? 'unknown')
}
export function desktopCopyMatches(receipt: DesktopCopyReceipt, request: DesktopCopyRequest): boolean {
  return ['QUEUED', 'DELIVERED', 'EXPIRED', 'FAILED'].includes(receipt.status) && receipt.sourcePreserved === true && receipt.filesCopied === false && !!receipt.conversationId &&
    ['requestId', 'sourceConversationId', 'targetProjectUid', 'targetDeviceId', 'targetProjectKey'].every(key => receipt[key as keyof DesktopCopyRequest] === request[key as keyof DesktopCopyRequest])
}
