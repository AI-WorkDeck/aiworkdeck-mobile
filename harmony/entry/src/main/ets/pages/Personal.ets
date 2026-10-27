// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { ContractCapabilities } from 'contract'
import { ServiceLocator } from '../services/ServiceLocator'
import { PersonalConversationStore } from '../services/PersonalConversationStore'
import { CalendarReminders } from '../services/CalendarReminders'
import { PersonalEvent, PersonalSource, PersonalMessage, PersonalConversation, personalMessages, personalHistorySources, personalSourceDate, personalEvents, personalSources, stringField, upcomingEvents } from '../model/PersonalWorkspace'
import { ProjectFilesRequest } from './ProjectFilesRequest'
import { Tk } from '../design/Tokens'
import { trIn, LOCALE_ZH, L10n } from '../design/L10n'
import { errorText } from './Feedback'
@Component
export struct Personal {
  stack: NavPathStack = new NavPathStack()
  @StorageProp('awdLocale') locale: string = LOCALE_ZH
  @StorageLink('personalCalendarEventId') @Watch('openNotification') notificationId: string = ''
  @State tab: string = 'assistant'
  @State assistantEnabled: boolean = false
  @State assistantSubscribed: boolean = false
  @State backupEnabled: boolean = false
  @State calendarEnabled: boolean = false
  @State calendarSubscribed: boolean = false
  @State summaryCount: number = 0
  @State messages: PersonalMessage[] = []
  @State sources: PersonalSource[] = []
  @State events: PersonalEvent[] = []
  @State draft: string = ''
  @State error: string = ''
  @State calendarError: string = ''
  @State busy: boolean = false
  @State loading: boolean = false
  @State days: number = 3
  @State project: string = ''
  @State reminders: boolean = false
  private session: string = ''
  private host: string = ''
  private alive: boolean = false
  private conversationId: string = ''
  private pendingId: string = ''
  private pendingText: string = ''
  private pendingConversationId: string = ''
  private conversationStore: PersonalConversationStore | null = null
  private version: number = 0
  private async current(version: number): Promise<boolean> {
    return this.alive && version === this.version && this.conversationStore !== null && await this.conversationStore.isCurrent() && this.alive && version === this.version
  }
  private async saveConversation(): Promise<void> {
    const value: PersonalConversation = new PersonalConversation()
    value.conversationId = this.conversationId; value.pendingId = this.pendingId
    value.pendingText = this.pendingText; value.pendingConversationId = this.pendingConversationId
    if (this.conversationStore !== null) await this.conversationStore.save(value)
  }
  private resetConversation(): void {
    this.messages = []; this.sources = []; this.conversationId = ''; this.pendingId = ''; this.pendingText = ''; this.pendingConversationId = ''; this.draft = ''
  }
  private async poll(reply: Record<string, Object>, id: string, version: number): Promise<Record<string, Object>> {
    let result: Record<string, Object> = reply
    for (let attempt: number = 0; stringField(result, 'status') === 'running' && attempt < 120; attempt++) {
      if (stringField(result, 'requestId') !== id || !await this.current(version)) throw new Error(this.t('error.network'))
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 2000) })
      if (!await this.current(version)) throw new Error(this.t('error.network'))
      result = await this.request('assistant/requests/' + id)
    }
    if (stringField(result, 'requestId') !== id) throw new Error(this.t('error.badResponse'))
    return result
  }
  private async restoreConversation(version: number): Promise<void> {
    if (this.conversationStore === null) this.conversationStore = await PersonalConversationStore.open()
    const value: PersonalConversation = await this.conversationStore.load()
    if (!await this.current(version)) return
    this.conversationId = value.conversationId; this.pendingId = value.pendingId
    this.pendingText = value.pendingText; this.pendingConversationId = value.pendingConversationId
    if (this.pendingId.length > 0) {
      this.draft = this.pendingText; this.busy = true
      try {
        const id: string = this.pendingId
        const reply: Record<string, Object> = await this.poll(await this.request('assistant/requests/' + id), id, version)
        if (!await this.current(version) || this.pendingId !== id) return
        this.conversationId = stringField(reply, 'conversationId')
        if (stringField(reply, 'status') === 'completed') { this.pendingId = ''; this.pendingText = ''; this.pendingConversationId = ''; this.draft = '' }
        else this.error = this.t('error.network')
        await this.saveConversation()
      } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
      finally { if (version === this.version) this.busy = false }
    }
    if (this.conversationId.length > 0 && await this.current(version)) {
      try {
        const id: string = this.conversationId
        const history: Record<string, Object> = await this.request('assistant/conversations/' + id)
        if (!await this.current(version) || this.conversationId !== id || stringField(history, 'conversationId') !== id) return
        this.messages = personalMessages(history['messages']); this.sources = personalHistorySources(history['messages'])
      } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
    }
  }
  private t(key: string, vars?: Record<string, string | number>): string { return trIn(this.locale, key, vars) }
  aboutToAppear(): void {
    this.alive = true; this.host = ServiceLocator.baseUrl()
    CalendarReminders.restore().then((enabled: boolean): void => { if (this.alive) this.reminders = enabled })
    ServiceLocator.session.current().then((session: string | null): void => { if (session !== null && this.alive) { this.session = session; this.load() } })
  }
  aboutToDisappear(): void { this.alive = false; this.version++ }
  private async request(path: string, method: http.RequestMethod = http.RequestMethod.GET, body: Record<string, Object> | null = null): Promise<Record<string, Object>> {
    if (this.host !== ServiceLocator.baseUrl()) throw new Error(this.t('files.error.closed'))
    return await ServiceLocator.backend.personalRequest(path, method, body, this.session)
  }
  private async load(): Promise<void> {
    if (this.loading || this.busy || !this.alive || this.session.length === 0) return
    const version: number = this.version
    let restore: boolean = false
    this.loading = true
    try {
      try {
        const status: Record<string, Object> = await this.request('assistant/status')
        if (!this.alive || version !== this.version) return
        this.assistantEnabled = status['enabled'] === true; this.assistantSubscribed = status['subscriptionActive'] === true; this.backupEnabled = status['backupEnabled'] === true
        this.summaryCount = typeof status['summaryCount'] === 'number' ? status['summaryCount'] as number : 0; this.error = ''
        if (status['consentEnabled'] === false) {
          await PersonalConversationStore.clear()
          if (!this.alive || version !== this.version) return
          this.conversationStore = null; this.resetConversation()
        } else if (this.assistantEnabled && this.assistantSubscribed) restore = true
        else { this.messages = []; this.sources = [] }
      } catch (e) { if (this.alive && version === this.version) this.error = errorText(e as Object) }
      if (!this.alive || version !== this.version) return
      try {
        const calendar: Record<string, Object> = await this.request('calendar/events')
        if (!this.alive || version !== this.version) return
        this.calendarEnabled = calendar['enabled'] === true; this.calendarSubscribed = calendar['subscriptionActive'] === true
        this.events = this.calendarEnabled && this.calendarSubscribed ? personalEvents(calendar['events']) : []; this.calendarError = ''
        if (this.reminders && !await CalendarReminders.replace(this.events)) this.calendarError = this.t('personal.remindersUnavailable')
        if (!this.alive || version !== this.version) return
        if (this.notificationId.length > 0) { this.tab = 'calendar'; const event: PersonalEvent | undefined = this.events.find((e: PersonalEvent): boolean => e.id === this.notificationId); if (event !== undefined) this.detail(event); this.notificationId = '' }
      } catch (e) { if (this.alive && version === this.version) this.calendarError = errorText(e as Object) }
      if (restore && this.alive && version === this.version) await this.restoreConversation(version)
    } finally { if (version === this.version) this.loading = false }
  }
  private async configure(feature: string, enabled: boolean): Promise<void> {
    if (this.loading || this.busy) return
    const version: number = this.version
    this.loading = true
    try {
      const body: Record<string, Object> = { 'enabled': enabled, 'consentVersion': ContractCapabilities.personalConsentVersion }
      await this.request(feature + '/settings', http.RequestMethod.PUT, body)
      if (this.alive && version === this.version) {
        if (feature === 'assistant' && !enabled) { await PersonalConversationStore.clear(); this.conversationStore = null; this.resetConversation() }
        this.loading = false; await this.load()
      }
    } catch (e) { if (this.alive && version === this.version) { if (feature === 'calendar') this.calendarError = errorText(e as Object); else this.error = errorText(e as Object) } }
    finally { if (version === this.version) this.loading = false }
  }
  private consent(feature: string): void {
    this.getUIContext().showAlertDialog({ title: this.t('personal.' + feature), message: this.t('personal.' + feature + 'Consent'), primaryButton: { value: this.t('common.cancel'), action: (): void => {} }, secondaryButton: { value: this.t('common.ok'), action: (): void => { this.configure(feature, true) } } })
  }
  private async send(): Promise<void> {
    const text: string = this.draft.trim()
    const version: number = this.version
    if (this.busy || this.loading || text.length === 0 || !this.assistantEnabled || !this.assistantSubscribed || !await this.current(version)) return
    if (this.busy || this.loading) return
    if (this.pendingText !== text) { this.pendingText = text; this.pendingId = util.generateRandomUUID(true); this.pendingConversationId = this.conversationId }
    const id: string = this.pendingId
    const body: Record<string, Object> = { 'message': text, 'requestId': id }
    if (this.pendingConversationId.length > 0) body['conversationId'] = this.pendingConversationId
    this.busy = true; this.error = ''
    try {
      await this.saveConversation()
      if (!await this.current(version)) return
      const reply: Record<string, Object> = await this.poll(await this.request('assistant/chat', http.RequestMethod.POST, body), id, version)
      if (!await this.current(version) || this.pendingId !== id) return
      if (stringField(reply, 'status') !== 'completed') throw new Error(this.t('error.network'))
      const last: PersonalMessage | undefined = this.messages[this.messages.length - 1]
      if (last === undefined || last.role !== 'user' || last.content !== text) this.messages = this.messages.concat([new PersonalMessage('user', text)])
      this.messages = this.messages.concat([new PersonalMessage('assistant', stringField(reply, 'answer'))])
      this.sources = personalSources(reply['sources']); this.conversationId = stringField(reply, 'conversationId')
      this.pendingId = ''; this.pendingText = ''; this.pendingConversationId = ''; this.draft = ''
      await this.saveConversation()
    } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
    finally { if (version === this.version) this.busy = false }
  }
  private openNotification(): void {
    if (!this.alive || this.notificationId.length === 0) return
    this.tab = 'calendar'; this.load()
  }
  private openProject(source: PersonalSource): void { ProjectFilesRequest.project = { deviceId: source.deviceId, key: source.projectKey, name: source.projectName }; this.stack.pushPath(new NavPathInfo('ProjectFiles', '')) }
  private detail(event: PersonalEvent): void {
    this.getUIContext().showAlertDialog({ title: event.title, message: `${event.dueDate} ${event.dueTime} · ${event.timeZone}\n${event.projectName}\n${event.files.join('\n')}`, primaryButton: { value: this.t('common.close'), action: (): void => {} }, secondaryButton: { value: this.t('project.files'), action: (): void => { this.openProject(event) } } })
  }
  private projectChoices(): PersonalEvent[] { const seen: Set<string> = new Set<string>(); return this.events.filter((e: PersonalEvent): boolean => { if (seen.has(e.identity())) return false; seen.add(e.identity()); return true }) }
  private projectOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: this.t('personal.allProjects') }]
    return options.concat(this.projectChoices().map((e: PersonalEvent): SelectOption => { return { value: e.projectName } }))
  }
  build() {
    NavDestination() {
      Column({ space: Tk.Sp.s2 }) {
        Row() { Text(this.t('personal.' + this.tab)).fontSize(22).fontWeight(FontWeight.Medium).fontColor(Tk.L.fg).layoutWeight(1); Button(this.t('home.settings')).onClick((): void => { this.stack.pushPath(new NavPathInfo('Settings', '')) }) }.width('100%')
        Row() {
          Button(this.t('personal.assistant')).layoutWeight(1).onClick((): void => { this.tab = 'assistant' })
          Button(this.t('personal.calendar')).layoutWeight(1).onClick((): void => { this.tab = 'calendar' })
          Button(this.t('workspace.title')).layoutWeight(1).onClick((): void => { this.stack.pushPath(new NavPathInfo('ProjectPickerSwitch', '')) })
          Button(this.t('workspace.capture')).layoutWeight(1).onClick((): void => { this.stack.pushPath(new NavPathInfo('Home', '')) })
        }
        if (this.tab === 'assistant') {
          if (!this.assistantEnabled || !this.assistantSubscribed) { Text(this.t(this.assistantSubscribed ? 'personal.assistantConsent' : 'personal.subscription')).fontColor(Tk.L.fgMuted); if (this.assistantSubscribed && this.backupEnabled) Button(this.t('common.on')).onClick((): void => { this.consent('assistant') }) }
          if (!this.assistantSubscribed || !this.backupEnabled) Button(this.t(this.assistantSubscribed ? 'backup.title' : 'settings.account')).onClick((): void => { this.stack.pushPath(new NavPathInfo('Settings', '')) })
          Scroll() {
            Column({ space: Tk.Sp.s4 }) {
              if (this.messages.length === 0) { Text(this.t('personal.ask')).fontSize(20); Text(this.t('personal.summaries', { 'count': this.summaryCount })).fontColor(Tk.L.fgMuted) }
              ForEach(this.messages, (message: PersonalMessage): void => { Text(message.content).copyOption(CopyOptions.InApp).fontColor(Tk.L.fg).width('100%').padding(Tk.Sp.s3) })
              if (this.sources.length > 0) Text(this.t('personal.sources')).fontColor(Tk.L.fgMuted)
              ForEach(this.sources, (source: PersonalSource): void => { Button(source.projectName + ' · ' + personalSourceDate(source.sourceUpdatedAt, this.locale)).onClick((): void => { this.openProject(source) }) })
              if (this.busy) Text(this.t('personal.processing')).fontColor(Tk.L.fgMuted)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).width('100%')
          if (this.error.length > 0) { Text(this.error).fontColor(Tk.S.failed); Button(this.t('project.retry')).enabled(!this.busy).onClick((): void => { if (this.pendingId.length > 0) { this.draft = this.pendingText; this.send() } else this.load() }) }
          Row() { TextArea({ text: this.draft, placeholder: this.t('personal.ask') }).enabled(!this.busy && !this.loading).layoutWeight(1).maxLines(5).onChange((value: string): void => { this.draft = value }); Button(this.t('personal.send')).enabled(!this.busy && !this.loading && this.draft.trim().length > 0 && this.assistantEnabled && this.assistantSubscribed).onClick((): void => { this.send() }) }
          Row() { Button(this.t('personal.newChat')).enabled(!this.busy && !this.loading && this.pendingId.length === 0).onClick((): void => { this.resetConversation(); this.saveConversation() }); if (this.assistantEnabled) Button(this.t('common.off')).enabled(!this.busy).onClick((): void => { this.configure('assistant', false) }) }
        } else {
          if (!this.calendarEnabled || !this.calendarSubscribed) { Text(this.t(this.calendarSubscribed ? 'personal.calendarConsent' : 'personal.subscription')).fontColor(Tk.L.fgMuted); if (this.calendarSubscribed) Button(this.t('common.on')).onClick((): void => { this.consent('calendar') }) }
          Row() { ForEach([1, 3, 5], (days: number): void => { Button(days === 1 ? this.t('personal.today') : this.t('personal.nextDays', { 'days': days })).onClick((): void => { this.days = days }) }); Button(this.t('common.refresh')).enabled(!this.loading).onClick((): void => { this.load() }) }
          Select(this.projectOptions()).selected(0).onSelect((index: number): void => { this.project = index === 0 ? '' : this.projectChoices()[index - 1].identity() })
          Row() {
            Text(this.t('personal.reminders')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.reminders }).enabled(this.calendarEnabled && this.calendarSubscribed).onChange((enabled: boolean): void => { if (!enabled) { this.reminders = false; CalendarReminders.clear() } else CalendarReminders.enable().then(async (allowed: boolean): Promise<void> => { this.reminders = allowed; if (!allowed || !await CalendarReminders.replace(this.events)) this.calendarError = this.t('personal.remindersUnavailable') }) })
          }
          Text(this.t('personal.remindersHint')).fontSize(12).fontColor(Tk.L.fgMuted)
          Scroll() {
            Column({ space: Tk.Sp.s3 }) {
              if (upcomingEvents(this.events, this.days, this.project).length === 0) Text(this.t('personal.noEvents')).fontColor(Tk.L.fgMuted)
              ForEach(upcomingEvents(this.events, this.days, this.project), (event: PersonalEvent): void => { Column({ space: Tk.Sp.s2 }) { Text(event.title).fontSize(18).fontWeight(FontWeight.Medium); Text(event.dueDate + ' ' + event.dueTime + ' · ' + event.timeZone).fontColor(Tk.L.fgMuted); Text(event.projectName).fontColor(Tk.L.fgMuted) }.width('100%').alignItems(HorizontalAlign.Start).padding(Tk.Sp.s3).onClick((): void => { this.detail(event) }) }, (event: PersonalEvent): string => event.id)
            }.width('100%')
          }.layoutWeight(1).width('100%')
          if (this.calendarError.length > 0) Text(this.calendarError).fontColor(Tk.S.failed)
          if (this.calendarEnabled) Button(this.t('common.off')).onClick((): void => { this.configure('calendar', false); CalendarReminders.clear(); this.reminders = false })
        }
      }.padding(Tk.Sp.s3).width('100%').height('100%').backgroundColor(Tk.L.bg).direction(L10n.isRtl(this.locale) ? Direction.Rtl : Direction.Ltr)
    }.hideTitleBar(true).onShown((): void => { this.alive = true; this.load(); this.openNotification() }).onHidden((): void => { this.alive = false; this.version++; this.busy = false; this.loading = false })
  }
}
