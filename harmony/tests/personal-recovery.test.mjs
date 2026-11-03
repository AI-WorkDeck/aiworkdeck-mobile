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
  const calls = []; const replies = []; const recentCalls = []; const recentReplies = []; let uuidCounter = 99
  const locator = { ctx: {}, baseUrl: () => host, session: { current: async () => account }, backend: {
    personalDesktopCopies: async (conversation, session) => { recentCalls.push({ conversation, session }); const response = recentReplies.shift() ?? []; return typeof response === 'function' ? response() : response },
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
    '@kit.ArkTS': { JSON, util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value) } }, generateRandomUUID: () => '00000000-0000-4000-8000-' + String(uuidCounter++).padStart(12, '0') } },
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
  return { page, Store, calls, replies, recentCalls, recentReplies, prefs, pending, reply, history, model, raw: () => latest, change: () => { host = 'https://other.invalid'; account = 'other-account' } }
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


const desktopFixture = JSON.parse(readFileSync(new URL('../../contract/fixtures/desktop-copy.json', import.meta.url), 'utf8'))
async function copyFixture() {
  const f = fixture(); f.page.conversationStore = await f.Store.open(); f.page.conversationId = desktopFixture.receipts[0].sourceConversationId
  const request = f.model.DesktopCopyRequest.from(desktopFixture.receipts[0])
  return { ...f, request, receipt: (status = 'QUEUED', id = request.requestId) => ({ ...desktopFixture.receipts[0], requestId: id, status }) }
}

test('copy targets require location ownership and stable UID/type proof, preserve cloud and distinguish devices', () => {
  const f = fixture(); const location = { kind: 'desktop', deviceId: 'a', deviceName: 'A', key: '17', projectUid: 'location-uid', projectType: 'BLANK', owned: true }
  const projects = [{ name: 'Same name', projectUid: 'top-uid', locations: [location, { ...location, deviceId: 'b', deviceName: 'B' }, { kind: 'cloud', deviceId: 'cloud', key: '42' }] }]
  const targets = f.model.personalCopyTargets(projects)
  assert.equal(targets.length, 3); assert.equal(targets[0].desktop.projectUid, 'location-uid'); assert.equal(targets[2].cloudId, 42)
  for (const change of [{ owned: undefined }, { owned: false }, { projectUid: undefined }, { projectType: undefined }, { projectType: 'SCRATCH' }, { projectType: 'LOOSE_FILES' }, { archiveOnly: true }]) {
    assert.equal(f.model.personalCopyTargets([{ ...projects[0], locations: [{ ...location, ...change }] }]).length, 0)
  }
  assert.equal(f.model.copyNeedsUpgrade([{ locations: [{ ...location, owned: undefined }] }]), true)
})

test('desktop POST is preceded by durable request; ambiguous failure retries same UUID; queued is not delivered', async () => {
  const f = await copyFixture()
  f.replies.push(() => { assert.ok(f.raw().includes(f.request.requestId)); throw new Error('offline') })
  await f.page.submitDesktopCopy(f.request, 0)
  assert.equal((await (await f.Store.open()).load()).desktopCopy.request.requestId, f.request.requestId)
  assert.equal(f.page.desktopCopy.statusKey(), 'personal.copy.unknown'); assert.equal(f.page.copySuccess, '')
  f.replies.push(f.receipt()); await f.page.retryDesktopCopy()
  assert.equal(f.calls[0].body.requestId, f.calls[1].body.requestId)
  assert.equal(f.page.desktopCopy.statusKey(), 'personal.copy.queued'); assert.equal(f.page.copySuccess, '')
  f.replies.push(f.receipt('DELIVERED')); await f.page.refreshDesktopCopy()
  assert.equal(f.calls.at(-1).method, 'GET'); assert.equal(f.page.desktopCopy.statusKey(), 'personal.copy.delivered')
  assert.equal((await (await f.Store.open()).load()).desktopCopy.receipt.status, 'DELIVERED')
})

test('restoring pending copy only polls GET and server recent restores lost local receipts', async () => {
  const f = await copyFixture(); const saved = new f.model.PersonalConversation(); saved.conversationId = f.request.sourceConversationId; saved.desktopCopy = new f.model.PersonalDesktopCopy(f.request)
  await (await f.Store.open()).save(saved)
  f.replies.push({ conversationId: f.request.sourceConversationId, messages: [] }, f.receipt())
  await f.page.restoreConversation(0)
  assert.ok(f.calls.every(call => call.method === 'GET')); assert.equal(f.page.desktopCopy.receipt.status, 'QUEUED')
  const fresh = await copyFixture(); fresh.recentReplies.push([fresh.receipt('DELIVERED')])
  await fresh.page.restoreDesktopCopy(0)
  assert.equal(fresh.recentCalls.length, 1); assert.equal(fresh.page.desktopCopy.receipt.status, 'DELIVERED')
  assert.equal((await (await fresh.Store.open()).load()).desktopCopy.request.requestId, fresh.request.requestId)
})

