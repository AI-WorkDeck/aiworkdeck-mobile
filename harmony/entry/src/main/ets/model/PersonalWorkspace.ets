// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
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
  conversationId: string = ''; pendingId: string = ''; pendingText: string = ''; pendingConversationId: string = ''
  static from(raw: Record<string, Object>): PersonalConversation {
    const value: PersonalConversation = new PersonalConversation()
    value.conversationId = stringField(raw, 'conversationId'); value.pendingId = stringField(raw, 'pendingId')
    value.pendingText = stringField(raw, 'pendingText'); value.pendingConversationId = stringField(raw, 'pendingConversationId')
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
