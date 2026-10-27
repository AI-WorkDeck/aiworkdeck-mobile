// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { getSession, personalRequest, uuid, setPersonalPreview } from '../../utils/api'
import { PersonalConversation, upcoming, projectIdentity, type AssistantStatus, type CalendarSnapshot, type PersonalReply, type PersonalSource, type CalendarEvent, type PersonalMessage } from '../../utils/personal'
import { PERSONAL_CONSENT_VERSION } from '../../utils/contract/capabilities'
import { readPersonalConversation, savePersonalConversation, clearPersonalConversation } from '../../utils/personal-storage'
import { t, getLocale, isRtl } from '../../utils/i18n'
import type { Metrics } from '../../utils/layout'

Page({
  data: {
    tab: 'assistant', direction: 'ltr', labels: {} as Record<string, string>, metrics: {} as Metrics,
    status: null as AssistantStatus | null, calendar: null as CalendarSnapshot | null,
    messages: [] as PersonalMessage[], sources: [] as PersonalSource[], events: [] as CalendarEvent[],
    projects: [] as { id: string; name: string }[], projectIndex: 0, days: 3,
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
    if (!getSession()) { wx.reLaunch({ url: '/pages/login/login' }); return }
    if (this.session !== getSession()) { this.conversation = new PersonalConversation(); this.session = getSession(); this.setData({ draft: '', messages: [], sources: [], status: null, calendar: null, events: [], busy: false, loading: false, error: '', calendarError: '' }); this.restoreLocal() }
    const labels: Record<string, string> = {}
    for (const key of ['assistant', 'calendar', 'ask', 'send', 'processing', 'newChat', 'assistantConsent', 'calendarConsent', 'subscription', 'remindersUnavailable', 'noEvents', 'today', 'sources']) labels[key] = t('personal.' + key)
    Object.assign(labels, { backup: t('backup.title'), account: t('settings.account'), projects: t('workspace.title'), capture: t('workspace.capture'), on: t('common.on'), off: t('common.off'), retry: t('project.retry'), refresh: t('common.refresh'), settings: t('home.settings'), next3: t('personal.nextDays', { days: 3 }), next5: t('personal.nextDays', { days: 5 }), files: t('project.files') })
    this.setData({ labels, direction: isRtl() ? 'rtl' : 'ltr', sources: this.displaySources(this.conversation.sources) }); this.load()
  },
  onUnload() { this.active = false },
  alive() { return this.active && this.session === getSession() },
  async load() {
    const account = this.session
    if (this.data.loading) return
    this.setData({ loading: true })
    try { const status = await personalRequest<AssistantStatus>('assistant/status'); if (this.alive() && this.session === account) {
      this.setData({ status, error: '', summary: t('personal.summaries', { count: status.summaryCount }) })
      if (status.consentEnabled === false) { this.conversation = new PersonalConversation(); clearPersonalConversation(); this.setData({ messages: [], sources: [], draft: '' }) }
    } }
    catch (error) { if (this.alive() && this.session === account) this.setData({ error: (error as Error).message }) }
    if (!this.alive() || this.session !== account) return
    try {
      const calendar = await personalRequest<CalendarSnapshot>('calendar/events')
      if (this.alive() && this.session === account) {
        const seen = new Set<string>()
        const projects = [{ id: '', name: t('personal.allProjects') }, ...calendar.events.filter(e => { const key = projectIdentity(e); if (seen.has(key)) return false; seen.add(key); return true }).map(e => ({ id: projectIdentity(e), name: e.projectName }))]
        this.setData({ calendar, projects, calendarError: '', projectIndex: 0 }); this.filter()
      }
    } catch (error) { if (this.alive() && this.session === account) this.setData({ calendarError: (error as Error).message }) }
    if (this.alive() && this.session === account) { this.setData({ loading: false }); if (!this.restored && this.data.status?.enabled) await this.restoreRemote() }
  },
  restoreLocal() {
    this.restored = false
    const saved = readPersonalConversation()
    if (saved) { this.conversation.conversationId = saved.conversationId; this.conversation.pending = saved.pending; this.setData({ draft: saved.pending?.message ?? '' }) }
  },
  displaySources(sources: PersonalSource[]): PersonalSource[] {
    return sources.map(source => { const date = new Date(source.sourceUpdatedAt ?? ''); return { ...source, sourceUpdatedAt: Number.isFinite(date.getTime()) ? date.toLocaleString(getLocale(), { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '' } })
  },
  saveRecent() { savePersonalConversation({ conversationId: this.conversation.conversationId, pending: this.conversation.pending }) },
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
    if (this.data.busy || !this.data.draft.trim() || !this.data.status?.enabled) return
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
  onRetry() { if (this.conversation.pending) this.onSend(); else this.load() },
  onNewChat() { if (this.data.busy || this.conversation.pending) return; this.conversation = new PersonalConversation(); this.saveRecent(); this.setData({ messages: [], sources: [], error: '' }) },
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
        if (feature === 'assistant' && !enabled) { this.conversation = new PersonalConversation(); clearPersonalConversation(); this.setData({ draft: '', messages: [], sources: [], error: '' }) }
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
