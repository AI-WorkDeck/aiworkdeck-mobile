import { audio } from '@kit.AudioKit'
import recording from 'librecording.so'

/** A single microphone feeds both the AAC file and the local WebRTC speech classifier. */
export class PcmRecorder {
  private capturer: audio.AudioCapturer | null = null
  private accepting: boolean = false
  private operating: boolean = false
  private released: boolean = false
  private lastFrame: number = 0
  private generation: number = 0
  private healthTimer: number = -1
  onInterrupted: (() => void) | null = null
  onVoice: ((silenceMs: number) => void) | null = null

  static async create(fd: number): Promise<PcmRecorder> {
    const value: PcmRecorder = new PcmRecorder()
    value.capturer = await audio.createAudioCapturer({
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 },
    })
    if (!recording.start(fd)) { await value.capturer.release(); throw new Error('AAC recorder prepare failed') }
    value.listen(value.capturer)
    return value
  }

  async start(): Promise<void> {
    const capturer: audio.AudioCapturer | null = this.capturer
    if (capturer === null || this.released) throw new Error('recorder released')
    this.operating = true
    try {
      recording.resetVoice()
      this.lastFrame = Date.now()
      capturer.off('readData')
      const epoch: number = ++this.generation
      capturer.on('readData', (data: ArrayBuffer): void => {
        if (!this.accepting || this.released || this.capturer !== capturer || epoch !== this.generation) return
        if (data.byteLength === 0) return
        this.lastFrame = Date.now()
        const result: number = recording.push(data)
        if (result === -2) {
          this.accepting = false
          if (this.onInterrupted !== null) this.onInterrupted()
        } else if (this.onVoice !== null) this.onVoice(result)
      })
      await capturer.start()
      this.accepting = true
      this.healthTimer = setInterval((): void => {
        if (this.accepting && Date.now() - this.lastFrame > 1000) {
          recording.resetVoice()
          if (this.onVoice !== null) this.onVoice(-1)
        }
      }, 1000)
    } catch (e) {
      this.accepting = false
      this.generation++
      capturer.off('readData')
      if (capturer.state === audio.AudioState.STATE_RUNNING) { try { await capturer.stop() } catch (_) {} }
      throw e as Error
    } finally { this.operating = false }
  }

  async pause(): Promise<void> {
    const capturer: audio.AudioCapturer | null = this.capturer
    if (capturer === null || !this.accepting) return
    this.operating = true
    this.accepting = false
    this.generation++
    capturer.off('readData')
    recording.resetVoice()
    this.clearHealth()
    try { await capturer.stop() } catch (e) {
      // Failure leaves the capturer's actual state uncertain. Caller saves rather than claiming a pause.
      throw e as Error
    } finally { this.operating = false }
  }

  async resume(): Promise<void> { await this.start() }

  async stop(): Promise<void> {
    const capturer: audio.AudioCapturer | null = this.capturer
    this.operating = true
    this.accepting = false
    this.generation++
    if (capturer !== null) capturer.off('readData')
    this.clearHealth()
    try {
      if (capturer !== null && capturer.state === audio.AudioState.STATE_RUNNING) await capturer.stop()
    } finally {
      this.operating = false
      if (!await recording.finish()) throw new Error('AAC encoding was interrupted')
    }
  }

  async release(): Promise<void> {
    if (this.released) return
    this.released = true
    this.accepting = false
    this.clearHealth()
    const capturer: audio.AudioCapturer | null = this.capturer
    this.capturer = null
    try { if (capturer !== null) await capturer.release() } finally { await recording.finish() }
  }

  resetVoice(): void { recording.resetVoice() }

  private clearHealth(): void {
    if (this.healthTimer >= 0) clearInterval(this.healthTimer)
    this.healthTimer = -1
  }

  private listen(capturer: audio.AudioCapturer): void {
    capturer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      if (this.released || this.capturer !== capturer) return
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_MUTE) {
        this.accepting = false
        recording.resetVoice()
        if (this.onInterrupted !== null) this.onInterrupted()
      }
    })
    capturer.on('stateChange', (state: audio.AudioState): void => {
      if (this.released || this.operating || !this.accepting || this.capturer !== capturer) return
      if (state !== audio.AudioState.STATE_RUNNING) {
        this.accepting = false
        if (this.onInterrupted !== null) this.onInterrupted()
      }
    })
  }
}
