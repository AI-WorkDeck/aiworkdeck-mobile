import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'

function fixture() {
  let session = 'synthetic'; let region = 'cn'; let reply = { code: 0, data: { id: 42 } }; let status = 200
  const requests = []; let destroyed = 0
  class ApiError extends Error {} class Unauthorized extends Error {}
  const mocks = {
    contract: { ContractCapabilities: {} }, '../model/ProjectFiles': {},
    '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'STRING' }, createHttp: () => ({ request: async (url, options) => { requests.push({url, options}); return { responseCode: status, result: JSON.stringify(reply) } }, destroy: () => destroyed++ }) } },
    '@kit.ArkTS': { JSON, util: { generateRandomUUID: () => 'synthetic-boundary' } },
    '../model/Envelope': { ApiError, Unauthorized, checkEnvelope: value => { if (value.code !== 0) throw new ApiError('failure') } },
    '../model/Capture': {}, './SessionStore': {},
    '../model/AccountRegion': { baseUrlOf: r => 'https://' + r + '.invalid', currentAppLanguage: () => 'en' },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {} } },
    './ApiTypes': { asRecord: v => v && typeof v === 'object' && !Array.isArray(v) ? v : null },
  }
  const source = readFileSync(new URL('../entry/src/main/ets/services/Backend.ets', import.meta.url), 'utf8')
  const out = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const module = { exports: {} }; new Function('require','module','exports',out)(n => { assert.ok(n in mocks, n); return mocks[n] },module,module.exports)
  const backend = new module.exports.Backend(() => region, { current: async () => session, clear: async () => { session = '' } })
  return { backend, requests, set: (body, code = 200) => { reply = body; status = code }, destroyed: () => destroyed }
}
const id = '00000000-0000-4000-8000-000000000002'
test('feedback uses Android multipart payload shape and only declared conversation context', async () => {
  const f = fixture(); assert.equal(await f.backend.reportAssistant(id, ' Synthetic reason ', 'synthetic'), 42)
  const r = f.requests[0]; assert.equal(r.url, 'https://cn.invalid/api/feedback')
  assert.match(r.options.header['Content-Type'], /^multipart\/form-data; boundary=/)
  const payload = JSON.parse(r.options.extraData.split('\r\n\r\n')[1].split('\r\n--')[0])
  assert.deepEqual(payload, { kind: 'BUG', text: 'Synthetic reason', page: 'mobile/personal/assistant', clientContext: { type: 'ai-content-report', platform: 'harmony', conversationId: id } })
  assert.equal(f.destroyed(), 1)
})
test('HTTP, business, missing envelope and invalid receipt cannot count as report success', async () => {
  for (const [body,status] of [[{code:0,data:{id:42}},500],[{code:1,data:{id:42}},200],[{data:{id:42}},200],[{code:0,data:{}},200],[{code:0,data:{id:0}},200]]) {
    const f = fixture(); f.set(body,status); await assert.rejects(f.backend.reportAssistant(id,'Synthetic','synthetic')); assert.equal(f.destroyed(),1)
  }
})
test('invalid conversation and stale session never send feedback', async () => {
  const f = fixture(); await assert.rejects(f.backend.reportAssistant('bad','Synthetic','synthetic'))
  await assert.rejects(f.backend.reportAssistant(id,'Synthetic','old')); assert.equal(f.requests.length,0)
})
