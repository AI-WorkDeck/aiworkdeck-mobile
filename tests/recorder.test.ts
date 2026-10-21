import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { gunzipSync } from 'node:zlib'
import { startRecording, stopRecording, recordingSnapshot, bindRecordingCallbacks, takeRecordingNotice,
  SEGMENT_DURATION_MS, pauseRecording, resumeRecording, answerSilenceReminder } from '../miniprogram/utils/recorder.ts'
import { t } from '../miniprogram/utils/i18n.ts'

const handlers: Record<string, (result?: any) => void> = {}
const calls = { start: 0, stop: 0, resume: 0 }
const on = (name: string) => (cb: (result?: any) => void) => { handlers[name] = cb }
const manager = {
  pause() {}, start() { calls.start++ }, stop() { calls.stop++ }, resume() { calls.resume++ },
  onPause: on('pause'), onResume: on('resume'), onFrameRecorded: on('frame'),
  onStart: on('start'), onStop: on('stop'), onError: on('error'),
  onInterruptionBegin: on('interruptionBegin'), onInterruptionEnd: on('interruptionEnd'),
}
let storage: Record<string, any> = {}
let saves: any[] = []
;(globalThis as any).wx = {
  getRecorderManager: () => manager,
  uploadFile: (o: any) => { o.success({ statusCode: 200, data: JSON.stringify({ code: 0 }) }); return {} },
  authorize: (o: any) => o.success(),
  setStorageSync: (key: string, value: any) => { storage[key] = structuredClone(value) },
  getStorageSync: (key: string) => structuredClone(storage[key]),
  getFileSystemManager: () => ({ saveFile: (options: any) => saves.push(options) }),
}
const project = { deviceId: 'd', key: '1', name: 'synthetic project' } as never
const audio = (duration = 10000) => ({ tempFilePath: '/synthetic/recording.mp3', duration, fileSize: 1000 })
function callbacks() {
  const seen = { finished: 0, errors: [] as string[], interrupted: [] as boolean[], segments: [] as number[] }
  return { seen, onSegment: (n: number) => seen.segments.push(n), onFinish: () => { seen.finished++ },
    onError: (s: string) => seen.errors.push(s), onInterrupted: (v: boolean) => seen.interrupted.push(v) }
}
async function start() {
  assert.equal(recordingSnapshot(), null)
  storage = {}; saves = []; takeRecordingNotice()
  const cb = callbacks()
  assert.equal(await startRecording(project, cb), true)
  handlers.start()
  return cb.seen
}
function saved(index = 0) { saves[index].success({ savedFilePath: `/synthetic/saved-${index}.mp3` }) }

test('system interruption stops once, freezes clock, and reports saved only after durable storage', async () => {
  const originalNow = Date.now
  let now = 1000
  Date.now = () => now
  try {
    const seen = await start()
    now = 11000
    const before = { ...calls }
    handlers.interruptionBegin()
    handlers.interruptionBegin()
    now = 61000
    assert.equal(calls.stop, before.stop + 1)
    assert.equal(recordingSnapshot()?.elapsedSeconds, 10)
    handlers.stop(audio())
    assert.equal(takeRecordingNotice(), null)
    assert.equal(seen.finished, 0)
    assert.equal(await startRecording(project, callbacks()), false)
    saved()
    assert.equal(recordingSnapshot(), null)
    assert.equal(seen.finished, 1)
    assert.equal(takeRecordingNotice(), t('rec.interruption.saved'))
    assert.equal(takeRecordingNotice(), null)
    assert.equal(calls.start, before.start)
    assert.equal(calls.resume, before.resume)
    assert.equal(storage['awd.queue'][0].saved, true)
  } finally { Date.now = originalNow }
})

test('early unexpected stop is saved and ends the session without silently starting a new segment', async () => {
  const seen = await start()
  const starts = calls.start
  handlers.stop(audio())
  saved()
  assert.equal(seen.finished, 1)
  assert.deepEqual(seen.segments, [])
  assert.equal(calls.start, starts)
  assert.equal(takeRecordingNotice(), t('rec.interruption.saved'))
})

