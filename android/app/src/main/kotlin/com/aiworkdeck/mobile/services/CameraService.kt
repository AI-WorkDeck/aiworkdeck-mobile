package com.aiworkdeck.mobile.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import java.util.UUID
import java.util.concurrent.Executor
import java.util.logging.Logger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 相机会话。镜像 iOS `CameraService`：照片走 [ImageCapture] JPEG 直出、录像走 [Recorder] 出 MP4，
 * 两者都落到 cacheDir 的临时文件，由 `AppModel.store` 接手搬进证据库。
 *
 * **不做二次编码、不改 EXIF**：照片的 SHA-256 要证明的是「相机吐出来的那一份」没被动过，
 * 中间任何一次重新压缩都会让哈希与「原始采集」这四个字脱钩（决策 D3，与 iOS 同）。
 *
 * 状态用 Compose 的 `mutableStateOf`：这层本来就只有取景器一个消费者，
 * 多套一层 StateFlow 只是把同一个值搬来搬去。
 */
class CameraService(private val context: Context, private val lifecycleOwner: LifecycleOwner) {
    enum class Mode { photo, video }

    var isRecording by mutableStateOf(false)
        private set

    /** 录制开始的墙钟时刻。计时由界面按秒自己算，服务层不养定时器。 */
    var recordingStartedAt by mutableStateOf<Long?>(null)
        private set

    var isPaused by mutableStateOf(false)
        private set
    var transitionPending by mutableStateOf(false)
        private set
    var elapsedMs by mutableStateOf(0L)
        private set

    private val executor: Executor = ContextCompat.getMainExecutor(context)
    private val preview = Preview.Builder().build()
    private val imageCapture = ImageCapture.Builder()
        .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
        .build()
    private val videoCapture = VideoCapture.withOutput(
        Recorder.Builder()
            .setQualitySelector(QualitySelector.from(Quality.HD, FallbackStrategy.higherQualityOrLowerThan(Quality.SD)))
            .build(),
    )

    private val logger = Logger.getLogger("CameraService")
    private var provider: ProcessCameraProvider? = null
    private var recording: Recording? = null
    private var finalized: CompletableDeferred<File>? = null
    /** 当前是否占着相机。[unbind] 幂等靠它，重复调用不再空转一次 unbindAll。 */
    private var bound = false
    /** 三个用例一起绑成功了没有。绑成了就切模式不用重绑，取景不会黑一下。 */
    private var boundAll = false
    private var boundMode: Mode? = null

    /**
     * 绑到取景视图。先试「预览+拍照+录像」三个用例一起绑：切模式无需重绑，画面不闪。
     * 低端机绑不下三个用例（CameraX 会抛），退回按模式各绑两个——宁可切模式黑一下，
     * 也不能因为一次绑定失败就没有相机。
     */
    suspend fun bind(view: PreviewView, mode: Mode) {
        val p = provider ?: awaitProvider().also { provider = it }
        preview.surfaceProvider = view.surfaceProvider
        // 解绑过就得重绑（录音模式回来、界面重进），所以先看 bound 再看模式
        if (bound && (boundAll || boundMode == mode)) return
        val selector = CameraSelector.DEFAULT_BACK_CAMERA
        try {
            p.unbindAll()
            p.bindToLifecycle(lifecycleOwner, selector, preview, imageCapture, videoCapture)
            boundAll = true
        } catch (_: Exception) {
            p.unbindAll()
            val second: UseCase = if (mode == Mode.photo) imageCapture else videoCapture
            p.bindToLifecycle(lifecycleOwner, selector, preview, second)
            boundAll = false
        }
        bound = true
        boundMode = mode
    }

    fun updateRotation(rotation: Int) {
        imageCapture.targetRotation = rotation
        videoCapture.targetRotation = rotation
    }

    /** 放开相机。幂等：没占着就直接返回，重复调用不会多解绑一次。 */
    fun unbind() {
        if (!bound) return
        provider?.unbindAll()
        bound = false
        boundAll = false
        boundMode = null
        logger.info("相机已解绑")
    }

    /** 拍一张。返回 cacheDir 里的 JPEG 原件，调用方负责搬走。 */
    suspend fun takePhoto(): File = suspendCancellableCoroutine { cont ->
        val file = File(context.cacheDir, "cap-${UUID.randomUUID()}.jpg")
        val options = ImageCapture.OutputFileOptions.Builder(file).build()
        imageCapture.takePicture(options, executor, object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(result: ImageCapture.OutputFileResults) {
                if (cont.isActive) cont.resume(file)
            }

            override fun onError(e: ImageCaptureException) {
                file.delete()
                if (cont.isActive) cont.resumeWithException(e)
            }
        })
    }

    /**
     * 开始录像。没有录音权限也照录（只是没声），不因为少一项权限就把画面也拒了——
     * 现场画面本身就是证据。
     */
    fun startVideo(onFinalized: (File) -> Unit) {
        if (recording != null) return
        val file = File(context.cacheDir, "cap-${UUID.randomUUID()}.mp4")
        val done = CompletableDeferred<File>()
        finalized = done
        var pending = videoCapture.output.prepareRecording(context, FileOutputOptions.Builder(file).build())
        if (granted(Manifest.permission.RECORD_AUDIO)) pending = pending.withAudioEnabled()
        isRecording = true
        isPaused = false
        elapsedMs = 0
        transitionPending = false
        recordingStartedAt = System.currentTimeMillis()
        recording = pending.start(executor) { event ->
            elapsedMs = event.recordingStats.recordedDurationNanos / 1_000_000
            when (event) {
                is VideoRecordEvent.Pause -> { isPaused = true; transitionPending = false }
                is VideoRecordEvent.Resume -> { isPaused = false; transitionPending = false }
                is VideoRecordEvent.Start -> {
                    isRecording = true
                    recordingStartedAt = System.currentTimeMillis()
                }
                is VideoRecordEvent.Finalize -> {
                    isRecording = false
                    isPaused = false
                    transitionPending = false
                    recordingStartedAt = null
                    recording = null
                    // 出错也先看文件：退后台会以 ERROR_SOURCE_INACTIVE 收尾，但已录的部分是完好的，
                    // 现场不可复现，能留多少留多少。
                    if (file.exists() && file.length() > 0) {
                        done.complete(file)
                        onFinalized(file)
                    } else {
                        file.delete()
                        done.completeExceptionally(IllegalStateException("video finalize error ${event.error}"))
                    }
                }
                else -> Unit
            }
        }
    }

    fun pauseVideo(): Boolean {
        val active = recording ?: return false
        if (transitionPending || isPaused) return false
        return try { active.pause(); transitionPending = true; true } catch (_: Exception) { false }
    }

    fun resumeVideo(): Boolean {
        val active = recording ?: return false
        if (transitionPending || !isPaused) return false
        return try { active.resume(); transitionPending = true; true } catch (_: Exception) { false }
    }

    /** 停止录像并等落盘完成。收尾在 Finalize 事件里，stop() 返回时文件还没写完。 */
    suspend fun stopVideo(): File {
        val done = finalized ?: throw IllegalStateException("no recording in progress")
        recording?.stop()
        recording = null
        return try { done.await() } finally { finalized = null }
    }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private suspend fun awaitProvider(): ProcessCameraProvider = suspendCancellableCoroutine { cont ->
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                if (cont.isActive) cont.resume(future.get())
            } catch (e: Exception) {
                if (cont.isActive) cont.resumeWithException(e)
            }
        }, executor)
    }
}
