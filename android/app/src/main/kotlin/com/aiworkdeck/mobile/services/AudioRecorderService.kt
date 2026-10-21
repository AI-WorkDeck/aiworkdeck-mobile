package com.aiworkdeck.mobile.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.media.MediaMetadataRetriever
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import androidx.core.content.ContextCompat
import java.io.File

/**
 * 现场录音。参数与 iOS `AudioRecorderService` 对齐：AAC / MPEG-4 容器（.m4a）、44.1kHz、
 * 单声道、64kbps——人声清晰，一小时约 28MB，走与照片同一条 EvidenceStore → UploadQueue 链路。
 *
 * 录音不经过相机会话：麦克风不需要点亮摄像头，也不该占着取景。
 *
 * 纯录音引擎，由前台服务 [RecordingService] 持有；界面不直接拿它，可观察的状态在 [RecordingState]。
 */
class AudioRecorderService(private val context: Context, private val onInterrupted: () -> Unit = {}) {
    val isRecording: Boolean get() = recorder != null

    /** 录制开始的墙钟时刻。落库用的采集时刻也取它——「什么时候开始录」比「什么时候按停」重要。 */
    var recordingStartedAt: Long? = null
        private set

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
            if (recorder != null && configs.any { it.isClientSilenced }) onInterrupted()
        }
    }

    /** 开录。没有麦克风权限直接返回 false，由界面去解释，不在这里弹东西。 */
    fun start(target: File): Boolean {
        if (recorder != null) return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return false
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else MediaRecorder()
        return try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(44_100)
            r.setAudioChannels(1)
            r.setAudioEncodingBitRate(64_000)
            r.setOutputFile(target.absolutePath)
            r.setOnErrorListener { _, _, _ -> if (recorder != null) onInterrupted() }
            r.registerAudioRecordingCallback(ContextCompat.getMainExecutor(context), callback)
            r.prepare()
            r.start()
            recorder = r
            file = target
            recordingStartedAt = System.currentTimeMillis()
            true
        } catch (_: Exception) {
            r.release()
            target.delete()
            false
        }
    }

    /**
     * 停录后验证是否含可播放音频；不能确认的原件保留为草稿，不当成成功。
     */
    fun stop(): File? {
        val r = recorder ?: return null
        val target = file
        recorder = null
        file = null
        recordingStartedAt = null
        runCatching { r.unregisterAudioRecordingCallback(callback) }
        runCatching { r.stop() }
        runCatching { r.release() }
        // A failed stop may still leave playable bytes. Invalid drafts remain available for recovery.
        return target?.takeIf(::isPlayableAudio)
    }
}

internal fun isPlayableAudio(file: File): Boolean = runCatching {
    MediaMetadataRetriever().use { reader ->
        reader.setDataSource(file.absolutePath)
        reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes" &&
            (reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0) > 0
    }
}.getOrDefault(false)
