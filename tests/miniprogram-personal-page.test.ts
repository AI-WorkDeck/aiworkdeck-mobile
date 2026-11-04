// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { PersonalConversation, personalCopyDestinations, desktopCopyNeedsUpgrade } from '../miniprogram/utils/personal.ts'
let definition: any
;(globalThis as any).Page = (value: any) => { definition = value }
await import('../miniprogram/pages/personal/personal.ts')

function fixture() {
  let session = 'synthetic-account'
  let fail = true
  const calls: any[] = []
  let held: any
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => key === 'awd.session' ? session : undefined,
    removeStorageSync() {},
    setStorageSync() {},
    request(opts: any) {
      if (opts.url.endsWith('/auth/me')) { opts.success({statusCode:200,data:{code:0,data:{id:71}}}); return }
      if (opts.url.endsWith('/billing/cloud-state')) { opts.success({statusCode:404,data:{}}); return }
      calls.push(opts)
      if (opts.url.endsWith('/assistant/chat')) {
        if (fail) return opts.fail()
        held = opts
        return
      }
      const data = opts.url.endsWith('/assistant/status') ? { enabled: false, backupEnabled: true, subscriptionActive: true, summaryCount: 0 } : { enabled: false, subscriptionActive: true, events: [] }
      opts.success({ statusCode: 200, data: { code: 0, data } })
    },
  }
  const page = { ...definition, data: structuredClone(definition.data), conversation: new PersonalConversation(), active: true, session,
    setData(value: any) { Object.assign(this.data, value) } }
  page.data.status = { enabled: true, subscriptionActive: true, backupEnabled: true, summaryCount: 2 }
  page.data.draft = 'Synthetic question'
  return { page, calls, succeed() { fail = false }, changeAccount() { session = 'other-account' }, complete() { held.success({ statusCode: 200, data: { code: 0, data: { status: 'completed', requestId: held.data.requestId, conversationId: 'conversation', answer: 'Answer', sources: [] } } }) } }
}
test('failed transport preserves draft and repeats the same request UUID without a project selection', async () => {
  const { page, calls, succeed, complete } = fixture()
  await page.onSend()
  assert.equal(page.data.draft, 'Synthetic question')
  assert.equal(page.data.busy, false)
  const id = calls[0].data.requestId
  succeed()
  const pending = page.onSend()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(calls[1].data.requestId, id)
  assert.equal(calls[1].data.projectKey, undefined)
  complete(); await pending
  assert.equal(page.data.draft, '')
  assert.equal(page.data.messages.length, 2)
  assert.equal(calls[1].timeout, 240000)
})
test('late response after account switch cannot publish the former answer', async () => {
  const { page, succeed, changeAccount, complete } = fixture(); succeed()
  const pending = page.onSend(); await new Promise(resolve => setImmediate(resolve)); changeAccount(); complete(); await pending
  assert.equal(page.data.messages.length, 0)
})
test('assistant disable clears current conversation only after settings succeeds', async () => {
  const { page } = fixture()
  page.data.messages = [{ role: 'user', content: 'Private' }]
  page.conversation.question('Private', () => 'pending')
  await page.onConsent({ currentTarget: { dataset: { feature: 'assistant', enabled: false } } })
  assert.equal(page.data.messages.length, 0)
  assert.equal(page.data.draft, '')
  assert.equal(page.conversation.pending, undefined)
})
test('disabled assistant never sends entered text', async () => {
  const { page, calls } = fixture(); page.data.status.enabled = false
  await page.onSend(); assert.equal(calls.length, 0)
})

