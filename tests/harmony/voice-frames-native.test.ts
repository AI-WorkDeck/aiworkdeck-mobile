import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

// Compile the production header against the pinned upstream C implementation on macOS and CI/Linux.
// No SDK/emulator, downloaded model, ffmpeg, synthetic VAD stub, or shortened threshold is involved.
test('native WebRTC classifies 300 seconds, voice PCM, missing frames and pause resets', { timeout: 120000 }, () => {
  const root = fileURLToPath(new URL('../../', import.meta.url))
  const vendor = join(root, 'third_party/libfvad')
  const work = mkdtempSync(join(tmpdir(), 'harmony-voice-'))
  try {
    const sources = ['src/fvad.c', ...['signal_processing', 'vad'].flatMap(dir =>
      readdirSync(join(vendor, 'src', dir)).filter(file => file.endsWith('.c')).map(file => `src/${dir}/${file}`))]
    const objects = sources.map((source, i) => {
      const object = join(work, `${i}.o`)
      execFileSync(process.env.CC || 'cc', ['-std=c11', '-O1', '-I', join(vendor, 'include'),
        '-I', join(vendor, 'src'), '-c', join(vendor, source), '-o', object], { stdio: 'pipe' })
      return object
    })
    const binary = join(work, 'voice-frames')
    execFileSync(process.env.CXX || 'c++', ['-std=c++17', '-O1', '-I', join(vendor, 'include'),
      join(root, 'tests/harmony/voice-frames-native.cpp'), ...objects, '-lm', '-o', binary], { stdio: 'pipe' })
    const wav = readFileSync(join(vendor, 'tests/data/audio_tiny48.wav'))
    assert.equal(wav.toString('ascii', 0, 4), 'RIFF')
    let pcm: Buffer | undefined
    for (let offset = 12; offset + 8 <= wav.length;) {
      const type = wav.toString('ascii', offset, offset + 4)
      const length = wav.readUInt32LE(offset + 4)
      if (type === 'fmt ') {
        assert.equal(wav.readUInt16LE(offset + 8), 1) // uncompressed PCM
        assert.equal(wav.readUInt16LE(offset + 10), 1)
        assert.equal(wav.readUInt32LE(offset + 12), 48000)
        assert.equal(wav.readUInt16LE(offset + 22), 16)
      }
      if (type === 'data') pcm = wav.subarray(offset + 8, offset + 8 + length)
      offset += 8 + length + length % 2
    }
    assert.ok(pcm && pcm.byteLength > 960)
    const sample = join(work, 'voice.pcm')
    writeFileSync(sample, pcm)
    const output = execFileSync(binary, [sample], { encoding: 'utf8' })
    assert.match(output, /PASS: real WebRTC 300 s threshold/)
  } finally { rmSync(work, { recursive: true, force: true }) }
})
