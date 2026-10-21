package com.aiworkdeck.mobile.services

import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import kotlin.math.sin

/** Real codec/JNI smoke tests on emulator/device, independent of microphone permissions. */
class AudioPipelineDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    @Test fun testNativeVadProcessesFiveMinutesAndRestartsAfterConfirmation() {
        VoiceActivityDetector().use { vad ->
            val silence = RecordingSilence()
            val frame = ShortArray(960)
            repeat(14_999) { assertFalse(silence.observe(20, vad.isSpeech(frame))) }
            assertTrue(silence.observe(20, vad.isSpeech(frame)))
            silence.reset()
            assertFalse(silence.observe(20, vad.isSpeech(frame)))
            var failed = false
            try { vad.isSpeech(ShortArray(10)) } catch (_: IllegalStateException) { failed = true }
            assertTrue(failed)
        }
    }

    @Test fun testUpstreamSpeechFixtureIsNotSilence() {
        val bytes = instrumentation.context.assets.open("audio_tiny48.wav").use { it.readBytes() }
        val buffer = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        while (String(bytes, offset, 4, Charsets.US_ASCII) != "data") {
            val size = buffer.getInt(offset + 4)
            offset += 8 + size + (size % 2)
        }
        val end = offset + 8 + buffer.getInt(offset + 4)
        offset += 8
        var voiceFrames = 0
        VoiceActivityDetector().use { vad ->
            while (offset + 1920 <= end) {
                val pcm = ShortArray(960) { buffer.getShort(offset + it * 2) }
                if (vad.isSpeech(pcm)) voiceFrames++
                offset += 1920
            }
        }
        assertTrue("speech frames: $voiceFrames", voiceFrames > 20)
    }

    @Test fun testStreamingAacHasOnlyWrittenSamplesAndRemainsPlayable() {
        val file = File(instrumentation.targetContext.cacheDir, "pipeline-device-test.m4a")
        try {
            val output = AacWriter(file)
            val frame = ShortArray(960) { (sin(it * 2 * Math.PI * 440 / 48000) * 2000).toInt().toShort() }
            repeat(25) { output.write(frame, frame.size) }
            Thread.sleep(700) // Paused wall time must not be encoded into the media timeline.
            repeat(25) { output.write(frame, frame.size) }
            output.finish()
            assertTrue(isPlayableAudio(file))
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.absolutePath)
                assertEquals(1, extractor.trackCount)
                val format = extractor.getTrackFormat(0)
                assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, format.getString(MediaFormat.KEY_MIME))
                assertEquals(48000, format.getInteger(MediaFormat.KEY_SAMPLE_RATE))
                assertEquals(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
                val duration = format.getLong(MediaFormat.KEY_DURATION)
                assertTrue("$duration us", duration in 980_000..1_080_000)
                assertTrue("${file.length()} bytes", file.length() < 20_000)
            } finally { extractor.release() }
        } finally { file.delete() }
    }
}
