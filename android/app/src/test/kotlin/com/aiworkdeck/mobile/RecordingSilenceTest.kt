package com.aiworkdeck.mobile

import com.aiworkdeck.mobile.services.RecordingSilence
import com.aiworkdeck.mobile.services.RecordingState
import org.junit.Assert.*
import org.junit.Test

class RecordingSilenceTest {
    @Test fun onlyFullFiveMinutesOfClassifiedAudioPrompts() {
        val silence = RecordingSilence()
        repeat(14_999) { assertFalse(silence.observe(20, false)) }
        assertTrue(silence.observe(20, false))
    }
    @Test fun speechRestartsIntervalAndClearsReminder() {
        val silence = RecordingSilence()
        silence.observe(300_000, false)
        assertFalse(silence.observe(20, true))
        assertFalse(silence.observe(299_980, false))
        assertTrue(silence.observe(20, false))
    }
    @Test fun pauseMissingFramesAndContinueEachRestartInterval() {
        repeat(3) {
            val silence = RecordingSilence()
            silence.observe(299_980, false)
            silence.reset()
            assertFalse(silence.observe(20, false))
            assertFalse(silence.needsConfirmation)
        }
    }
    @Test fun noClassificationsCannotAdvanceReminder() {
        val silence = RecordingSilence()
        repeat(1_000_000) { silence.observe(0, false) }
        assertFalse(silence.needsConfirmation)
    }
    @Test fun pausedRemainsARecordingWithFrozenSampleDuration() {
        try {
            RecordingState.begin(1)
            RecordingState.elapsedMs = 2000
            RecordingState.silenceConfirmation = true
            RecordingState.applyPaused(true)
            assertTrue(RecordingState.isRecording)
            assertTrue(RecordingState.isPaused)
            assertEquals(2000, RecordingState.elapsedMs)
            assertFalse(RecordingState.silenceConfirmation)
            RecordingState.applyPaused(false)
            assertFalse(RecordingState.isPaused)
            assertEquals(2000, RecordingState.elapsedMs)
        } finally { RecordingState.finish() }
    }
}
