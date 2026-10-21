import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { t, setLocale } from '../miniprogram/utils/i18n.ts'
import { Mp3VoiceDetector, SilenceWindow } from '../miniprogram/utils/silence-monitor.ts'

async function detector() {
  const bytes = readFileSync(new URL('../miniprogram/vendor/speech/speech.wasm', import.meta.url))
  const module = await WebAssembly.compile(bytes)
  assert.deepEqual(WebAssembly.Module.imports(module), [])
  const instance = await WebAssembly.instantiate(module)
  return new Mp3VoiceDetector(instance.exports as never)
}
async function classify(file: string) {
  const d = await detector()
  const bytes = readFileSync(new URL(`fixtures/speech/${file}.mp3`, import.meta.url))
  const decisions: boolean[] = []
  for (let i = 0; i < bytes.length; i += 6144) {
    const chunk = bytes.subarray(i, i + 6144)
    decisions.push(...d.push(chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.length)))
  }
  return decisions
}
test('packaged MP3 decoder and WebRTC classifier recognize voice and silence locally, while noisy input conservatively prevents a false reminder', async () => {
  const speech = await classify('voice')
  const silence = await classify('silence')
  const noise = await classify('noise')
  assert.ok(speech.filter(Boolean).length > 100)
  assert.ok(silence.length > 400)
  assert.equal(silence.filter(Boolean).length, 0)
  assert.ok(noise.filter(Boolean).length > 0) // WebRTC can classify loud noise as speech: do not claim perfect acoustic recognition.
})
test('five minutes means classified non-voice frames, with one reminder until explicitly reset', () => {
  const gate = new SilenceWindow()
  for (let i = 0; i < 29999; i++) assert.equal(gate.accept(false, 10, i * 10), false)
  assert.equal(gate.accept(false, 10, 299990), true)
  assert.equal(gate.accept(false, 10, 300000), false)
  gate.reset()
  assert.equal(gate.accept(false, 10, 300010), false)
})
test('voice, missing frames, pause/resume, and keep-recording reset the consecutive window', () => {
  for (const reset of ['voice', 'gap', 'reset']) {
    const gate = new SilenceWindow()
    for (let i = 0; i < 29999; i++) gate.accept(false, 10, i * 10)
    if (reset === 'voice') gate.accept(true, 10, 299990)
    if (reset === 'reset') gate.reset()
    assert.equal(gate.accept(false, 10, reset === 'gap' ? 310000 : 300000), false)
  }
})
test('decoder has bounded frame memory and reset drops incomplete MP3 bytes', async () => {
  const d = await detector()
  assert.throws(() => d.push(new ArrayBuffer(20000)))
  d.push(new ArrayBuffer(1024))
  d.reset()
  const silent = readFileSync(new URL('fixtures/speech/silence.mp3', import.meta.url)).subarray(0, 6144)
  assert.ok(d.push(silent.buffer.slice(silent.byteOffset, silent.byteOffset + silent.length)).length > 0)
})
test('a pending reminder is revoked by speech or a frame gap before returning to the page', () => {
  for (const speech of [true, false]) {
    const gate = new SilenceWindow()
    for (let i = 0; i < 30000; i++) gate.accept(false, 10, i * 10)
    assert.equal(gate.awaitingConfirmation, true)
    gate.accept(speech, 10, speech ? 300000 : 310000)
    assert.equal(gate.awaitingConfirmation, false)
  }
})

test('native modal button labels fit the four-character platform limit in both languages', () => {
  try {
    for (const locale of ['zh-Hans', 'en'] as const) {
      setLocale(locale)
      for (const key of ['rec.silence.stop.short', 'rec.silence.continue.short']) assert.ok(t(key).length <= 4)
    }
  } finally { setLocale('zh-Hans') }
})
