// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { notificationManager } from '@kit.NotificationKit'
import { reminderAgentManager } from '@kit.BackgroundTasksKit'
import { preferences } from '@kit.ArkData'
import { bundleManager, common } from '@kit.AbilityKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { tr } from '../design/L10n'
import { ServiceLocator } from './ServiceLocator'
import { PersonalEvent } from '../model/PersonalWorkspace'
export class CalendarReminders {
  private static generation: number = 0
  private static queue: Promise<boolean> = Promise.resolve(true)
  private static async scope(): Promise<string> {
    const session: string | null = await ServiceLocator.session.current()
    if (session === null) return ''
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256')
    md.updateSync({ data: new util.TextEncoder().encodeInto(ServiceLocator.baseUrl() + ":" + session) })
    return Array.from(md.digestSync().data).map((v: number): string => v.toString(16).padStart(2, '0')).join('')
  }
  static async restore(): Promise<boolean> {
    if (CalendarReminders.store().getSync('scope', '') !== await CalendarReminders.scope()) await CalendarReminders.clear()
    return CalendarReminders.enabled()
  }
  private static store(): preferences.Preferences { return preferences.getPreferencesSync(ServiceLocator.ctx, { name: 'personal-calendar' }) }
  static enabled(): boolean { return CalendarReminders.store().getSync('enabled', false) === true }
  static async enable(): Promise<boolean> {
    try {
      if (!await notificationManager.isNotificationEnabled()) await notificationManager.requestEnableNotification(ServiceLocator.ctx as common.UIAbilityContext)
      const enabled: boolean = await notificationManager.isNotificationEnabled()
      CalendarReminders.store().putSync('scope', await CalendarReminders.scope()); CalendarReminders.store().putSync('enabled', enabled); await CalendarReminders.store().flush(); return enabled
    } catch (_) { return false }
  }
  private static async remove(): Promise<void> {
    const ids: preferences.ValueType = CalendarReminders.store().getSync('ids', [])
    if (Array.isArray(ids)) for (const id of ids as number[]) { try { await reminderAgentManager.cancelReminder(id) } catch (_) {} }
    CalendarReminders.store().putSync('ids', []); await CalendarReminders.store().flush()
  }
  static async clear(): Promise<void> {
    CalendarReminders.generation++; CalendarReminders.store().putSync('enabled', false); await CalendarReminders.store().flush()
    const pending: Promise<boolean> = CalendarReminders.queue
    CalendarReminders.queue = pending.then(async (): Promise<boolean> => { await CalendarReminders.remove(); return true })
    await CalendarReminders.queue
  }
  static async replace(events: PersonalEvent[]): Promise<boolean> {
    const version: number = ++CalendarReminders.generation
    const pending: Promise<boolean> = CalendarReminders.queue
    const work: Promise<boolean> = pending.then(async (): Promise<boolean> => { return await CalendarReminders.apply(events, version) })
    CalendarReminders.queue = work; return await work
  }
  private static async apply(events: PersonalEvent[], version: number): Promise<boolean> {
    if (version !== CalendarReminders.generation) return false
    const session: string | null = await ServiceLocator.session.current()
    await CalendarReminders.remove()
    if (!CalendarReminders.enabled() || session === null) return false
    const upcoming: PersonalEvent[] = events.filter((e: PersonalEvent): boolean => e.status === 'OPEN' && Date.parse(e.remindAt) > Date.now()).sort((a: PersonalEvent, b: PersonalEvent): number => Date.parse(a.remindAt) - Date.parse(b.remindAt)).slice(0, 50)
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT); const ids: number[] = []
    try {
      for (const event of upcoming) {
        if (version !== CalendarReminders.generation || session !== await ServiceLocator.session.current()) return false
        const date: Date = new Date(event.remindAt)
        const request: reminderAgentManager.ReminderRequestCalendar = {
          reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
          dateTime: { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(), hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds() },
          content: tr('personal.reminders'), ringDuration: 0,
          wantAgent: { pkgName: info.name, abilityName: 'EntryAbility', parameters: { 'calendarEventId': event.id } },
        }
        const id: number = await reminderAgentManager.publishReminder(request)
        if (version !== CalendarReminders.generation || session !== await ServiceLocator.session.current()) { await reminderAgentManager.cancelReminder(id); return false }
        ids.push(id); CalendarReminders.store().putSync('ids', ids); await CalendarReminders.store().flush()
      }
      return true
    } catch (_) { await CalendarReminders.remove(); return false }
  }
}