test('mismatched receipts never mark delivered, stale account responses do not overwrite storage', async () => {
  const f = await copyFixture(); f.replies.push({ ...f.receipt('DELIVERED'), targetDeviceId: 'other' })
  await f.page.submitDesktopCopy(f.request, 0); assert.equal(f.page.desktopCopy.receipt, null)
  assert.equal((await (await f.Store.open()).load()).desktopCopy.receipt, null)
  const saved = f.raw(); f.replies.push(() => { f.change(); return f.receipt('DELIVERED') })
  await f.page.refreshDesktopCopy(); assert.equal(f.raw(), saved); assert.equal(f.page.desktopCopy.receipt, null)
})

test('failed or expired explicit retry gets a new UUID and revoked input cannot be restored', async () => {
  const f = await copyFixture(); f.page.desktopCopy = new f.model.PersonalDesktopCopy(f.request)
  f.page.desktopCopy.receipt = f.model.DesktopCopyReceipt.from(f.receipt('EXPIRED'), f.request)
  f.replies.push(() => f.receipt('QUEUED', f.calls.at(-1).body.requestId)); await f.page.retryDesktopCopy()
  assert.notEqual(f.calls[0].body.requestId, f.request.requestId)
  await f.Store.clear(); f.page.resetConversation(); assert.equal(f.page.desktopCopy, null)
  assert.equal((await (await f.Store.open()).load()).desktopCopy, null)
})

test('failed durable save never sends a desktop request', async () => {
  const f = await copyFixture(); f.prefs.flush = async () => { throw new Error('disk unavailable') }
  await f.page.submitDesktopCopy(f.request, 0)
  assert.equal(f.calls.length, 0); assert.equal(f.page.desktopCopy.receipt, null)
})

test('choosing a desktop sends its location proof, not the aggregate project identity', async () => {
  const f = await copyFixture()
  const location = { kind: 'desktop', deviceId: f.request.targetDeviceId, key: f.request.targetProjectKey, projectUid: f.request.targetProjectUid, owned: true, projectType: 'BLANK' }
  const target = f.model.personalCopyTargets([{ name: 'Formal', projectUid: 'different-aggregate-uid', locations: [location] }])[0]
  f.replies.push(() => f.receipt('QUEUED', f.calls.at(-1).body.requestId))
  await f.page.copyTo(target, f.request.sourceConversationId, 0)
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].body.targetProjectUid, location.projectUid)
  assert.equal(f.calls[0].body.targetDeviceId, location.deviceId); assert.equal(f.calls[0].body.targetProjectKey, location.key)
  assert.equal(f.page.desktopCopy.receipt.status, 'QUEUED')
})

test('receipt validation rejects identity, preservation and malformed state before persistence', async () => {
  const f = await copyFixture()
  for (const change of [{ requestId: 'another' }, { sourceConversationId: 'another' }, { targetProjectUid: 'another' }, { targetProjectKey: 'another' }, { sourcePreserved: false }, { filesCopied: true }, { status: 'SUCCESS' }, { messageCount: -1 }, { expiresAt: 'invalid' }]) {
    assert.equal(f.model.DesktopCopyReceipt.from({ ...f.receipt('DELIVERED'), ...change }, f.request), null)
  }
})

test('unavailable recent receipts block new desktop request and concurrent selection', async () => {
  const f = await copyFixture()
  const location = { kind: 'desktop', deviceId: f.request.targetDeviceId, key: f.request.targetProjectKey, projectUid: f.request.targetProjectUid, owned: true, projectType: 'BLANK' }
  const target = f.model.personalCopyTargets([{ name: 'Formal', locations: [location] }])[0]
  let release
  f.recentReplies.push(() => new Promise((_resolve, reject) => { release = reject }))
  const first = f.page.copyTo(target, f.request.sourceConversationId, 0)
  while (!release) await Promise.resolve()
  await f.page.copyTo(target, f.request.sourceConversationId, 0)
  assert.equal(f.recentCalls.length, 1)
  release(new Error('offline')); await first
  assert.equal(f.calls.length, 0); assert.equal(f.page.desktopCopy, null)
  assert.equal(f.page.error, 'personal.copy.unknown')
})

test('same desktop target recovers queued UUID from recent receipts', async () => {
  const f = await copyFixture()
  const location = { kind: 'desktop', deviceId: f.request.targetDeviceId, key: f.request.targetProjectKey, projectUid: f.request.targetProjectUid, owned: true, projectType: 'BLANK' }
  const target = f.model.personalCopyTargets([{ name: 'Formal', locations: [location] }])[0]
  f.recentReplies.push([f.receipt('QUEUED')]); f.replies.push(f.receipt('QUEUED'))
  await f.page.copyTo(target, f.request.sourceConversationId, 0)
  assert.equal(f.calls[0].body.requestId, f.request.requestId)
})