test('restart recovers original pending result and history with GET only', async () => {
  const { page } = fixture()
  const requests: string[] = []
  const stored = { scope: 'https://addin.aiworkdeck.com:71', pending: { message: 'Synthetic question', requestId: 'persisted-id' } }
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => key === 'awd.session' ? 'synthetic-account' : key === 'awd.user' ? { id: 71 } : key === 'awd.personalConversation' ? stored : undefined,
    setStorageSync() {},
    request(opts: any) {
      if (opts.url.endsWith('/auth/me')) { opts.success({statusCode:200,data:{code:0,data:{id:71}}}); return }
      if (opts.url.endsWith('/billing/cloud-state')) { opts.success({statusCode:404,data:{}}); return }
      requests.push(opts.method + ' ' + opts.url)
      const data = opts.url.includes('/requests/') ? { status: 'completed', conversationId: 'conversation', requestId: 'persisted-id', answer: 'Recovered', sources: [] }
        : { conversationId: 'conversation', messages: [{ role: 'user', content: 'Synthetic question' }, { role: 'assistant', content: 'Recovered' }] }
      opts.success({ statusCode: 200, data: { code: 0, data } })
    },
  }
  page.restoreLocal()
  assert.equal(page.data.draft, 'Synthetic question')
  await page.restoreRemote()
  assert.equal(page.conversation.pending, undefined)
  assert.equal(page.data.messages[1].content, 'Recovered')
  assert.ok(requests.every(url => url.startsWith('GET ')))
  assert.ok(requests[0].endsWith('/requests/persisted-id'))
})

test('copy uses cloud location ID, preserves source history and requires confirmation', async () => {
  const { page } = fixture()
  page.conversation.conversationId = 'source-id'
  page.conversation.messages = [{ role: 'user', content: 'Keep original' }]
  const calls: any[] = []
  let confirmed = false
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => key === 'awd.session' ? 'synthetic-account' : undefined,
    setStorageSync() {},
    showModal: async () => ({ confirm: confirmed }),
    request(opts: any) {
      if (opts.url.endsWith('/auth/me')) { opts.success({statusCode:200,data:{code:0,data:{id:71}}}); return }
      if (opts.url.endsWith('/billing/cloud-state')) { opts.success({statusCode:404,data:{}}); return }
      calls.push(opts)
      const data = opts.url.endsWith('/catalog') ? [
        { projectUid: 'formal-uid', name: 'Same name', projectType: 'BLANK', locations: [{ kind: 'desktop', deviceId: 'd', key: '999' }, { kind: 'cloud', deviceId: 'cloud', key: '71' }] },
        { projectUid: 'scratch-uid', name: 'Same name', projectType: 'SCRATCH', locations: [{ kind: 'cloud', deviceId: 'cloud', key: '72' }] },
        { projectUid: 'archive-uid', name: 'Archive', locations: [{ kind: 'cloud', deviceId: 'cloud', key: '73', archiveOnly: true }] },
      ] : { mode: 'copy', sourcePreserved: true, filesCopied: false, sourceConversationId: 'source-id', targetProjectId: 71, conversationId: 'new-id', messageCount: 1 }
      opts.success({ statusCode: 200, data: opts.url.endsWith('/catalog') ? data : { code: 0, data } })
    },
  }
  await page.onPrepareCopy()
  assert.equal(page.data.copyTargets.length, 1)
  await page.onCopy({ detail: { value: '0' } })
  assert.equal(calls.length, 1)
  confirmed = true
  await page.onCopy({ detail: { value: '0' } })
  assert.equal(calls[1].data.targetProjectId, 71)
  assert.ok(calls[1].url.endsWith('/assistant/conversations/source-id/copy-to-project'))
  assert.equal(page.conversation.conversationId, 'source-id')
  assert.equal(page.conversation.messages[0].content, 'Keep original')
  assert.ok(page.data.copySuccess)
})

test('account switch during copy confirmation never sends the prior conversation', async () => {
  const { page, changeAccount, calls } = fixture()
  page.conversation.conversationId = 'source-id'
  page.data.copyTargets = personalCopyDestinations([{ deviceId: 'cloud', deviceName: null, key: '71', name: 'Target', locations: [{ kind: 'cloud', deviceId: 'cloud', key: '71' }] }], 'Cloud')
  ;(globalThis as any).wx.showModal = async () => { changeAccount(); return { confirm: true } }
  await page.onCopy({ detail: { value: '0' } })
  assert.equal(calls.length, 0)
})