test('a complete ten-minute segment continues only after local save confirms success', async () => {
  const seen = await start()
  const starts = calls.start
  handlers.stop(audio(SEGMENT_DURATION_MS))
  assert.equal(calls.start, starts)
  saved()
  assert.equal(calls.start, starts + 1)
  assert.deepEqual(seen.segments, [2])
  handlers.start()
  stopRecording()
  handlers.stop(audio())
  saved(1)
  assert.equal(seen.finished, 1)
  assert.equal(takeRecordingNotice(), null)
})

test('user stop while the full segment is saving prevents automatic continuation', async () => {
  const seen = await start()
  const before = { ...calls }
  handlers.stop(audio(SEGMENT_DURATION_MS))
  stopRecording()
  saved()
  assert.equal(seen.finished, 1)
  assert.equal(calls.start, before.start)
  assert.equal(calls.stop, before.stop)
})

test('interruption while a full segment is saving prevents automatic continuation', async () => {
  const seen = await start()
  const starts = calls.start
  handlers.stop(audio(SEGMENT_DURATION_MS))
  handlers.interruptionBegin()
  saved()
  assert.equal(seen.finished, 1)
  assert.equal(calls.start, starts)
  assert.equal(takeRecordingNotice(), t('rec.interruption.saved'))
})

test('save failure retains the queued temporary file without claiming saved or continuing', async () => {
  const seen = await start()
  const starts = calls.start
  handlers.interruptionBegin()
  handlers.stop(audio())
  saves[0].fail()
  assert.equal(recordingSnapshot(), null)
  assert.equal(seen.finished, 0)
  assert.deepEqual(seen.errors, [t('rec.failed')])
  assert.equal(takeRecordingNotice(), t('rec.failed'))
  assert.equal(storage['awd.queue'][0].saved, false)
  assert.equal(storage['awd.queue'][0].filePath, '/synthetic/recording.mp3')
  assert.equal(calls.start, starts)
})

test('onStop then duplicate stop/error does not discard or enqueue the saved segment twice', async () => {
  const seen = await start()
  handlers.stop(audio())
  handlers.error()
  handlers.stop(audio())
  assert.equal(saves.length, 1)
  saved()
  assert.deepEqual(seen.errors, [])
  assert.equal(seen.finished, 1)
  assert.equal(storage['awd.queue'].length, 1)
})

test('error before stop preserves the valid final audio instead of dropping it', async () => {
  const seen = await start()
  handlers.interruptionBegin()
  handlers.error()
  handlers.stop(audio())
  saved()
  assert.equal(seen.finished, 1)
  assert.deepEqual(seen.errors, [])
  assert.equal(takeRecordingNotice(), t('rec.interruption.saved'))
})

test('an error with no final file eventually reports failure and releases the session', async (context) => {
  context.mock.timers.enable({ apis: ['setTimeout'] })
  const seen = await start()
  handlers.error()
  assert.equal(await startRecording(project, callbacks()), false)
  context.mock.timers.tick(5000)
  assert.equal(recordingSnapshot(), null)
  assert.deepEqual(seen.errors, [t('rec.failed')])
  assert.equal(saves.length, 0)
})

test('a stale error before a new start acknowledgement does not end the new session', async () => {
  storage = {}; saves = []; takeRecordingNotice()
  const seen = callbacks()
  assert.equal(await startRecording(project, seen), true)
  handlers.error()
  handlers.start()
  assert.ok(recordingSnapshot())
  assert.deepEqual(seen.seen.errors, [])
  stopRecording()
  handlers.stop(audio())
  saved()
  assert.equal(seen.seen.finished, 1)
})

test('stop before start acknowledgement stops again when the native recorder starts', async () => {
  storage = {}; saves = []; takeRecordingNotice()
  const cb = callbacks()
  assert.equal(await startRecording(project, cb), true)
  const stops = calls.stop
  stopRecording()
  handlers.start()
  assert.equal(calls.stop, stops + 2)
  assert.equal(recordingSnapshot()?.elapsedSeconds, 0)
  handlers.stop(audio())
  saved()
  assert.equal(cb.seen.finished, 1)
})

