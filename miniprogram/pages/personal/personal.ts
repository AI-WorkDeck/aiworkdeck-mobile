// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { cloudCanUse, cloudCanRead, cloudCanWrite } from '../../utils/cloud-access'
import { getSession, myProjects, personalRequest, uuid, setPersonalPreview } from '../../utils/api'
import { PersonalConversation, personalCopyTarget, personalCopyDestinations, desktopCopyNeedsUpgrade, desktopCopyMatches, desktopCopyTerminal, desktopCopyStatusKey, type PersonalCopyDestination, type DesktopCopyReceipt, type PersonalCopyResult, upcoming, projectIdentity, type AssistantStatus, type CalendarSnapshot, type PersonalReply, type PersonalSource, type CalendarEvent, type PersonalMessage } from '../../utils/personal'
import { PERSONAL_CONSENT_VERSION } from '../../utils/contract/capabilities'
import { readPersonalConversation, savePersonalConversation, clearPersonalConversation } from '../../utils/personal-storage'
import { t, getLocale, isRtl } from '../../utils/i18n'
import type { Metrics } from '../../utils/layout'

Page({
  data: {
    tab: 'assistant', direction: 'ltr', labels: {} as Record<string, string>, metrics: {} as Metrics,
    assistantAllowed: false, calendarAllowed: false, calendarWritable: false,
    status: null as AssistantStatus | null, calendar: null as CalendarSnapshot | null,
    messages: [] as PersonalMessage[], sources: [] as PersonalSource[], events: [] as CalendarEvent[],
    projects: [] as { id: string; name: string }[], projectIndex: 0, days: 3,
    copyTargets: [] as PersonalCopyDestination[], copyReady: false, copyUpgrade: false, copyStatus: '', copyCanRetry: false, copySuccess: '',
    draft: '', busy: false, loading: false, error: '', calendarError: '', summary: '',
  },
  conversation: new PersonalConversation(),
  session: null as string | null,
  active: true,
  restored: false,
  onLoad() {
    this.active = true
    this.conversation = new PersonalConversation()
    this.session = getSession()
    this.restoreLocal()
    this.setData({ metrics: getApp<{ globalData: { metrics: Metrics } }>().globalData.metrics })
  },
  onShow() {
    if (!getSession()) { wx.reLaunch({ url: '/pages/start/start' }); return }
    if (this.session !== getSession()) { this.conversation = new PersonalConversation(); this.session = getSession(); this.setData({ draft: '', messages: [], sources: [], status: null, calendar: null, assistantAllowed: false, calendarAllowed: false, calendarWritable: false, events: [], copyTargets: [], copyReady: false, copyStatus: '', copyCanRetry: false, copySuccess: '', busy: false, loading: false, error: '', calendarError: '' }); this.restoreLocal() }
    const labels: Record<string, string> = {}
    for (const key of ['assistant', 'calendar', 'ask', 'send', 'processing', 'newChat', 'assistantConsent', 'calendarConsent', 'subscription', 'remindersUnavailable', 'noEvents', 'today', 'sources']) labels[key] = t('personal.' + key)
    labels.subscription = t('postpaid.restricted')
    Object.assign(labels, { copyTitle: t('personal.copy.title'), copyHint: t('personal.copy.hint'), copyUpgrade: t('personal.copy.upgrade'), emptyProjects: t('project.emptyTitle'), backup: t('backup.title'), account: t('settings.account'), projects: t('workspace.title'), capture: t('workspace.capture'), on: t('common.on'), off: t('common.off'), retry: t('project.retry'), refresh: t('common.refresh'), settings: t('home.settings'), next3: t('personal.nextDays', { days: 3 }), next5: t('personal.nextDays', { days: 5 }), files: t('project.files') })
    this.setData({ labels, direction: isRtl() ? 'rtl' : 'ltr', sources: this.displaySources(this.conversation.sources) }); this.renderCopy(); this.load()
  },
  onUnload() { this.active = false },
  alive() { return this.active && this.session === getSession() },
  async load() {
    const account = this.session
    if (this.data.loading) return
    this.setData({ loading: true })
    try { const status = await personalRequest<AssistantStatus>('assistant/status'); if (this.alive() && this.session === account) {
      this.setData({ assistantAllowed: cloudCanUse(status), status, error: '', summary: t('personal.summaries', { count: status.summaryCount }) })
      if (status.consentEnabled === false) { this.conversation = new PersonalConversation(); clearPersonalConversation(); this.setData({ messages: [], sources: [], draft: '', copyStatus: '', copyCanRetry: false }) }
    } }
    catch (error) { if (this.alive() && this.session === account) this.setData({ error: (error as Error).message }) }
    if (!this.alive() || this.session !== account) return
    try {
      const calendar = await personalRequest<CalendarSnapshot>('calendar/events')
      if (this.alive() && this.session === account) {
        const seen = new Set<string>()
        const projects = [{ id: '', name: t('personal.allProjects') }, ...calendar.events.filter(e => { const key = projectIdentity(e); if (seen.has(key)) return false; seen.add(key); return true }).map(e => ({ id: projectIdentity(e), name: e.projectName }))]
        this.setData({ calendarAllowed: cloudCanRead(calendar), calendarWritable: cloudCanWrite(calendar), calendar, projects, calendarError: '', projectIndex: 0 }); this.filter()
      }
    } catch (error) { if (this.alive() && this.session === account) this.setData({ calendarError: (error as Error).message }) }
    if (this.alive() && this.session === account) { this.setData({ loading: false }); if (!this.restored && this.data.status?.enabled) await this.restoreRemote() }
  },
  restoreLocal() {
    this.restored = false
    const saved = readPersonalConversation()
    if (saved) { this.conversation.conversationId = saved.conversationId; this.conversation.pending = saved.pending; this.conversation.desktopCopy = saved.desktopCopy; this.setData({ draft: saved.pending?.message ?? '' }); this.renderCopy() }
  },
  displaySources(sources: PersonalSource[]): PersonalSource[] {
    return sources.map(source => { const date = new Date(source.sourceUpdatedAt ?? ''); return { ...source, sourceUpdatedAt: Number.isFinite(date.getTime()) ? date.toLocaleString(getLocale(), { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '' } })
  },
  saveRecent() { savePersonalConversation({ conversationId: this.conversation.conversationId, pending: this.conversation.pending, desktopCopy: this.conversation.desktopCopy }) },
  async restoreRemote() {
    if (this.data.busy) return
    const account = this.session
    const question = this.conversation.pending
    let id = this.conversation.conversationId
    this.setData({ busy: true })
    try {
      let reply: PersonalReply | undefined
      if (question) {
        reply = await personalRequest<PersonalReply>('assistant/requests/' + question.requestId)
        for (let attempt = 0; reply.status === 'running' && attempt < 120; attempt++) {
          await new Promise<void>(resolve => setTimeout(resolve, 2000))
          if (!this.alive() || this.session !== account) return
          reply = await personalRequest<PersonalReply>('assistant/requests/' + question.requestId)
        }
        if (reply.status !== 'completed' || reply.requestId !== question.requestId) throw new Error(t('error.network'))
        id = reply.conversationId
      }
      if (id) {
        if (!this.alive() || this.session !== account) return
        const history = await personalRequest<{ conversationId: string; messages: PersonalMessage[] }>('assistant/conversations/' + id)
        if (!this.alive() || this.session !== account) return
        if (history.conversationId !== id) throw new Error(t('error.badResponse'))
        this.conversation.conversationId = id; this.conversation.messages = history.messages
        this.conversation.sources = reply?.sources ?? []; this.conversation.pending = undefined; this.saveRecent()
        this.setData({ messages: history.messages, sources: this.displaySources(this.conversation.sources), draft: '', error: '' })
        if (!this.conversation.desktopCopy) {
          try {
            const receipts = await personalRequest<DesktopCopyReceipt[]>('assistant/conversations/' + encodeURIComponent(id) + '/desktop-copies')
            const latest = Array.isArray(receipts) ? receipts[0] : undefined
            if (this.alive() && this.session === account && this.conversation.conversationId === id && latest?.sourceConversationId === id && desktopCopyMatches(latest, latest)) {
              this.conversation.desktopCopy = { request: { requestId: latest.requestId, sourceConversationId: id, targetProjectUid: latest.targetProjectUid, targetDeviceId: latest.targetDeviceId, targetProjectKey: latest.targetProjectKey }, receipt: latest }
              this.saveRecent(); this.renderCopy()
            }
          } catch { /* Older servers may not expose desktop copies yet. */ }
        }
      }
      this.restored = true
    } catch (error) { if (this.alive() && this.session === account) this.setData({ error: (error as Error).message }) }
    finally { if (this.alive() && this.session === account) this.setData({ busy: false }) }
  },
  onTab(e: { currentTarget: { dataset: { tab: string } } }) { this.setData({ tab: e.currentTarget.dataset.tab }) },
  onInput(e: { detail: { value: string } }) { this.setData({ draft: e.detail.value }) },
  onDays(e: { currentTarget: { dataset: { days: string } } }) { this.setData({ days: Number(e.currentTarget.dataset.days) }); this.filter() },
  onProject(e: { detail: { value: string } }) { this.setData({ projectIndex: Number(e.detail.value) }); this.filter() },
  filter() { this.setData({ events: upcoming(this.data.calendar?.events ?? [], this.data.days, this.data.projects[this.data.projectIndex]?.id ?? '') }) },
  async onSend() {
    if (this.data.busy || this.data.loading || !this.data.draft.trim() || !this.data.status?.enabled || !cloudCanUse(this.data.status)) return
    const account = this.session
    const question = this.conversation.question(this.data.draft.trim(), uuid)
    this.setData({ busy: true, error: '' })
    try {
      this.saveRecent()
      let reply = await personalRequest<PersonalReply>('assistant/chat', 'POST', { ...question })
      for (let attempt = 0; reply.status === 'running' && attempt < 120; attempt++) {
        await new Promise<void>(resolve => setTimeout(resolve, 2000))
        if (!this.alive() || this.session !== account) return
        reply = await personalRequest<PersonalReply>('assistant/requests/' + question.requestId)
      }
      if (!this.alive() || this.session !== account) return
      if (reply.status !== 'completed') throw new Error(t('error.network'))
      if (!this.conversation.accept(reply)) throw new Error(t('error.badResponse'))
      this.saveRecent()
      this.setData({ draft: '', messages: [...this.conversation.messages], sources: this.displaySources(this.conversation.sources) })
    } catch (error) { if (this.alive() && this.session === account) this.setData({ error: (error as Error).message }) }
    finally { if (this.alive() && this.session === account) this.setData({ busy: false }) }
  },
  async onPrepareCopy() {
    if (this.data.busy || this.data.loading || this.conversation.pending || !this.conversation.conversationId) return
    const account = this.session
    this.setData({ loading: true, error: '', copySuccess: '' })
    try {
      const projects = await myProjects()
      if (this.alive() && this.session === account) this.setData({ copyTargets: personalCopyDestinations(projects, t('personal.copy.cloud')), copyUpgrade: desktopCopyNeedsUpgrade(projects), copyReady: true })
    } catch (error) { if (this.alive() && this.session === account) this.setData({ error: (error as Error).message }) }
    finally { if (this.alive() && this.session === account) this.setData({ loading: false }) }
  },
  async onCopy(e: { detail: { value: string } }) {
    if (this.data.busy || this.data.loading || this.conversation.pending) return
    const id = this.conversation.conversationId
    const destination = this.data.copyTargets[Number(e.detail.value)]
    const project = destination?.project
    const target = project && personalCopyTarget(project)
    if (!id || !project || (!destination.desktop && !target)) return
    const account = this.session
    this.setData({ loading: true })
    try {
      const choice = await wx.showModal({ title: project.name, content: t('personal.copy.hint'), confirmText: t('common.ok'), cancelText: t('common.cancel') })
      if (!choice.confirm || !this.alive() || this.session !== account || this.conversation.conversationId !== id) return
      if (destination.desktop) {
        const location = destination.desktop
        const previous = this.conversation.desktopCopy
        if (!previous || previous.request.sourceConversationId !== id || previous.request.targetProjectUid !== location.projectUid || previous.request.targetDeviceId !== location.deviceId || previous.request.targetProjectKey !== location.key || desktopCopyTerminal(previous.receipt)) {
          const recent = await personalRequest<DesktopCopyReceipt[]>('assistant/conversations/' + encodeURIComponent(id) + '/desktop-copies')
          if (!this.alive() || this.session !== account || this.conversation.conversationId !== id) return
          if (!Array.isArray(recent) || recent.some(item => item.sourceConversationId !== id || !desktopCopyMatches(item, item))) throw new Error(t('error.badResponse'))
          const prior = recent.find(item => item.targetProjectUid === location.projectUid && item.targetDeviceId === location.deviceId && item.targetProjectKey === location.key)
          this.conversation.desktopCopy = prior && !desktopCopyTerminal(prior)
            ? { request: { requestId: prior.requestId, sourceConversationId: id, targetProjectUid: prior.targetProjectUid, targetDeviceId: prior.targetDeviceId, targetProjectKey: prior.targetProjectKey }, receipt: prior }
            : { request: { requestId: uuid(), sourceConversationId: id, targetProjectUid: location.projectUid!, targetDeviceId: location.deviceId, targetProjectKey: location.key } }
        }
        this.saveRecent(); this.renderCopy()
        await this.submitDesktopCopy(account)
        if (this.alive() && this.session === account) this.setData({ copyReady: false, error: '' })
        return
      }
      const result = await personalRequest<PersonalCopyResult>('assistant/conversations/' + encodeURIComponent(id) + '/copy-to-project', 'POST', { targetProjectId: target })
      if (!this.alive() || this.session !== account || this.conversation.conversationId !== id) return
      if (result.mode !== 'copy' || !result.sourcePreserved || result.filesCopied !== false || result.sourceConversationId !== id || result.targetProjectId !== target) throw new Error(t('error.badResponse'))
      this.setData({ copySuccess: t('personal.copy.success'), copyReady: false, error: '' })
    } catch (error) { if (this.alive() && this.session === account) this.setData({ error: (error as Error).message }) }
    finally { if (this.alive() && this.session === account) this.setData({ loading: false }) }
  },
  renderCopy() {
    const value = this.conversation.desktopCopy
    this.setData({ copyStatus: value ? t(desktopCopyStatusKey(value)) : '', copyCanRetry: !!value && (!value.receipt || ['FAILED', 'EXPIRED'].includes(value.receipt.status)) })
  },
  async submitDesktopCopy(account: string | null) {
    const value = this.conversation.desktopCopy
    if (!value) return
    const { sourceConversationId, ...body } = value.request
    const receipt = await personalRequest<DesktopCopyReceipt>('assistant/conversations/' + encodeURIComponent(sourceConversationId) + '/copy-to-desktop', 'POST', body)
    if (!this.alive() || this.session !== account || this.conversation.desktopCopy?.request.requestId !== value.request.requestId) return
    if (!desktopCopyMatches(receipt, value.request)) throw new Error(t('error.badResponse'))
    this.conversation.desktopCopy = { request: value.request, receipt }; this.saveRecent(); this.renderCopy()
  },
  async onCopyRefresh() {
    const value = this.conversation.desktopCopy
    if (!value || this.data.loading || this.data.busy) return
    const account = this.session
    this.setData({ loading: true })
    try {
      const receipt = await personalRequest<DesktopCopyReceipt>('assistant/desktop-copies/' + encodeURIComponent(value.request.requestId))
      if (!this.alive() || this.session !== account || this.conversation.desktopCopy?.request.requestId !== value.request.requestId) return
      if (!desktopCopyMatches(receipt, value.request)) throw new Error(t('error.badResponse'))
      this.conversation.desktopCopy = { request: value.request, receipt }; this.saveRecent(); this.renderCopy(); this.setData({ error: '' })
    } catch { if (this.alive() && this.session === account) this.setData({ error: t('personal.copy.unknown') }) }
    finally { if (this.alive() && this.session === account) this.setData({ loading: false }) }
  },
  async onCopyRetry() {
    const value = this.conversation.desktopCopy
    if (!value || !this.data.copyCanRetry || this.data.loading || this.data.busy) return
    const account = this.session
    this.setData({ loading: true })
    try {
      const choice = await wx.showModal({ title: t('personal.copy.title'), content: t('personal.copy.hint'), confirmText: t('common.ok'), cancelText: t('common.cancel') })
      if (!choice.confirm || !this.alive() || this.session !== account) return
      if (desktopCopyTerminal(value.receipt)) this.conversation.desktopCopy = { request: { ...value.request, requestId: uuid() } }
      this.saveRecent(); this.renderCopy()
      await this.submitDesktopCopy(account)
      if (this.alive() && this.session === account) this.setData({ error: '' })
    } catch { if (this.alive() && this.session === account) this.setData({ error: t('personal.copy.unknown') }) }
    finally { if (this.alive() && this.session === account) this.setData({ loading: false }) }
  },
  onRetry() { if (this.conversation.pending) this.onSend(); else this.load() },
  onNewChat() { if (this.data.busy || this.data.loading || this.conversation.pending) return; this.conversation = new PersonalConversation(); this.saveRecent(); this.setData({ messages: [], sources: [], error: '', copyTargets: [], copyReady: false, copyStatus: '', copyCanRetry: false, copySuccess: '' }) },
  async onConsent(e: { currentTarget: { dataset: { feature: string; enabled: boolean } } }) {
    if (this.data.loading || this.data.busy) return
    const account = this.session
    const feature = e.currentTarget.dataset.feature
    const enabled = e.currentTarget.dataset.enabled !== false
    if (enabled) {
      const confirm = await wx.showModal({ title: t('personal.' + feature), content: t('personal.' + feature + 'Consent'), confirmText: t('common.ok'), cancelText: t('common.cancel') })
      if (!confirm.confirm || !this.alive() || this.session !== account) return
    }
    this.setData({ loading: true })
    try {
      await personalRequest(feature + '/settings', 'PUT', { enabled, consentVersion: PERSONAL_CONSENT_VERSION })
      if (this.alive() && this.session === account) {
        if (feature === 'assistant' && !enabled) { this.conversation = new PersonalConversation(); clearPersonalConversation(); this.setData({ draft: '', messages: [], sources: [], error: '', copyStatus: '', copyCanRetry: false }) }
        this.setData({ loading: false }); await this.load()
      }
    }
    catch (error) { if (this.alive() && this.session === account) this.setData(feature === 'calendar' ? { calendarError: (error as Error).message } : { error: (error as Error).message }) }
    finally { if (this.alive() && this.session === account) this.setData({ loading: false }) }
  },
  onProjects() { wx.navigateTo({ url: '/pages/project/project' }) },
  onCapture() { wx.navigateTo({ url: '/pages/index/index' }) },
  onSettings() { wx.navigateTo({ url: '/pages/settings/settings' }) },
  onSource(e: { currentTarget: { dataset: { index: number; event?: boolean } } }) {
    const source = e.currentTarget.dataset.event ? this.data.events[e.currentTarget.dataset.index] : this.data.sources[e.currentTarget.dataset.index]
    if (!source) return
    setPersonalPreview({ deviceId: source.deviceId, deviceName: null, key: source.projectKey, name: source.projectName })
    wx.navigateTo({ url: '/pages/files/files' })
  },
})
