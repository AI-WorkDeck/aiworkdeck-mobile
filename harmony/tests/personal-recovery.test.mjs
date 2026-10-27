// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import ts from 'typescript'

// Execute the production page's behavior methods; ArkUI rendering and OS services are substitutes.
// Native syntax, layouts, and platform imports are checked separately by assembleHap.
function fixture() {
  let account = 'synthetic-account'; let host = 'https://synthetic.invalid'; let latest = ''
  const calls = []; const replies = []
  const locator = { ctx: {}, baseUrl: () => host, session: { current: async () => account }, backend: {
    personalRequest: async (path, method, body) => {
      calls.push({ path, method, body }); const response = replies.shift()
      if (response instanceof Error) throw response
      return typeof response === 'function' ? response() : response
    },
  } }
  const prefs = { getSync: (_key, fallback) => latest || fallback, putSync: (_key, value) => { latest = value }, deleteSync: () => { latest = '' }, flush: async () => {} }
  const mocks = {
    '@kit.ArkData': { preferences: { getPreferencesSync: () => prefs } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => { const hash = createHash('sha256'); return { updateSync: ({ data }) => hash.update(data), digestSync: () => ({ data: hash.digest() }) } } } },
    '@kit.ArkTS': { JSON, util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value) } }, generateRandomUUID: () => '00000000-0000-4000-8000-000000000099' } },
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT' } } },
    contract: { ContractCapabilities: { personalConsentVersion: 'synthetic' } },
    '../services/ServiceLocator': { ServiceLocator: locator }, './ServiceLocator': { ServiceLocator: locator },
    '../services/CalendarReminders': { CalendarReminders: { restore: async () => false, clear: async () => {} } },
    './ProjectFilesRequest': { ProjectFilesRequest: {} }, '../design/Tokens': { Tk: {} },
    '../design/L10n': { LOCALE_ZH: 'en', trIn: (_locale, key) => key, L10n: {} }, './Feedback': { errorText: e => String(e.message) },
  }
  function compile(path, page = false) {
    let source = readFileSync(new URL(path, import.meta.url), 'utf8')
    if (page) source = source.slice(0, source.indexOf('  build() {')) + '\n}'
    source = source.replace('@Component\n', '').replace('export struct Personal', 'export class Personal').replace(/@(State|StorageProp|StorageLink|Watch)(\([^)]*\))?\s*/g, '')
    const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
    const module = { exports: {} }
    new Function('require', 'module', 'exports', 'NavPathStack', 'setTimeout', output)(name => {
      assert.ok(name in mocks, `Unexpected module ${name}`); return mocks[name]
    }, module, module.exports, class {}, fn => { queueMicrotask(fn) })
    return module.exports
  }
  const model = compile('../entry/src/main/ets/model/PersonalWorkspace.ets')
  mocks['../model/PersonalWorkspace'] = model
  const { PersonalConversationStore: Store } = compile('../entry/src/main/ets/services/PersonalConversationStore.ets')
  mocks['../services/PersonalConversationStore'] = { PersonalConversationStore: Store }
  const { Personal } = compile('../entry/src/main/ets/pages/Personal.ets', true)
  const page = new Personal(); page.alive = true; page.session = account; page.host = host
  const pending = { conversationId: '', pendingId: '00000000-0000-4000-8000-000000000001', pendingText: 'Synthetic question', pendingConversationId: '' }
  const reply = (status = 'completed') => ({ status, requestId: pending.pendingId, conversationId: '00000000-0000-4000-8000-000000000002', answer: 'Answer', sources: [] })
  const history = { conversationId: reply().conversationId, messages: [{ role: 'user', content: pending.pendingText }, { role: 'assistant', content: 'Answer', sources: [{ deviceId: 'desktop', projectKey: 'alpha', projectName: 'Synthetic' }] }] }
  return { page, Store, calls, replies, pending, reply, history, model, raw: () => latest, change: () => { host = 'https://other.invalid'; account = 'other-account' } }
}

test('reopening polls only GET before history and clears completed pending', async () => {
  const f = fixture(); const store = await f.Store.open(); await store.save(f.pending)
  f.replies.push(f.reply('running'), f.reply(), f.history)
  await f.page.restoreConversation(0)
  assert.deepEqual(f.calls.map(c => [c.method, c.path]), [['GET', 'assistant/requests/' + f.pending.pendingId], ['GET', 'assistant/requests/' + f.pending.pendingId], ['GET', 'assistant/conversations/' + f.history.conversationId]])
  assert.equal(f.page.messages.length, 2); assert.equal(f.page.sources[0].projectKey, 'alpha')
  assert.equal(f.page.draft, ''); assert.equal(f.page.pendingId, '')
  assert.equal((await (await f.Store.open()).load()).conversationId, f.history.conversationId)
  assert.equal((await (await f.Store.open()).load()).pendingId, '')
  assert.ok(!f.raw().includes('synthetic-account')); assert.ok(!f.raw().includes('https://'))
})

test('failed recovery preserves original UUID and original conversation for explicit retry', async () => {
  const f = fixture(); await (await f.Store.open()).save(f.pending)
  f.replies.push(f.reply('failed'), { ...f.history, messages: [f.history.messages[0]] })
  await f.page.restoreConversation(0)
  assert.equal(f.calls.length, 2); assert.ok(f.calls.every(c => c.method === 'GET'))
  assert.equal(f.page.pendingId, f.pending.pendingId)
  f.page.assistantEnabled = true; f.page.assistantSubscribed = true
  f.replies.push(f.reply()); await f.page.send()
  assert.deepEqual(f.calls[2], { path: 'assistant/chat', method: 'POST', body: { message: f.pending.pendingText, requestId: f.pending.pendingId } })
  assert.equal(f.page.messages.length, 2)
})

test('late completion after navigation hide cannot mutate state or storage', async () => {
  const f = fixture(); await (await f.Store.open()).save(f.pending)
  f.replies.push(() => { f.page.alive = false; f.page.version++; return f.reply() })
  await f.page.restoreConversation(0)
  assert.equal(f.calls.length, 1); assert.equal(f.page.messages.length, 0)
  assert.equal((await (await f.Store.open()).load()).pendingId, f.pending.pendingId)
})

test('logout/revocation and account/region changes reject stale writers', async () => {
  const f = fixture(); const old = await f.Store.open(); await old.save(f.pending)
  await f.Store.clear(); assert.equal(await old.save(f.pending), false); assert.equal(f.raw(), '')
  const next = await f.Store.open(); await next.save(f.pending); f.change()
  assert.equal(await next.save(f.pending), false)
  assert.equal((await (await f.Store.open()).load()).pendingId, ''); assert.equal(f.raw(), '')
})

test('temporarily unavailable subscription retains pending until explicit consent revocation', async () => {
  const f = fixture(); await (await f.Store.open()).save(f.pending)
  f.replies.push({ enabled: false, consentEnabled: true, subscriptionActive: false, subscriptionAvailable: false }, { enabled: false })
  await f.page.load()
  assert.equal((await (await f.Store.open()).load()).pendingId, f.pending.pendingId)
  assert.deepEqual(f.calls.map(c => c.path), ['assistant/status', 'calendar/events'])
  f.replies.push({ enabled: false, consentEnabled: false, subscriptionActive: true }, { enabled: false })
  await f.page.load()
  assert.equal(f.raw(), ''); assert.equal(f.page.messages.length, 0)
})

test('clearing while a scoped save awaits cannot restore deleted input', async () => {
  const f = fixture(); const store = await f.Store.open()
  const saving = store.save(f.pending)
  await f.Store.clear(); await saving
  assert.equal(f.raw(), '')
})
