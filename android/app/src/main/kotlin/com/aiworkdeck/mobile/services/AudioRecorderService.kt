package com.aiworkdeck.mobile.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaMetadataRetriever
import android.media.MediaRecorder
import android.os.SystemClock
import androidx.core.content.ContextCompat
import java.io.File

/** One microphone, one PCM stream: AAC/M4A (48 kHz mono, 64 kbps) and local WebRTC VAD. */
class AudioRecorderService(
    private val context: Context,
    private val onInterrupted: () -> Unit = {},
    private val onSilence: (Boolean) -> Unit = {},
    private val onAnalysisUnavailable: () -> Unit = {},
    private val onDuration: (Long) -> Unit = {},
) {
    val isRecording: Boolean get() = running
    var recordingStartedAt: Long? = null
        private set
    @Volatile private var running = false
    @Volatile private var paused = false
    @Volatile private var generation = 0L
    private val lock = Any()
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null
    private var file: File? = null
    private val silence = RecordingSilence()
    private val main = ContextCompat.getMainExecutor(context)
    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
            if (running && !paused && recorder?.activeRecordingConfiguration?.isClientSilenced == true) onInterrupted()
        }
    }

    fun start(target: File): Boolean {
        if (running) return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return false
        var r: AudioRecord? = null
        var writer: AacWriter? = null
        return try {
            val min = AudioRecord.getMinBufferSize(AacWriter.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(min > 0)
            r = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(AacWriter.SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(min * 2, 960 * 2 * 4)).build()
            check(r.state == AudioRecord.STATE_INITIALIZED)
            writer = AacWriter(target)
            r.registerAudioRecordingCallback(main, callback)
            r.startRecording()
            check(r.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            recorder = r
            file = target
            recordingStartedAt = System.currentTimeMillis()
            paused = false
            running = true
            val input = r; val output = writer
            worker = Thread({ record(input, output) }, "workdeck-audio").apply { start() }
            true
        } catch (_: Exception) {
            runCatching { r?.release() }
            runCatching { writer?.finish() }
            target.delete()
            false
        }
    }

    private fun record(input: AudioRecord, output: AacWriter) {
        var detector: VoiceActivityDetector? = try { VoiceActivityDetector() } catch (_: Throwable) {
            main.execute(onAnalysisUnavailable); null
        }
        val frame = ShortArray(960)
        var filled = 0
        var samples = 0L
        var lastRead = SystemClock.elapsedRealtime()
        var lastGeneration = generation
        var lastReportedSecond = -1L
        try {
            while (running) {
                if (paused) { Thread.sleep(10); continue }
                val epoch = generation
                if (epoch != lastGeneration) { filled = 0; lastGeneration = epoch }
                val count = input.read(frame, filled, frame.size - filled, AudioRecord.READ_BLOCKING)
                synchronized(lock) {
                    if (!running || paused || epoch != generation) { filled = 0; return@synchronized }
                    check(count > 0) { "Audio capture interrupted: $count" }
                    val now = SystemClock.elapsedRealtime()
                    // A stalled/missing callback is not evidence that the room stayed silent.
                    if (now - lastRead > 250) { silence.reset(); main.execute { onSilence(false) } }
                    lastRead = now
                    filled += count
                    if (filled != frame.size) return@synchronized
                    output.write(frame, frame.size)
                    samples += frame.size
                    filled = 0
                    val second = samples / AacWriter.SAMPLE_RATE
                    if (second != lastReportedSecond) {
                        lastReportedSecond = second
                        val duration = samples * 1000 / AacWriter.SAMPLE_RATE
                        main.execute { onDuration(duration) }
                    }
                    detector?.let { vad ->
                        try {
                            val before = silence.needsConfirmation
                            val after = silence.observe(20, vad.isSpeech(frame))
                            if (before != after) main.execute { onSilence(after) }
                        } catch (_: Throwable) {
                            runCatching { vad.close() }; detector = null
                            silence.reset()
                            main.execute { onSilence(false); onAnalysisUnavailable() }
                        }
                    }
                }
            }
        } catch (_: Exception) {
            if (running) main.execute(onInterrupted)
        } finally {
            runCatching { output.finish() }
            runCatching { detector?.close() }
        }
    }

    fun pause(): Boolean = synchronized(lock) {
        if (!running || paused) return@synchronized paused
        try {
            recorder?.stop()
            paused = true
            generation++
            silence.reset()
            onSilence(false)
            true
        } catch (_: Exception) { false }
    }

    fun resume(): Boolean = synchronized(lock) {
        if (!running || !paused) return@synchronized false
        try {
            recorder?.startRecording()
            check(recorder?.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            generation++
            silence.reset()
            paused = false
            onSilence(false)
            true
        } catch (_: Exception) { false }
    }

    fun keepRecording() = synchronized(lock) { silence.reset(); onSilence(false) }

    fun stop(): File? {
        running = false
        generation++
        val r = recorder
        runCatching { r?.stop() }
        worker?.join(3_000)
        // Do not inspect or delete a file while its encoder could still be finalizing it.
        val finished = worker?.isAlive != true
        worker = null
        runCatching { r?.unregisterAudioRecordingCallback(callback) }
        runCatching { r?.release() }
        recorder = null
        recordingStartedAt = null
        return file?.takeIf { finished && isPlayableAudio(it) }.also { file = null }
    }
}

internal fun isPlayableAudio(file: File): Boolean = runCatching {
    MediaMetadataRetriever().use { reader ->
        reader.setDataSource(file.absolutePath)
        reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes" &&
            (reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0) > 0
    }
}.getOrDefault(false)
