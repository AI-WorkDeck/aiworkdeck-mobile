import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'

function fixture() {
  const callbacks: Record<string, Function> = {}
  const calls: string[] = []
  let failStart = false
  let nativeStatus = 10
  const capturer = { state: 1, on: (type: string, cb: Function) => { callbacks[type] = cb }, off: (type: string) => { delete callbacks[type] },
    start: async () => { if (failStart) throw new Error('focus denied'); capturer.state = 2; calls.push('start') },
    stop: async () => { capturer.state = 3; callbacks.stateChange?.(3); calls.push('stop') }, release: async () => { calls.push('release') } }
  const native = { start: () => true, push: () => { calls.push('pcm'); return nativeStatus },
    resetVoice: () => { calls.push('resetVoice') }, finish: async () => { calls.push('finish'); return true } }
  const audio = { createAudioCapturer: async () => capturer, AudioSamplingRate: { SAMPLE_RATE_48000: 48000 },
    AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
    SourceType: { SOURCE_TYPE_MIC: 0 }, AudioState: { STATE_RUNNING: 2 },
    InterruptHint: { INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3, INTERRUPT_HINT_MUTE: 6 } }
  const modules: Record<string, any> = { '@kit.AudioKit': { audio }, 'librecording.so': { default: native } }
  const source = readFileSync(new URL('../../harmony/entry/src/main/ets/services/PcmRecorder.ets', import.meta.url), 'utf8')
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const exports: any = {}
  new Function('require', 'exports', output)((id: string) => { assert.ok(modules[id], id); return modules[id] }, exports)
  return { create: () => exports.PcmRecorder.create(1), callbacks, calls, failStart: () => { failStart = true }, status: (s: number) => { nativeStatus = s } }
}

test('one microphone sends identical PCM to native AAC/VAD; pause stops capture and rejects stale callbacks', async () => {
  const f = fixture(); const rec = await f.create(); let interrupted = 0
  rec.onInterrupted = () => { interrupted++ }
  await rec.start()
  const oldRead = f.callbacks.readData
  oldRead(new ArrayBuffer(1920))
  await rec.pause()
  oldRead(new ArrayBuffer(1920))
  assert.equal(f.calls.filter(x => x === 'pcm').length, 1)
  assert.equal(interrupted, 0)
  await rec.resume()
  oldRead(new ArrayBuffer(1920))
  assert.equal(f.calls.filter(x => x === 'pcm').length, 1)
  f.callbacks.readData(new ArrayBuffer(1920))
  assert.equal(f.calls.filter(x => x === 'pcm').length, 2)
  await rec.stop(); await rec.release()
})

test('VAD failure only reports unavailable; codec failure and real mic interruption ask to save', async () => {
  const f = fixture(); const rec = await f.create(); let interrupted = 0; const voice: number[] = []
  rec.onInterrupted = () => { interrupted++ }; rec.onVoice = (ms: number) => { voice.push(ms) }
  await rec.start()
  f.status(-1); f.callbacks.readData(new ArrayBuffer(1920))
  assert.deepEqual(voice, [-1]); assert.equal(interrupted, 0)
  f.status(-2); f.callbacks.readData(new ArrayBuffer(1920))
  assert.equal(interrupted, 1)
  await rec.stop(); await rec.release()
  const other = fixture(); const second = await other.create(); second.onInterrupted = () => { interrupted++ }
  await second.start(); other.callbacks.audioInterrupt({ hintType: 6 })
  assert.equal(interrupted, 2)
  await second.stop(); await second.release()
})

test('failed resume and empty PCM cannot falsely advance a voice streak or resume recording', async () => {
  const f = fixture(); const rec = await f.create()
  await rec.start(); f.callbacks.readData(new ArrayBuffer(0))
  assert.equal(f.calls.includes('pcm'), false)
  await rec.pause(); f.failStart()
  await assert.rejects(rec.resume(), /focus denied/)
  assert.equal(f.callbacks.readData, undefined)
  await rec.stop(); await rec.release()
})
