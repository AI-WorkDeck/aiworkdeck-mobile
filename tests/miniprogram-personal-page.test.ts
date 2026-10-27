// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { PersonalConversation } from '../miniprogram/utils/personal.ts'
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
    request(opts: any) {
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
  assert.equal(calls[1].data.requestId, id)
  assert.equal(calls[1].data.projectKey, undefined)
  complete(); await pending
  assert.equal(page.data.draft, '')
  assert.equal(page.data.messages.length, 2)
  assert.equal(calls[1].timeout, 240000)
})
test('late response after account switch cannot publish the former answer', async () => {
  const { page, succeed, changeAccount, complete } = fixture(); succeed()
  const pending = page.onSend(); changeAccount(); complete(); await pending
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
