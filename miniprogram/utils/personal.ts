// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
export interface AssistantStatus { enabled: boolean; subscriptionActive: boolean; backupEnabled: boolean; summaryCount: number; reason?: string; consentEnabled?: boolean }
export interface PersonalSource { deviceId: string; projectKey: string; projectName: string; sourceUpdatedAt?: string }
export interface PersonalReply { status?: 'running' | 'completed' | 'failed'; conversationId: string; requestId: string; answer: string; sources: PersonalSource[] }
export interface PersonalQuestion { conversationId?: string; requestId: string; message: string }
export interface CalendarEvent extends PersonalSource {
  id: string; projectUid?: string; title: string; dueDate: string; dueTime?: string; timeZone: string;
  remindAt?: string; status: 'OPEN' | 'DONE'; updatedAt?: string; files: { fileId: string | number; fileName: string }[]
}
export interface CalendarSnapshot { enabled: boolean; subscriptionActive: boolean; events: CalendarEvent[]; syncedAt?: string }
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
