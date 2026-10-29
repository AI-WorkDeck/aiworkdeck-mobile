package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.TransferEvent
import com.aiworkdeck.mobile.model.TransferState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import java.io.IOException

/** kick() 的结果：单飞占用中 / 处理完但还有可处理的 waiting 件（失败退避后待续）/ 处理完且暂无更多可传件。 */
enum class KickResult { done, hasMoreWaiting, alreadyRunning }

/**
 * 上传队列。镜像 iOS UploadQueue（ios/Sources/Services/UploadQueue.swift）：
 * 串行、单飞、失败落盘不吞、退避不硬重试。区别只在于纯 JVM、无 actor，靠 Mutex 单飞。
 *
 * 状态推进全部经 EvidenceStore 落盘——进程被杀、App 被切走再回来，队列能从磁盘恢复，
 * 不依赖内存里的任何东西（除了退避计时与 attempts 计数，这两样 iOS 同样不落盘）。
 *
 * 所有公开挂起函数在 Dispatchers.IO 上执行，调用方无需切换（读库、算哈希、传文件都是阻塞
 * 活儿，跑在主线程上会卡住取景器）。
 */
class UploadQueue(
    private val store: EvidenceStore,
    private val uploader: Uploader,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()

    /** 失败次数计数，纯内存、不落盘（EvidenceStore 的 lastError 只留最近一条原因，推不出次数）。*/
    private val attempts = mutableMapOf<String, Int>()

    /** 失败退避：首败 60 秒，逐次翻倍，封顶 15 分钟；一旦传成即复位。 */
    private var backoffSeconds = 60L

    var nextAutoKickAt: Long = 0L
        private set

    /** 队列里最近一次遇到 401：AppModel 据此触发登出/重登，本类不碰 UI、不弹提示。 */
    var lastUnauthorized: String? = null
        private set

    /**
     * 取走并清掉「队列撞过 401」的标记。AppModel 每轮心跳消费一次——不清掉的话，
     * 重新登录之后还会被上一次的旧标记再踢出去一次。
     */
    fun consumeUnauthorized(): Boolean {
        val hit = lastUnauthorized != null
        lastUnauthorized = null
        return hit
    }

    private val _progress = MutableStateFlow<Map<String, Double>>(emptyMap())
    val progress: StateFlow<Map<String, Double>> = _progress.asStateFlow()

    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    /** UI calls stay single-flight; a Worker waits cancellably so its foreground service covers the active upload. */
    suspend fun kick(waitForCurrent: Boolean = false): KickResult = withContext(Dispatchers.IO) {
        if (waitForCurrent) mutex.lock()
        else if (!mutex.tryLock()) return@withContext KickResult.alreadyRunning
        try {
            recoverStale()
            while (true) {
                val item = nextPending() ?: break
                val ok = uploadOne(item)
                if (!ok) break
            }
            if (hasActionableWaiting()) KickResult.hasMoreWaiting else KickResult.done
        } finally {
            mutex.unlock()
        }
    }

    /** 还有没有能传的待传件。UploadWorker 据此决定这一轮要不要 Result.retry()。 */
    suspend fun hasWaiting(): Boolean = withContext(Dispatchers.IO) { hasActionableWaiting() }

    /** 还有没有等着退避到期自动重排的失败件——对 Worker 来说同样算「这一轮没干完」。 */
    suspend fun hasRetryableFailed(): Boolean = withContext(Dispatchers.IO) {
        store.loadAll().any { it.state == TransferState.failed && it.project != null }
    }

    /** 周期性自愈：滞留/待传直接续跑；失败按退避到期才自动重排，不到期就什么也不做。 */
    suspend fun autoKick() = withContext(Dispatchers.IO) {
        if (mutex.isLocked) return@withContext
        val items = store.loadAll()
        val hasFailed = items.any { it.state == TransferState.failed }
        val hasWork = items.any { it.state == TransferState.waiting || it.state == TransferState.uploading }
        if (hasFailed && clock() >= nextAutoKickAt) {
            autoRetryFailed()
            return@withContext
        }
        if (hasWork) kick()
    }

    /** 把失败的重新排回待传。用户手动点「重试」时调用，不看退避、不看次数。 */
    suspend fun retryFailed() = withContext(Dispatchers.IO) {
        val failed = store.loadAll().filter { it.state == TransferState.failed }
        for (f in failed) store.updateState(f.id, TransferState.waiting, progress = 0.0)
        if (failed.isNotEmpty()) _changes.tryEmit(Unit)
        kick()
        Unit
    }

    /**
     * 对停在中转区的影像查投递回执。查询失败静默返回——回执只是状态汇报，不该产生任何打扰。
     * 返回未投递件的中转区到期时刻（键 clientMediaId 小写），队列页拿去做到期提醒。
     */
    suspend fun checkDelivered(): Map<String, String> = withContext(Dispatchers.IO) {
        val uploaded = store.loadAll().filter { it.state == TransferState.uploaded }
        if (uploaded.isEmpty()) return@withContext emptyMap()
        val expiry = mutableMapOf<String, String>()
        var changed = false
        for (batch in uploaded.chunked(50)) {
            val ids = batch.map { it.manifest.clientMediaId }
            val statuses = try { uploader.mediaStatus(ids) } catch (_: Exception) { continue }
            val byId = statuses.associateBy { it.clientMediaId.lowercase() }
            for (item in batch) {
                val key = item.manifest.clientMediaId.lowercase()
                val st = byId[key] ?: continue
                val merged = item.state.applyingStatus(st.delivered, st.waitingSeconds, st.expiresAt)
                if (merged.state != item.state) {
                    store.updateState(item.id, merged.state, progress = 1.0)
                    changed = true
                }
                merged.expiresAt?.let { expiry[key] = it }
            }
        }
        if (changed) _changes.tryEmit(Unit)
        expiry
    }

    /** 滞留的「传输中」= 上一次进程死在上传半路。串行队列走到这里没有任何在途上传，
     * 所以此刻所有 uploading 都是尸体——复位回 waiting 重传，幂等键（clientMediaId）
     * 保证服务端不产生重复件（dev-board#241 的 Android 对应）。 */
    private suspend fun recoverStale() {
        val stale = store.loadAll().filter { it.state == TransferState.uploading }
        for (s in stale) store.updateState(s.id, s.state.recovered())
        if (stale.isNotEmpty()) _changes.tryEmit(Unit)
    }

    /** 目标项目按件走；没记项目的件跳过（Android 无兜底 project，等旧记录被用户手动归类）。
     * 先传最早拍的：loadAll 按拍摄时间降序，取最后一个即最早。 */
    private suspend fun nextPending(): CaptureItem? =
        store.loadAll().filter { it.state == TransferState.waiting && it.project != null }.lastOrNull()

    private suspend fun hasActionableWaiting(): Boolean =
        store.loadAll().any { it.state == TransferState.waiting && it.project != null }

    /** 一件的上传。成功 true；失败/未授权 false——调用方据此 break，弱网下不把后面几条也挤掉。 */
    private suspend fun uploadOne(item: CaptureItem): Boolean {
        val project = item.project ?: return false
        store.updateState(item.id, TransferState.uploading, progress = 0.0)
        setProgress(item.id, 0.0)
        _changes.tryEmit(Unit)
        return try {
            val fileName = UploadNaming.fileName(item)
            uploader.upload(item, project, fileName) { p -> setProgress(item.id, p) }
            // 进了中转区 ≠ 到了电脑：真正的 arrived 由 checkDelivered 按回执改
            store.updateState(item.id, TransferState.uploaded, progress = 1.0)
            attempts.remove(item.id)
            backoffSeconds = 60
            clearProgress(item.id)
            _changes.tryEmit(Unit)
            true
        } catch (e: Unauthorized) {
            lastUnauthorized = e.message
            recordFailure(item.id, e.message, backoff = false)
            false
        } catch (e: IOException) {
            recordFailure(item.id, e.message, backoff = true)
            false
        } catch (e: Exception) {
            recordFailure(item.id, e.message, backoff = true)
            false
        }
    }

    /** 原因照实落盘——队列页要显示「为什么失败」，光一个红点用户没法自救。 */
    private suspend fun recordFailure(id: String, message: String?, backoff: Boolean) {
        attempts[id] = (attempts[id] ?: 0) + 1
        store.updateState(id, TransferState.failed, error = message)
        clearProgress(id)
        if (backoff) {
            nextAutoKickAt = clock() + backoffSeconds * 1000
            backoffSeconds = (backoffSeconds * 2).coerceAtMost(900)
        }
        _changes.tryEmit(Unit)
    }

    /** 自动重排：走契约的 retry_auto 事件与 guard（attempts <= maxAutoRetries），
     * 超过次数的件留在 failed，等用户手动 retryFailed()。 */
    private suspend fun autoRetryFailed() {
        val failed = store.loadAll().filter { it.state == TransferState.failed }
        var any = false
        for (f in failed) {
            val n = attempts[f.id] ?: 0
            if (f.state.next(TransferEvent.retryAuto, n) == TransferState.waiting) {
                store.updateState(f.id, TransferState.waiting, progress = 0.0)
                any = true
            }
        }
        if (any) _changes.tryEmit(Unit)
        kick()
    }

    private fun setProgress(id: String, value: Double) { _progress.value = _progress.value + (id to value) }
    private fun clearProgress(id: String) { _progress.value = _progress.value - id }
}
