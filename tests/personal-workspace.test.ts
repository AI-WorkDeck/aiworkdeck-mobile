// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { PersonalConversation, upcoming, type CalendarEvent } from '../miniprogram/utils/personal.ts'
// @ts-ignore pure ArkTS module.
import { personalEvents, upcomingEvents } from '../harmony/entry/src/main/ets/model/PersonalWorkspace.ets'
import { loadContract, outputs } from '../contract/tools/lib.mjs'

const event: CalendarEvent = { id: 'event', deviceId: 'desktop', projectKey: 'alpha', projectName: 'Synthetic', title: 'Synthetic event', dueDate: '2026-10-28', timeZone: 'Asia/Shanghai', status: 'OPEN', files: [{ fileId: 7, fileName: 'synthetic.pdf' }] }
test('calendar filters use project identity and event timezone across midnight on mini and Harmony', () => {
  const now = new Date('2026-10-27T20:00:00Z')
  const entries = [event, { ...event, id: 'done', status: 'DONE' as const }, { ...event, id: 'later', dueDate: '2026-10-31' }, { ...event, id: 'other', deviceId: 'another' }]
  assert.deepEqual(upcoming(entries, 3, 'desktop:alpha', now).map(e => e.id), ['event'])
  assert.deepEqual(upcomingEvents(personalEvents(entries), 3, 'desktop:alpha', now).map((e: any) => e.id), ['event'])
  assert.deepEqual(personalEvents(entries)[0].files, ['synthetic.pdf'])
})
test('running, failed and foreign replies never consume a pending UUID or insert a blank answer', () => {
  const conversation = new PersonalConversation()
  const question = conversation.question('My question', () => 'request-one')
  assert.equal(conversation.question('My question', () => 'should-not-be-used'), question)
  for (const status of ['running', 'failed'] as const) assert.equal(conversation.accept({ status, requestId: question.requestId, conversationId: 'conversation', answer: '', sources: [] }), false)
  assert.equal(conversation.accept({ status: 'completed', requestId: 'foreign', conversationId: 'conversation', answer: 'Wrong', sources: [] }), false)
  assert.equal(conversation.messages.length, 0)
  assert.equal(conversation.accept({ status: 'completed', requestId: question.requestId, conversationId: 'conversation', answer: 'Answer', sources: [] }), true)
  assert.equal(conversation.messages.length, 2)
  assert.equal(conversation.pending, undefined)
})
test('APNs localization is generated from the same 20-language contract without case details', () => {
  const root = fileURLToPath(new URL('..', import.meta.url))
  const contract = loadContract(root)
  const files = outputs(contract)
  assert.equal(contract.locales.length, 20)
  for (const locale of contract.locales) {
    const file = `ios/Resources/${locale.code}.lproj/Localizable.strings`
    assert.equal(readFileSync(new URL('../' + file, import.meta.url), 'utf8'), files.get(file))
    assert.ok(files.get(file)?.includes(`"personal.reminders" = ${JSON.stringify(contract.strings['personal.reminders'][locale.code])};`))
  }
})

test('saved personal conversation is isolated by account and host without storing credentials', async () => {
  const { savePersonalConversation, readPersonalConversation } = await import('../miniprogram/utils/personal-storage.ts')
  const data = new Map<string, unknown>([['awd.session', 'secret-session'], ['awd.user', { id: 71 }]])
  ;(globalThis as any).wx = { getStorageSync: (key: string) => data.get(key), setStorageSync: (key: string, value: unknown) => data.set(key, value) }
  savePersonalConversation({ conversationId: 'conversation', pending: { requestId: 'original-id', message: 'Question' } })
  assert.equal(readPersonalConversation()?.pending?.requestId, 'original-id')
  assert.equal(JSON.stringify(data.get('awd.personalConversation')).includes('secret-session'), false)
  data.set('awd.user', { id: 72 })
  assert.equal(readPersonalConversation(), undefined)
})
