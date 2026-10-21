import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'
// @ts-ignore ArkTS runtime state, independent of native SDK.
import { RecordingState } from '../../harmony/entry/src/main/ets/services/RecordingState.ets'
// @ts-ignore ArkTS domain model.
import * as capture from '../../harmony/entry/src/main/ets/model/Capture.ets'
// @ts-ignore ArkTS decoders.
import * as api from '../../harmony/entry/src/main/ets/services/ApiTypes.ets'

function recorderFixture(metadata: Record<string, string> = { duration: '1000', hasAudio: 'yes' }) {
  const files = new Map<string, string>([['/private/RecordingDrafts/a.m4a', 'audio'],
    ['/private/RecordingDrafts/a.m4a.json', JSON.stringify({ capturedAt: 1234 })]])
  const stored: any[] = []
  let savingFails = false
  let uploads = 0
  const locator = { ctx: { filesDir: '/private' }, store: {
    save: async (...args: any[]) => { if (savingFails) throw new Error('full disk'); stored.push(args); files.delete(args[1]); return { id: 'stored' } },
  }, queue: { kick: async () => { uploads++ } } }
  const fs = { OpenMode: { READ_ONLY: 0 }, accessSync: (p: string) => files.has(p) || p === '/private/RecordingDrafts',
    statSync: (p: string) => ({ size: files.get(p)?.length ?? 0 }), openSync: () => ({ fd: 1 }), closeSync: () => {},
    unlinkSync: (p: string) => files.delete(p), listFileSync: () => [...files.keys()].map(p => p.split('/').pop()),
    readTextSync: (p: string) => files.get(p) }
  const modules: Record<string, any> = {
    '@kit.AbilityKit': {}, '@kit.BackgroundTasksKit': {}, '@kit.BasicServicesKit': {},
    '@kit.CoreFileKit': { fileIo: fs }, '@kit.ArkTS': { JSON }, '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    '@kit.MediaKit': { media: { CodecMimeType: { AUDIO_AAC: 'aac' }, ContainerFormatType: { CFT_MPEG_4A: 'm4a' },
      createAVMetadataExtractor: async () => ({ fetchMetadata: async () => metadata, release: async () => {} }) } },
    '../model/Capture': capture, '../model/Loc': {}, '../design/L10n': { tr: (key: string) => key },
    './RecordingState': { RecordingState }, '../ScreenshotMode': { ScreenshotMode: { enabled: false } },
    './ServiceLocator': { ServiceLocator: locator }, './ApiTypes': api,
  }
  const source = readFileSync(new URL('../../harmony/entry/src/main/ets/services/RecorderService.ets', import.meta.url), 'utf8')
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const exports: any = {}
  new Function('require', 'exports', output)((id: string) => { assert.ok(modules[id], id); return modules[id] }, exports)
  const service = new exports.RecorderService()
  service.path = '/private/RecordingDrafts/a.m4a'
  return { service, files, stored, savingFails: () => { savingFails = true }, uploads: () => uploads }
}
const drain = () => new Promise(resolve => setTimeout(resolve, 5))

test('real recorder pause finalizes existing audio, stops recording, reports the missing tail', async () => {
  const f = recorderFixture()
  f.service.state.begin(1234)
  f.service.onStateChange('paused', 0)
  await drain()
  assert.equal(f.service.state.isRecording, false)
  assert.equal(f.service.state.message, 'rec.interruption.saved')
  assert.equal(f.stored.length, 1)
  assert.equal(f.uploads(), 1)
  assert.equal(f.files.size, 0)
})

test('zero-duration and missing audio tracks retain drafts without uploading a false success', async () => {
  for (const metadata of [{ duration: '0', hasAudio: 'yes' }, { duration: '1000', hasAudio: 'no' }]) {
    const f = recorderFixture(metadata)
    f.service.state.begin(1234)
    await f.service.stop(true)
    assert.equal(f.stored.length, 0)
    assert.equal(f.uploads(), 0)
    assert.equal(f.service.state.message, 'rec.recovery.noAudio')
    assert.equal(f.files.size, 2)
  }
})

test('failed save keeps the playable draft; retry recovers locally unassigned', async () => {
  const f = recorderFixture()
  f.service.state.begin(1234)
  f.savingFails()
  await f.service.stop(true)
  assert.equal(f.files.size, 2)
  assert.equal(f.service.state.message, 'rec.saveFailed')
  const recovered = recorderFixture()
  await recovered.service.recoverDrafts()
  assert.equal(recovered.stored.length, 1)
  assert.equal(recovered.stored[0][4], null)
  assert.equal(recovered.uploads(), 0)
  assert.equal(recovered.service.state.message, 'rec.recovery.saved')
})

test('late callbacks from a released recorder cannot stop the next recording', async () => {
  const f = recorderFixture()
  const callbacks: Record<string, Function> = {}
  const old = { on: (event: string, cb: Function) => { callbacks[event] = cb } }
  f.service.listen(old)
  f.service.recorder = { stop: async () => {}, release: async () => {} }
  f.service.state.begin(1234)
  callbacks.stateChange('paused', 0)
  callbacks.error({ code: 1, message: 'late' })
  await drain()
  assert.equal(f.service.state.isRecording, true)
  assert.equal(f.stored.length, 0)
  await f.service.stop()
})
