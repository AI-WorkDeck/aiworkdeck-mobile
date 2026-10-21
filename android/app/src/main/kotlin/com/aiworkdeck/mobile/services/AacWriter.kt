package com.aiworkdeck.mobile.services

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteOrder

/** Streaming AAC/M4A writer: PCM never goes to disk; timestamps exclude paused samples. */
internal class AacWriter(target: File) {
    private val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private var muxer: MediaMuxer? = null
    private var track = -1
    private var samples = 0L
    private val info = MediaCodec.BufferInfo()

    init {
        try {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
            }
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            muxer = MediaMuxer(target.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (error: Exception) {
            runCatching { encoder.release() }
            throw error
        }
    }

    fun write(pcm: ShortArray, count: Int) {
        var offset = 0
        while (offset < count) {
            drain(false)
            val index = encoder.dequeueInputBuffer(100_000)
            check(index >= 0) { "AAC input timeout" }
            val buffer = checkNotNull(encoder.getInputBuffer(index)).apply { clear(); order(ByteOrder.LITTLE_ENDIAN) }
            val length = minOf(count - offset, buffer.remaining() / 2)
            check(length > 0)
            for (i in offset until offset + length) buffer.putShort(pcm[i])
            encoder.queueInputBuffer(index, 0, length * 2, samples * 1_000_000 / SAMPLE_RATE, 0)
            samples += length
            offset += length
        }
        drain(false)
    }

    fun finish() {
        try {
            drain(false)
            val index = encoder.dequeueInputBuffer(100_000)
            check(index >= 0) { "AAC end timeout" }
            encoder.queueInputBuffer(index, 0, 0, samples * 1_000_000 / SAMPLE_RATE, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            drain(true)
        } finally {
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
            if (track >= 0) runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
        }
    }

    private fun drain(end: Boolean) {
        var emptyReads = 0
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, if (end) 100_000 else 0)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    check(track < 0)
                    track = checkNotNull(muxer).addTrack(encoder.outputFormat)
                    muxer?.start()
                }
                index >= 0 -> {
                    try {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            check(track >= 0)
                            muxer?.writeSampleData(track, checkNotNull(encoder.getOutputBuffer(index)), info)
                        }
                    } finally { encoder.releaseOutputBuffer(index, false) }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    emptyReads = 0
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!end) return
                    check(++emptyReads < 20) { "AAC finalization timeout" }
                }
            }
        }
    }

    companion object { const val SAMPLE_RATE = 48_000 }
}
