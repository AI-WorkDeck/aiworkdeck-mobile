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
    './RecordingState': { RecordingState }, './PcmRecorder': {},
    './RecordingReminder': { RecordingReminder: { cancel() {}, show: async () => true, prepare: async () => true } }, '../ScreenshotMode': { ScreenshotMode: { enabled: false } },
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

test('real microphone interruption finalizes existing audio, stops recording, reports the missing tail', async () => {
  const f = recorderFixture()
  f.service.state.begin(1234)
  f.service.finishInterrupted()
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
  const old: any = {}
  f.service.listen(old)
  f.service.recorder = { stop: async () => {}, release: async () => {} }
  f.service.state.begin(1234)
  old.onInterrupted()
  old.onVoice(300000)
  await drain()
  assert.equal(f.service.state.isRecording, true)
  assert.equal(f.stored.length, 0)
  await f.service.stop()
})


test('manual audio pause freezes time and retains the same file until explicit resume or stop', async () => {
  const f = recorderFixture()
  const calls: string[] = []
  f.service.recorder = { pause: async () => { calls.push('pause') }, resume: async () => { calls.push('resume') },
    stop: async () => { calls.push('stop') }, release: async () => {} }
  f.service.state.begin(Date.now() - 1000)
  await f.service.pause()
  assert.equal(f.service.state.userPaused, true)
  assert.equal(f.service.state.isRecording, true)
  const frozen = f.service.state.clock.elapsed(Date.now())
  assert.equal(f.service.state.clock.elapsed(Date.now() + 600000), frozen)
  assert.equal(f.stored.length, 0)
  await f.service.resume()
  assert.equal(f.service.state.userPaused, false)
  assert.deepEqual(calls, ['pause', 'resume'])
  await f.service.stop()
  assert.equal(f.stored.length, 1)
})

test('failed resume remains visibly paused and can still save', async () => {
  const f = recorderFixture()
  f.service.recorder = { resume: async () => { throw new Error('mic unavailable') }, stop: async () => {}, release: async () => {} }
  f.service.state.begin(Date.now())
  f.service.state.markUserPaused(Date.now())
  await f.service.resume()
  assert.equal(f.service.state.userPaused, true)
  assert.equal(f.service.state.message, 'rec.resume.failed')
  await f.service.stop()
  assert.equal(f.stored.length, 1)
})

test('voice threshold is advisory; speech, missing analysis and pause clear pending reminders', () => {
  const state = new RecordingState()
  state.begin(Date.now())
  state.updateVoice(299990)
  assert.equal(state.silencePending, false)
  state.updateVoice(300000)
  assert.equal(state.silencePending, true)
  assert.equal(state.isRecording, true)
  state.updateVoice(0)
  assert.equal(state.silencePending, false)
  state.updateVoice(300000)
  state.updateVoice(-1)
  assert.equal(state.voiceUnavailable, true)
  assert.equal(state.silencePending, false)
  state.markUserPaused(Date.now())
  state.updateVoice(300000)
  assert.equal(state.silencePending, false)
  state.markUserResumed(Date.now())
  state.updateVoice(10)
  assert.equal(state.voiceUnavailable, false)
  state.finish()
})


test('AAC finalization failure preserves playable prefix and reports the interrupted tail', async () => {
  const f = recorderFixture()
  f.service.recorder = { stop: async () => { throw new Error('EOS timeout') }, release: async () => {} }
  f.service.state.begin(Date.now())
  await f.service.stop()
  assert.equal(f.stored.length, 1)
  assert.equal(f.service.state.message, 'rec.interruption.saved')
})


test('stop while hardware pause is pending is saved after pause resolves instead of being dropped', async () => {
  const f = recorderFixture()
  let paused: () => void = () => {}
  f.service.recorder = { pause: () => new Promise<void>(resolve => { paused = resolve }),
    stop: async () => {}, release: async () => {} }
  f.service.state.begin(Date.now())
  const operation = f.service.pause()
  await f.service.stop()
  assert.equal(f.stored.length, 0)
  paused()
  await operation
  assert.equal(f.service.state.isRecording, false)
  assert.equal(f.stored.length, 1)
})