test('desktop copy requires location proof and keeps ambiguous delivery UUID across retry and reload', async () => {
  const { page } = fixture()
  page.conversation.conversationId = 'source-id'
  page.conversation.messages = [{ role: 'user', content: 'Keep original' }]
  const project = { deviceId: 'cloud', deviceName: null, key: '71', projectUid: 'cloud-uid', name: 'Matter', locations: [
    { kind: 'desktop' as const, deviceId: 'mac-a', deviceName: 'Mac A', key: 'local-17', projectUid: 'device-uid', projectType: 'LOCAL_DIR', owned: true },
    { kind: 'desktop' as const, deviceId: 'mac-old', key: 'old' },
    { kind: 'desktop' as const, deviceId: 'mac-b', key: 'shared', projectUid: 'shared', projectType: 'LOCAL_DIR', owned: false },
    { kind: 'cloud' as const, deviceId: 'cloud', key: '71' },
  ] }
  const targets = personalCopyDestinations([project], 'Cloud')
  assert.equal(targets.length, 2)
  assert.ok(desktopCopyNeedsUpgrade([project]))
  page.data.copyTargets = targets
  const calls: any[] = []; let saved: any
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => key === 'awd.session' ? 'synthetic-account' : key === 'awd.user' ? { id: 71 } : key === 'awd.personalConversation' ? saved : undefined,
    setStorageSync(key: string, value: any) { if(key==='awd.personalConversation') saved = structuredClone(value) },
    showModal: async () => ({ confirm: true }),
    request(opts: any) {
      if (opts.url.endsWith('/auth/me')) { opts.success({statusCode:200,data:{code:0,data:{id:71}}}); return }
      if (opts.url.endsWith('/billing/cloud-state')) { opts.success({statusCode:404,data:{}}); return }
      if (opts.url.endsWith('/desktop-copies')) return opts.success({ statusCode: 200, data: { code: 0, data: [] } })
      calls.push(opts)
      if (calls.length === 1) return opts.fail()
      const request = page.conversation.desktopCopy.request
      const data = { ...request, status: opts.method === 'GET' ? 'DELIVERED' : 'QUEUED', sourcePreserved: true, filesCopied: false, conversationId: 'copied', messageCount: 1, expiresAt: '2026-11-10T00:00:00Z' }
      opts.success({ statusCode: 200, data: { code: 0, data } })
    },
  }
  await page.onCopy({ detail: { value: '1' } })
  assert.equal(calls[0].data.targetProjectUid, 'device-uid')
  assert.equal(calls[0].data.targetProjectKey, 'local-17')
  assert.equal(calls[0].data.targetProjectId, undefined)
  assert.ok(saved.desktopCopy.request.requestId)
  page.conversation = new PersonalConversation(); page.restoreLocal()
  await page.onCopyRetry()
  assert.equal(calls[0].data.requestId, calls[1].data.requestId)
  assert.equal(page.conversation.desktopCopy.receipt.status, 'QUEUED')
  assert.equal(page.data.copySuccess, '')
  assert.equal(page.data.copyCanRetry, false)
  await page.onCopyRefresh()
  assert.equal(page.conversation.desktopCopy.receipt.status, 'DELIVERED')
  assert.equal(page.conversation.conversationId, 'source-id')
  page.onNewChat(); assert.equal(page.conversation.desktopCopy, undefined)
})

test('desktop copy does not create a new request when recent receipt recovery fails', async () => {
  const { page } = fixture()
  page.conversation.conversationId = 'source'
  page.data.copyTargets = personalCopyDestinations([{ deviceId: 'mac', key: 'local', name: 'Matter', locations: [{ kind: 'desktop', deviceId: 'mac', key: 'local', projectUid: 'uid', projectType: 'LOCAL_DIR', owned: true }] }])
  let posts = 0
  ;(globalThis as any).wx.showModal = async () => ({ confirm: true })
  ;(globalThis as any).wx.request = (opts: any) => { if (opts.method === 'POST') posts++; opts.fail() }
  await page.onCopy({ detail: { value: '0' } })
  assert.equal(posts, 0)
  assert.equal(page.conversation.desktopCopy, undefined)
  assert.ok(page.data.error)
})

test('postpaid restriction preserves local draft and does not send a paid request', async () => {
  const {page, calls} = fixture()
  page.data.status.cloudAccess = {canUse: false, canRead: true, canWrite: false, cleanupState: 'none'}
  await page.onSend()
  assert.equal(calls.length, 0)
  assert.equal(page.data.draft, 'Synthetic question')
})
