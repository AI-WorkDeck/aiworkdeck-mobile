package com.aiworkdeck.mobile.services

/** Only classified PCM contributes time. Gaps, speech and user confirmation restart the interval. */
internal class RecordingSilence(private val thresholdMs: Long = com.aiworkdeck.contract.ContractCapabilities.voiceReminderSeconds * 1000L) {
    private var silentMs = 0L
    var needsConfirmation = false
        private set

    fun observe(durationMs: Long, voice: Boolean): Boolean {
        if (durationMs <= 0) return needsConfirmation
        if (voice) reset() else {
            silentMs += durationMs
            if (silentMs >= thresholdMs) needsConfirmation = true
        }
        return needsConfirmation
    }

    fun reset() { silentMs = 0; needsConfirmation = false }
}

internal class VoiceActivityDetector : AutoCloseable {
    private var handle = create()
    init { check(handle != 0L) }
    fun isSpeech(frame: ShortArray): Boolean {
        check(handle != 0L)
        val result = process(handle, frame)
        check(result >= 0)
        return result == 1
    }
    override fun close() { if (handle != 0L) { destroy(handle); handle = 0 } }
    private external fun create(): Long
    private external fun process(handle: Long, pcm: ShortArray): Int
    private external fun destroy(handle: Long)
    companion object { init { System.loadLibrary("workdeck_vad") } }
}
