package com.aiworkdeck.mobile.services

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * 录音的进程级状态。录音由前台服务 [RecordingService] 承担（退后台、锁屏都继续），
 * 界面与服务不在同一个生命周期里，只能隔着这个单例说话：
 *
 * - 界面读 [isRecording] / [startedAt]（Compose 可观察）画计时；
 * - 界面开录前把项目与位置快照放进 [request]，服务起来后 [takeRequest] 取走——不走 Intent extras，
 *   `RelayProject` / `Loc` 不用再做一遍序列化；
 * - 服务落库后向 [stored] 发一件，`AppModel` 收到后重读库。
 *
 * 状态迁移（[begin] / [finish] / [takeRequest]）是纯函数，可以在 JVM 单测里直接跑。
 */
object RecordingState {
    data class StartRequest(val project: RelayProject?, val loc: Loc?)

    var isPaused by mutableStateOf(false)
        private set
    var elapsedMs by mutableStateOf(0L)
    var silenceConfirmation by mutableStateOf(false)
    var analysisUnavailable by mutableStateOf(false)
    var backgroundAlertsUnavailable by mutableStateOf(false)

    var isSaving by mutableStateOf(false)
    var message by mutableStateOf<String?>(null)

    var isRecording by mutableStateOf(false)
        private set

    /** 录制开始的墙钟时刻（毫秒）。落库用的采集时刻也取它——「什么时候开始录」比「什么时候按停」重要。 */
    var startedAt by mutableStateOf<Long?>(null)
        private set

    /** 下一次开录要用的参数。由界面写、服务取，取走即清空。 */
    @Volatile var request: StartRequest? = null

    /** 服务落库完成后发出的那一件。没有订阅者时直接丢弃：下次 `bootstrap` 反正会重读库。 */
    val stored = MutableSharedFlow<CaptureItem>()

    fun begin(startedAt: Long) {
        message = null
        isPaused = false
        elapsedMs = 0
        silenceConfirmation = false
        analysisUnavailable = false
        backgroundAlertsUnavailable = false
        this.startedAt = startedAt
        isRecording = true
    }

    fun applyPaused(value: Boolean) {
        if (!isRecording) return
        isPaused = value
        silenceConfirmation = false
    }

    fun finish() {
        isRecording = false
        isPaused = false
        elapsedMs = 0
        silenceConfirmation = false
        analysisUnavailable = false
        backgroundAlertsUnavailable = false
        startedAt = null
    }

    /** 取走并清空开录参数：同一份参数只能开一次录。 */
    fun takeRequest(): StartRequest? {
        val r = request
        request = null
        return r
    }
}
