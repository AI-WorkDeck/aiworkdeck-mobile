import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'

test('vendored WebRTC VAD: 300s silence, invalid input and upstream speech at recording rates', () => {
  const root = join(import.meta.dirname, '..')
  const lib = join(root, 'third_party/libfvad')
  const dir = mkdtempSync(join(tmpdir(), 'awd-vad-'))
  try {
    const binary = join(dir, 'vad-fixture')
    const sources = readdirSync(join(lib, 'src'), { recursive: true })
      .filter((name) => String(name).endsWith('.c')).map((name) => join(lib, 'src', String(name)))
    const build = spawnSync(process.env.CC || 'cc', ['-std=c11', '-O2', '-I', join(lib, 'include'),
      join(root, 'tests/native/vad_fixture.c'), ...sources, '-o', binary], { encoding: 'utf8' })
    assert.equal(build.status, 0, build.stderr || String(build.error))
    for (const rate of [16000, 48000]) {
      const wav = readFileSync(join(lib, `tests/data/audio_tiny${rate / 1000}.wav`))
      assert.equal(wav.toString('ascii', 0, 4), 'RIFF')
      let pcm: Buffer | undefined
      for (let offset = 12; offset + 8 <= wav.length;) {
        const size = wav.readUInt32LE(offset + 4)
        if (wav.toString('ascii', offset, offset + 4) === 'data') {
          pcm = wav.subarray(offset + 8, offset + 8 + size)
          break
        }
        offset += 8 + size + (size % 2)
      }
      assert.ok(pcm, 'upstream WAV data chunk is required')
      const run = spawnSync(binary, [String(rate)], { input: pcm, encoding: 'utf8' })
      assert.equal(run.status, 0, run.stderr || String(run.error))
      const [speech, frames] = run.stdout.trim().split('/').map(Number)
      assert.equal(frames, 270)
      // Raw PCM differs slightly from upstream fvadwav's float-to-int16 rounding.
      assert.ok(speech >= 240 && speech < frames, `${rate}Hz: ${speech}/${frames} speech frames`)
    }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
