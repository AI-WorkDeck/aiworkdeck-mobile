// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { http } from '@kit.NetworkKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { ContractCapabilities } from 'contract'
import { ServiceLocator } from '../services/ServiceLocator'
import { PersonalConversationStore } from '../services/PersonalConversationStore'
import { CalendarReminders } from '../services/CalendarReminders'
import { stripEmoji } from '../model/ReplyText'
import { PersonalCopyTarget, PersonalDesktopCopy, DesktopCopyRequest, DesktopCopyReceipt, personalCopyTargets, copyNeedsUpgrade, PersonalEvent, PersonalSource, PersonalMessage, PersonalConversation, personalMessages, personalHistorySources, personalSourceDate, personalEvents, personalSources, stringField, upcomingEvents } from '../model/PersonalWorkspace'
import { ProjectFilesRequest } from './ProjectFilesRequest'
import { RelayProject } from '../model/Capture'
import { Tk } from '../design/Tokens'
import { trIn, LOCALE_ZH, L10n } from '../design/L10n'
import { errorText } from './Feedback'
@Component
export struct Personal {
  stack: NavPathStack = new NavPathStack()
  @StorageProp('awdLocale') locale: string = LOCALE_ZH
  @StorageLink('personalCalendarEventId') @Watch('openNotification') notificationId: string = ''
  @State reportConversationId: string = ''
  @State reportDescription: string = ''
  @State reporting: boolean = false
  @State reportSubmitted: boolean = false
  @State reportError: string = ''
  @State tab: string = 'assistant'
  @State assistantEnabled: boolean = false
  @State assistantSubscribed: boolean = false
  @State assistantFrozen: boolean = false
  @State backupEnabled: boolean = false
  @State calendarEnabled: boolean = false
  @State calendarWritable: boolean = false
  @State calendarSubscribed: boolean = false
  @State calendarFrozen: boolean = false
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
  @State copyTargets: PersonalCopyTarget[] = []
  @State copyUpgrade: boolean = false
  @State desktopCopy: PersonalDesktopCopy | null = null
  @State copyReady: boolean = false
  @State copySuccess: string = ''
  @State reminders: boolean = false
  private session: string = ''
  private host: string = ''
  private alive: boolean = false
  @State conversationId: string = ''
  private pendingId: string = ''
  private pendingText: string = ''
  private pendingConversationId: string = ''
  private conversationStore: PersonalConversationStore | null = null
  private version: number = 0
  private async current(version: number): Promise<boolean> {
    return this.alive && version === this.version && this.conversationStore !== null && await this.conversationStore.isCurrent() && this.alive && version === this.version
  }
  private async saveConversation(): Promise<boolean> {
    const value: PersonalConversation = new PersonalConversation()
    value.conversationId = this.conversationId; value.pendingId = this.pendingId
    value.pendingText = this.pendingText; value.pendingConversationId = this.pendingConversationId
    value.desktopCopy = this.desktopCopy
    return this.conversationStore !== null ? await this.conversationStore.save(value) : false
  }
  private resetConversation(): void {
    this.reportConversationId = ''; this.reportDescription = ''; this.reportSubmitted = false; this.reportError = ''
    this.desktopCopy = null; this.copyUpgrade = false; this.copyTargets = []; this.copyReady = false; this.copySuccess = ''; this.messages = []; this.sources = []; this.conversationId = ''; this.pendingId = ''; this.pendingText = ''; this.pendingConversationId = ''; this.draft = ''
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
    this.desktopCopy = value.desktopCopy
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
      if (await this.current(version)) await this.restoreDesktopCopy(version)
    }
  }
  private t(key: string, vars?: Record<string, string | number>): string { return trIn(this.locale, key, vars) }
  aboutToAppear(): void {
    this.alive = true; this.host = ServiceLocator.baseUrl()
    CalendarReminders.restore().then((enabled: boolean): void => { if (this.alive) this.reminders = enabled })
    ServiceLocator.session.current().then((session: string | null): void => { if (session !== null && this.alive) { this.session = session; this.load() } })
  }
  aboutToDisappear(): void { this.alive = false; this.version++ }
  private cloudAllowed(state: Record<string, Object>, permission: string): boolean {
    const value: Object | undefined = state['cloudAccess']
    if (value === undefined || value === null) return state['subscriptionActive'] === true
    return (value as Record<string, Object>)[permission] === true
  }
  private cloudFrozen(state: Record<string, Object>): boolean {
    const value: Object | undefined = state['cloudAccess']
    if (value === undefined || value === null) return false
    return (value as Record<string, Object>)['frozen'] === true
  }
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
        this.assistantEnabled = status['enabled'] === true; this.assistantSubscribed = this.cloudAllowed(status, 'canUse'); this.assistantFrozen = this.cloudFrozen(status); this.backupEnabled = status['backupEnabled'] === true
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
        this.calendarEnabled = calendar['enabled'] === true; this.calendarSubscribed = this.cloudAllowed(calendar, 'canRead'); this.calendarFrozen = this.cloudFrozen(calendar); this.calendarWritable = this.cloudAllowed(calendar, 'canWrite')
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
  private async copyMessage(message: PersonalMessage): Promise<void> {
    const version: number = this.version
    if (!await this.current(version)) return
    const text: string = this.t('personal.aiGenerated') + '\n' + stripEmoji(message.content)
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)) }
    catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
  }
  private async openReport(): Promise<void> {
    const version: number = this.version
    if (this.reporting || this.conversationId.length === 0 || !await this.current(version)) return
    this.reportConversationId = this.conversationId; this.reportDescription = ''; this.reportSubmitted = false; this.reportError = ''
  }
  private async submitReport(): Promise<void> {
    const version: number = this.version
    const id: string = this.reportConversationId
    if (this.reporting || this.reportSubmitted || id.length === 0 || this.reportDescription.trim().length === 0 || !await this.current(version)) return
    if (this.reporting || this.reportSubmitted || this.reportConversationId !== id) return
    this.reporting = true; this.reportError = ''
    try {
      await ServiceLocator.backend.reportAssistant(id, this.reportDescription, this.session)
      if (await this.current(version) && this.reportConversationId === id) this.reportSubmitted = true
    } catch (e) { if (await this.current(version) && this.reportConversationId === id) this.reportError = this.t('error.network') }
    finally { this.reporting = false }
  }
  private async prepareCopy(): Promise<void> {
    const version: number = this.version
    if (this.busy || this.loading || this.pendingId.length > 0 || this.conversationId.length === 0 || !await this.current(version)) return
    if (this.loading || this.busy) return
    this.loading = true; this.error = ''; this.copySuccess = ''
    try {
      const projects: RelayProject[] = await ServiceLocator.backend.myProjects()
      if (await this.current(version)) { this.copyTargets = personalCopyTargets(projects); this.copyUpgrade = copyNeedsUpgrade(projects); this.copyReady = true }
    } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
    finally { if (version === this.version) this.loading = false }
  }
  private confirmCopy(project: PersonalCopyTarget): void {
    const version: number = this.version
    const id: string = this.conversationId
    this.getUIContext().showAlertDialog({ title: this.copyTargetLabel(project), message: this.t('personal.copy.hint'), primaryButton: { value: this.t('common.cancel'), action: (): void => {} }, secondaryButton: { value: this.t('common.ok'), action: (): void => { this.copyTo(project, id, version) } } })
  }
  private async copyTo(project: PersonalCopyTarget, id: string, version: number): Promise<void> {
    const target: number = project.cloudId
    if (this.busy || this.loading || this.pendingId.length > 0 || (target === 0 && project.desktop === null) || this.conversationId !== id || !await this.current(version)) return
    if (this.loading || this.busy) return
    if (project.desktop !== null) {
      const request: DesktopCopyRequest = new DesktopCopyRequest()
      request.requestId = util.generateRandomUUID(true); request.sourceConversationId = id
      request.targetProjectUid = project.desktop.projectUid ?? ''; request.targetDeviceId = project.desktop.deviceId; request.targetProjectKey = project.desktop.key
      if (this.desktopCopy !== null && this.desktopCopy.request.sameTarget(request) && (this.desktopCopy.receipt === null || !this.desktopCopy.receipt.terminal())) request.requestId = this.desktopCopy.request.requestId
      else {
        this.loading = true
        try {
          const recent: Record<string, Object>[] = await ServiceLocator.backend.personalDesktopCopies(id, this.session)
          if (!await this.current(version) || this.conversationId !== id) return
          let matched: DesktopCopyReceipt | null = null
          for (const raw of recent) {
            const receipt: DesktopCopyReceipt | null = DesktopCopyReceipt.from(raw)
            if (receipt === null || receipt.request.sourceConversationId !== id) throw new Error(this.t('error.badResponse'))
            if (matched === null && receipt.request.sameTarget(request)) matched = receipt
          }
          if (matched !== null && !matched.terminal()) request.requestId = matched.request.requestId
        } catch (e) { if (await this.current(version)) this.error = this.t('personal.copy.unknown'); return }
        finally { if (version === this.version) this.loading = false }
      }
      await this.submitDesktopCopy(request, version); return
    }
    this.loading = true; this.error = ''
    try {
      const result: Record<string, Object> = await this.request('assistant/conversations/' + encodeURIComponent(id) + '/copy-to-project', http.RequestMethod.POST, { 'targetProjectId': target })
      if (!await this.current(version) || this.conversationId !== id) return
      if (result['mode'] !== 'copy' || result['sourcePreserved'] !== true || result['filesCopied'] !== false || result['sourceConversationId'] !== id || result['targetProjectId'] !== target) throw new Error(this.t('error.badResponse'))
      this.copySuccess = this.t('personal.copy.success'); this.copyReady = false
    } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
    finally { if (version === this.version) this.loading = false }
  }
  private copyTargetLabel(target: PersonalCopyTarget): string {
    return target.project.name + ' · ' + (target.desktop === null ? this.t('personal.copy.cloud') : (target.desktop.deviceName ?? target.desktop.deviceId))
  }
  private async submitDesktopCopy(request: DesktopCopyRequest, version: number): Promise<void> {
    if (this.loading || this.busy || request.sourceConversationId !== this.conversationId || !await this.current(version)) return
    this.loading = true; this.error = ''; this.copySuccess = ''
    try {
      const copy: PersonalDesktopCopy = new PersonalDesktopCopy(request)
      this.desktopCopy = copy
      if (!await this.saveConversation() || !await this.current(version)) return
      const raw: Record<string, Object> = await this.request('assistant/conversations/' + encodeURIComponent(request.sourceConversationId) + '/copy-to-desktop', http.RequestMethod.POST, request.body())
      const receipt: DesktopCopyReceipt | null = DesktopCopyReceipt.from(raw, request)
      if (!await this.current(version) || this.desktopCopy?.request.requestId !== request.requestId) return
      if (receipt === null) throw new Error(this.t('error.badResponse'))
      const updated: PersonalDesktopCopy = new PersonalDesktopCopy(request); updated.receipt = receipt; this.desktopCopy = updated
      await this.saveConversation(); this.copyReady = false
    } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
    finally { if (version === this.version) this.loading = false }
  }
  private async restoreDesktopCopy(version: number): Promise<void> {
    const id: string = this.conversationId
    if (id.length === 0 || !await this.current(version)) return
    try {
      if (this.desktopCopy === null) {
        const recent: Record<string, Object>[] = await ServiceLocator.backend.personalDesktopCopies(id, this.session)
        if (!await this.current(version) || this.conversationId !== id || this.desktopCopy !== null) return
        for (const raw of recent) {
          const receipt: DesktopCopyReceipt | null = DesktopCopyReceipt.from(raw)
          if (receipt === null || receipt.request.sourceConversationId !== id) throw new Error(this.t('error.badResponse'))
        }
        if (recent.length > 0) {
          const receipt: DesktopCopyReceipt | null = DesktopCopyReceipt.from(recent[0])
          if (receipt !== null) { const copy: PersonalDesktopCopy = new PersonalDesktopCopy(receipt.request); copy.receipt = receipt; this.desktopCopy = copy; await this.saveConversation() }
        }
      } else if (this.desktopCopy.request.sourceConversationId === id && (this.desktopCopy.receipt === null || !this.desktopCopy.receipt.terminal())) {
        const copy: PersonalDesktopCopy = this.desktopCopy
        const raw: Record<string, Object> = await this.request('assistant/desktop-copies/' + encodeURIComponent(copy.request.requestId))
        if (!await this.current(version) || this.conversationId !== id || this.desktopCopy?.request.requestId !== copy.request.requestId) return
        const receipt: DesktopCopyReceipt | null = DesktopCopyReceipt.from(raw, copy.request)
        if (receipt === null) throw new Error(this.t('error.badResponse'))
        const updated: PersonalDesktopCopy = new PersonalDesktopCopy(copy.request); updated.receipt = receipt; this.desktopCopy = updated; await this.saveConversation()
      }
    } catch (e) { if (await this.current(version)) this.error = errorText(e as Object) }
  }
  private async refreshDesktopCopy(): Promise<void> {
    if (this.loading || this.busy) return
    const version: number = this.version; this.loading = true
    try { await this.restoreDesktopCopy(version) } finally { if (version === this.version) this.loading = false }
  }
  private async retryDesktopCopy(): Promise<void> {
    const copy: PersonalDesktopCopy | null = this.desktopCopy
    if (copy === null || !copy.canRetry() || this.loading || this.busy) return
    const request: DesktopCopyRequest = new DesktopCopyRequest()
    request.sourceConversationId = copy.request.sourceConversationId; request.targetProjectUid = copy.request.targetProjectUid
    request.targetDeviceId = copy.request.targetDeviceId; request.targetProjectKey = copy.request.targetProjectKey
    request.requestId = copy.receipt === null ? copy.request.requestId : util.generateRandomUUID(true)
    await this.submitDesktopCopy(request, this.version)
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
          if (!this.assistantEnabled || !this.assistantSubscribed) { Text(this.t(this.assistantSubscribed ? 'personal.assistantConsent' : (this.assistantFrozen ? 'postpaid.restricted' : 'personal.subscription'))).fontColor(Tk.L.fgMuted); if (this.assistantSubscribed && this.backupEnabled) Button(this.t('common.on')).onClick((): void => { this.consent('assistant') }) }
          if (!this.assistantSubscribed || !this.backupEnabled) Button(this.t(this.assistantSubscribed ? 'backup.title' : 'settings.account')).onClick((): void => { this.stack.pushPath(new NavPathInfo('Settings', '')) })
          Scroll() {
            Column({ space: Tk.Sp.s4 }) {
              if (this.messages.length === 0) { Text(this.t('personal.ask')).fontSize(20); Text(this.t('personal.summaries', { 'count': this.summaryCount })).fontColor(Tk.L.fgMuted) }
              ForEach(this.messages, (message: PersonalMessage): void => {
                Column({ space: Tk.Sp.s2 }) {
                  if (message.role === 'assistant') Text(this.t('personal.aiGenerated')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Tk.L.fg)
                  Text(message.role === 'assistant' ? stripEmoji(message.content) : message.content).fontSize(16).copyOption(message.role === 'assistant' ? CopyOptions.None : CopyOptions.InApp).fontColor(Tk.L.fg).width('100%')
                  if (message.role === 'assistant') Button(this.t('personal.copyMessage')).onClick((): void => { this.copyMessage(message) })
                }.width('100%').alignItems(HorizontalAlign.Start).padding(Tk.Sp.s3)
              })
              if (this.sources.length > 0) Text(this.t('personal.sources')).fontColor(Tk.L.fgMuted)
              ForEach(this.sources, (source: PersonalSource): void => { Button(source.projectName + ' · ' + personalSourceDate(source.sourceUpdatedAt, this.locale)).onClick((): void => { this.openProject(source) }) })
              if (this.busy) Text(this.t('personal.processing')).fontColor(Tk.L.fgMuted)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).width('100%')
          if (this.error.length > 0) { Text(this.error).fontColor(Tk.S.failed); Button(this.t('project.retry')).enabled(!this.busy).onClick((): void => { if (this.pendingId.length > 0) { this.draft = this.pendingText; this.send() } else this.load() }) }
          if (this.desktopCopy !== null) {
            Text(this.t(this.desktopCopy.statusKey())).fontColor(Tk.L.fgMuted)
            Row() {
              Button(this.t('common.refresh')).enabled(!this.loading && !this.busy).onClick((): void => { this.refreshDesktopCopy() })
              if (this.desktopCopy.canRetry()) Button(this.t('project.retry')).enabled(!this.loading && !this.busy).onClick((): void => { this.retryDesktopCopy() })
            }
          }
          if (this.copySuccess.length > 0) Text(this.copySuccess).fontColor(Tk.L.fgMuted)
          if (this.messages.length > 0) Button(this.t('personal.copy.title')).enabled(!this.busy && !this.loading && this.pendingId.length === 0).onClick((): void => { this.prepareCopy() })
          if (this.conversationId.length > 0 && this.messages.some((message: PersonalMessage): boolean => message.role === 'assistant')) Button(this.t('personal.report.conversation')).enabled(!this.reporting).onClick((): void => { this.openReport() })
          if (this.reportConversationId.length > 0) {
            Text(this.t('personal.report.conversation')).fontWeight(FontWeight.Medium)
            if (this.reportSubmitted) Text(this.t('personal.report.sent'))
            else {
              Text(this.t('personal.report.privacy')).fontSize(12).fontColor(Tk.L.fgMuted)
              TextArea({ text: this.reportDescription, placeholder: this.t('personal.report.reason') }).maxLength(2000).maxLines(3).enabled(!this.reporting).onChange((value: string): void => { this.reportDescription = value })
              if (this.reportError.length > 0) Text(this.reportError).fontColor(Tk.S.failed)
              Button(this.t('personal.send')).enabled(!this.reporting && this.reportDescription.trim().length > 0).onClick((): void => { this.submitReport() })
            }
            Button(this.t(this.reportSubmitted ? 'common.close' : 'common.cancel')).enabled(!this.reporting).onClick((): void => { this.reportConversationId = '' })
          }
          if (this.copyReady) {
            Text(this.t('personal.copy.hint')).fontColor(Tk.L.fgMuted)
            if (this.copyUpgrade) Text(this.t('personal.copy.upgrade')).fontColor(Tk.L.fgMuted)
            if (this.copyTargets.length === 0) Text(this.t('project.emptyTitle')).fontColor(Tk.L.fgMuted)
            Select(this.copyTargets.map((project: PersonalCopyTarget): SelectOption => { return { value: this.copyTargetLabel(project) } })).value(this.t('personal.copy.title')).enabled(!this.busy && !this.loading).onSelect((index: number): void => { if (index >= 0 && index < this.copyTargets.length) this.confirmCopy(this.copyTargets[index]) })
          }
          Row() { TextArea({ text: this.draft, placeholder: this.t('personal.ask') }).enabled(!this.busy && !this.loading).layoutWeight(1).maxLines(5).onChange((value: string): void => { this.draft = value }); Button(this.t('personal.send')).enabled(!this.busy && !this.loading && this.draft.trim().length > 0 && this.assistantEnabled && this.assistantSubscribed).onClick((): void => { this.send() }) }
          Row() { Button(this.t('personal.newChat')).enabled(!this.busy && !this.loading && this.pendingId.length === 0).onClick((): void => { this.resetConversation(); this.saveConversation() }); if (this.assistantEnabled) Button(this.t('common.off')).enabled(!this.busy).onClick((): void => { this.configure('assistant', false) }) }
        } else {
          if (!this.calendarEnabled || !this.calendarSubscribed) {
            Text(this.t(this.calendarSubscribed ? 'personal.calendarConsent' : (this.calendarFrozen ? 'postpaid.restricted' : 'personal.subscription'))).fontColor(Tk.L.fgMuted)
            if (!this.calendarSubscribed) Button(this.t('settings.account')).onClick((): void => { this.stack.pushPath(new NavPathInfo('Settings', '')) })
            if (this.calendarWritable) Button(this.t('common.on')).onClick((): void => { this.consent('calendar') })
          }
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
