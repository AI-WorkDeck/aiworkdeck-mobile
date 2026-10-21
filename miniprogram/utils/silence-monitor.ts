/** Counts classified audio, never wall-clock gaps or an amplitude threshold. */
import { VOICE_REMINDER_SECONDS } from './contract/capabilities'
export const SILENCE_LIMIT_MS = VOICE_REMINDER_SECONDS * 1000
export class SilenceWindow {
  private silenceMs = 0
  private lastFrameAt: number | null = null
  private pending = false
  reset(): void { this.silenceMs = 0; this.lastFrameAt = null; this.pending = false }
  get awaitingConfirmation(): boolean { return this.pending }
  accept(voice: boolean, durationMs: number, now: number): boolean {
    if (voice || (this.lastFrameAt !== null && now - this.lastFrameAt > 2500)) { this.silenceMs = 0; this.pending = false }
    this.lastFrameAt = now
    if (this.pending) return false
    this.silenceMs = voice ? 0 : this.silenceMs + durationMs
    if (this.silenceMs < SILENCE_LIMIT_MS) return false
    this.pending = true
    return true
  }
}

interface SpeechExports {
  memory: { buffer: ArrayBuffer }
  reset(): void
  input_ptr(): number
  decode(length: number): number
  decisions_ptr(): number
  decision_count(): number
  decoded_samples(): number
}

/** The instance has its own fixed 256 KiB memory; no Web Audio, network, or audio copies to storage. */
export class Mp3VoiceDetector {
  private pending = new Uint8Array(0)
  private wasm: SpeechExports
  constructor(wasm: SpeechExports) { this.wasm = wasm; wasm.reset() }
  reset(): void { this.pending = new Uint8Array(0); this.wasm.reset() }
  push(chunk: ArrayBuffer): boolean[] {
    if (!chunk.byteLength || chunk.byteLength + this.pending.length > 16384) throw new Error('invalid audio frame')
    const bytes = new Uint8Array(this.pending.length + chunk.byteLength)
    bytes.set(this.pending); bytes.set(new Uint8Array(chunk), this.pending.length)
    const decisions: boolean[] = []
    let offset = 0
    // Keep enough bytes for the next MP3 header/frame. Never ask minimp3 to consume
    // an incomplete last frame, which would discard its reservoir continuity.
    while (bytes.length - offset > 2048) {
      new Uint8Array(this.wasm.memory.buffer, this.wasm.input_ptr(), bytes.length - offset).set(bytes.subarray(offset))
      const used = this.wasm.decode(bytes.length - offset)
      if (used <= 0 || used > bytes.length - offset) throw new Error('invalid MP3 stream')
      offset += used
      const count = this.wasm.decision_count()
      if (!this.wasm.decoded_samples()) {
        // Startup/seek reservoir unavailable: unknown audio breaks consecutive silence.
        decisions.push(true)
      } else {
        const result = new Uint8Array(this.wasm.memory.buffer, this.wasm.decisions_ptr(), count)
        for (const voice of result) decisions.push(voice !== 0)
      }
    }
    this.pending = bytes.slice(offset)
    return decisions
  }
  static async create(): Promise<Mp3VoiceDetector> {
    // WeChat uses a package path, not WebAssembly.instantiate(bytes).
    const result = await WXWebAssembly.instantiate('vendor/speech/speech.wasm')
    const instance = (result as unknown as { instance?: { exports: unknown } }).instance ?? result
    return new Mp3VoiceDetector(instance.exports as unknown as SpeechExports)
  }
}