test('zero-duration or empty files are not queued as successful recordings', async () => {
  for (const result of [audio(0), { ...audio(), fileSize: 0 }, { ...audio(), tempFilePath: '' }]) {
    const seen = await start()
    handlers.stop(result)
    assert.equal(saves.length, 0)
    assert.equal(seen.finished, 0)
    assert.deepEqual(seen.errors, [t('rec.failed')])
  }
})

test('late duplicate save callbacks cannot finish or overwrite a new recording session', async () => {
  await start()
  handlers.stop(audio())
  const oldSave = saves[0]
  saved()
  const next = await start()
  oldSave.success({ savedFilePath: '/synthetic/old.mp3' })
  oldSave.fail()
  assert.equal(next.finished, 0)
  assert.deepEqual(next.errors, [])
  assert.ok(recordingSnapshot())
  stopRecording()
  handlers.stop(audio())
  saved()
  assert.equal(next.finished, 1)
})

test('page recreation rebinds completion callbacks and retains a notice until consumed', async () => {
  const original = await start()
  handlers.interruptionBegin()
  handlers.stop(audio())
  const replacement = callbacks()
  bindRecordingCallbacks(replacement)
  saved()
  assert.equal(original.finished, 0)
  assert.equal(replacement.seen.finished, 1)
  assert.equal(takeRecordingNotice(), t('rec.interruption.saved'))
})

test('concurrent start requests create one session; repeated manual stop requests stop once', async () => {
  storage = {}; saves = []; takeRecordingNotice()
  const cb = callbacks()
  assert.deepEqual(await Promise.all([startRecording(project, cb), startRecording(project, cb)]), [true, false])
  handlers.start()
  const stops = calls.stop
  stopRecording(); stopRecording()
  assert.equal(calls.stop, stops + 1)
  handlers.stop(audio())
  saved()
  assert.equal(cb.seen.finished, 1)
})

test('an unassigned recording keeps its original destination when the selected project changes', async () => {
  storage = {}; saves = []; takeRecordingNotice()
  const cb = callbacks()
  assert.equal(await startRecording(null, cb), true)
  handlers.start()
  storage['awd.project'] = project
  stopRecording()
  handlers.stop(audio())
  saved()
  assert.equal(storage['awd.queue'][0].deviceId, '')
  assert.equal(storage['awd.queue'][0].projectKey, '')
  assert.equal(storage['awd.queue'][0].state, 'waiting')
  assert.equal(cb.seen.finished, 1)
})

test('late old stop while awaiting a new start acknowledgement cannot save into the new project', async () => {
  storage = {}; saves = []; takeRecordingNotice()
  const cb = callbacks()
  assert.equal(await startRecording(project, cb), true)
  handlers.stop(audio())
  assert.equal(saves.length, 0)
  assert.ok(recordingSnapshot())
  handlers.start()
  stopRecording()
  handlers.stop(audio())
  saved()
  assert.equal(cb.seen.finished, 1)
})

test('failed start with no acknowledgement does not leave the recording controls stuck', async (context) => {
  context.mock.timers.enable({ apis: ['setTimeout'] })
  storage = {}; saves = []; takeRecordingNotice()
  const cb = callbacks()
  assert.equal(await startRecording(project, cb), true)
  handlers.error()
  context.mock.timers.tick(5000)
  assert.equal(recordingSnapshot(), null)
  assert.deepEqual(cb.seen.errors, [t('rec.failed')])
})

test('a delayed native start after a failed session timed out is stopped instead of recording without controls', async (context) => {
  context.mock.timers.enable({ apis: ['setTimeout'] })
  storage = {}; saves = []; takeRecordingNotice()
  assert.equal(await startRecording(project, callbacks()), true)
  handlers.error()
  context.mock.timers.tick(5000)
  assert.equal(recordingSnapshot(), null)
  const stops = calls.stop
  handlers.start()
  assert.equal(calls.stop, stops + 1)
})


