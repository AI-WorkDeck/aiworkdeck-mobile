import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'
import { RecordingClock } from '../../harmony/entry/src/main/ets/model/RecordingClock.ets'

function fixture() {
  const modules: Record<string, any> = {
    '@kit.ArkUI': {}, '@kit.CameraKit': {}, '@kit.ImageKit': {}, '@kit.MediaKit': {}, '@kit.BasicServicesKit': {},
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    './Permissions': {}, './ServiceLocator': {}, '../model/RecordingClock': { RecordingClock },
  }
  const source = readFileSync(new URL('../../harmony/entry/src/main/ets/services/CameraService.ets', import.meta.url), 'utf8')
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const exports: any = {}
  new Function('require', 'exports', output)((id: string) => { assert.ok(modules[id], id); return modules[id] }, exports)
  const service = new exports.CameraService()
  const calls: string[] = []
  const recorder = { pause: async () => { calls.push('pause') }, resume: async () => { calls.push('resume') },
    stop: async () => { calls.push('stop') }, release: async () => { calls.push('release') } }
  service.recorder = recorder
  service.videoPath = '/private/clip.mp4'
  service.isRecordingVideo = true
  service.videoStartedAt = 1000
  service.videoClock.start(1000)
  return { service, calls, recorder }
}

test('video pause/resume call the same native recorder and exclude paused wall time, including stop while paused', async () => {
  const f = fixture(); const now = Date.now
  try {
    Date.now = () => 11000
    await f.service.pauseVideo()
    assert.equal(f.service.isRecordingVideo, true)
    assert.equal(f.service.isVideoPaused, true)
    assert.equal(f.service.videoClock.elapsed(90000), 10)
    Date.now = () => 91000
    await f.service.resumeVideo()
    assert.equal(f.service.videoClock.elapsed(96000), 15)
    Date.now = () => 96000
    await f.service.pauseVideo()
    assert.equal(await f.service.stopVideo(), '/private/clip.mp4')
    assert.deepEqual(f.calls, ['pause', 'resume', 'pause', 'stop', 'release'])
    assert.equal(f.service.isRecordingVideo, false)
    assert.equal(f.service.isVideoPaused, false)
  } finally { Date.now = now }
})

test('video resume failure retains paused state and original file for explicit stop/save', async () => {
  const f = fixture()
  await f.service.pauseVideo()
  f.recorder.resume = async () => { throw new Error('focus unavailable') }
  await assert.rejects(f.service.resumeVideo(), /focus unavailable/)
  assert.equal(f.service.isVideoPaused, true)
  assert.equal(await f.service.stopVideo(), '/private/clip.mp4')
})