test('explicit pause waits for native acknowledgement, freezes elapsed time, and resumes the same segment', async () => {
  const originalNow = Date.now
  let now = 1000
  Date.now = () => now
  try {
    const seen = await start()
    now = 4000
    pauseRecording()
    assert.equal(recordingSnapshot()?.paused, false)
    assert.equal(recordingSnapshot()?.pausePending, true)
    handlers.pause()
    now = 64000
    assert.equal(recordingSnapshot()?.paused, true)
    assert.equal(recordingSnapshot()?.elapsedSeconds, 3)
    const starts = calls.start
    resumeRecording()
    handlers.resume()
    now = 66000
    assert.equal(recordingSnapshot()?.elapsedSeconds, 5)
    assert.equal(recordingSnapshot()?.segmentIndex, 1)
    assert.equal(calls.start, starts)
    stopRecording(); handlers.stop(audio()); saved()
    assert.equal(seen.finished, 1)
  } finally { Date.now = originalNow }
})

test('native pause without a user pause intent is an interruption and saves rather than showing user-paused', async () => {
  const seen = await start()
  const stops = calls.stop
  handlers.pause()
  assert.equal(recordingSnapshot()?.paused, false)
  assert.equal(calls.stop, stops + 1)
  assert.deepEqual(seen.interrupted, [true])
  handlers.stop(audio()); saved()
  assert.equal(takeRecordingNotice(), t('rec.interruption.saved'))
})

test('stop while user-paused saves once and a late resume cannot restart recording', async () => {
  const seen = await start()
  pauseRecording(); handlers.pause()
  stopRecording()
  handlers.resume()
  handlers.stop(audio()); saved()
  assert.equal(seen.finished, 1)
  assert.equal(recordingSnapshot(), null)
})


test('a stale silence confirmation cannot stop a later recording session', async () => {
  await start()
  const oldId = recordingSnapshot()!.sessionId
  stopRecording(); handlers.stop(audio()); saved()
  const seen = await start()
  const stops = calls.stop
  answerSilenceReminder(oldId, true)
  assert.equal(calls.stop, stops)
  assert.ok(recordingSnapshot())
  stopRecording(); handlers.stop(audio()); saved()
  assert.equal(seen.finished, 1)
})


test('real packaged VAD retains an undisplayed reminder across callback unbinding and clears it on pause', async () => {
  const wasm = readFileSync(new URL('../miniprogram/vendor/speech/speech.wasm', import.meta.url))
  const compiled = await WebAssembly.instantiate(wasm)
  ;(globalThis as any).WXWebAssembly = { instantiate: () => Promise.resolve(compiled) }
  const originalNow = Date.now
  let now = 1000
  Date.now = () => now
  try {
    await start()
    await new Promise(resolve => setImmediate(resolve))
    bindRecordingCallbacks({ onSegment() {}, onFinish() {}, onError() {}, onSilence() {} })
    const bytes = gunzipSync(readFileSync(new URL('fixtures/speech/silence-long.mp3.gz', import.meta.url)))
    for (let i = 0; i < bytes.length; i += 6144) {
      const chunk = bytes.subarray(i, i + 6144)
      now += 1024
      handlers.frame({ frameBuffer: chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.length) })
    }
    assert.equal(recordingSnapshot()?.silencePending, true)
    const replacement = callbacks()
    bindRecordingCallbacks(replacement)
    assert.equal(recordingSnapshot()?.silencePending, true)
    pauseRecording(); handlers.pause()
    assert.equal(recordingSnapshot()?.silencePending, false)
    stopRecording(); handlers.stop(audio()); saved()
  } finally {
    if (recordingSnapshot()) { stopRecording(); handlers.stop(audio()); if (saves.length) saved(saves.length - 1) }
    Date.now = originalNow; delete (globalThis as any).WXWebAssembly
  }
})
