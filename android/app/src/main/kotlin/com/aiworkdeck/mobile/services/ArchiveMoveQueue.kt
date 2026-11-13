package com.aiworkdeck.mobile.services

import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.ArchiveMove
import com.aiworkdeck.mobile.model.ArchiveMoveAccount
import com.aiworkdeck.mobile.model.ArchiveMoveRegistrationRejected
import com.aiworkdeck.mobile.model.ArchiveMoveReply
import com.aiworkdeck.mobile.model.ArchiveMoveService
import com.aiworkdeck.mobile.model.ArchiveMoveStatus
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.RelayProject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 已上传件改投项目的远端事务。镜像 iOS `ArchiveMoveQueue`（ios/Sources/Services/ArchiveMoveQueue.swift）：
 * 网络结果不明时续跑**同一个**落盘事务；目标端的投递回执本身从不授权本地改项目——只认服务端的 DONE。
 *
 * 单飞：跑着时再踢一脚只记一个「再跑一轮」。每一步之前都核对账号没换，换了就停手不写盘。
 */
class ArchiveMoveQueue(
    private val store: EvidenceStore,
    private val service: ArchiveMoveService,
    private val currentAccount: () -> ArchiveMoveAccount?,
) {
    /** 落盘状态变了就通知一声，界面据此重读。 */
    var onChange: (suspend () -> Unit)? = null

    private val lock = Any()
    private var running = false
    private var runAgain = false

    suspend fun begin(id: String, target: RelayProject) {
        val account = currentAccount() ?: throw ApiError(1, tr("queue.moveAccountChanged"))
        store.beginArchiveMove(id, target, account.binding) { currentAccount() == account }
        onChange?.invoke()
    }

    /** 用户显式重试：同一个 requestId 再走一遍（中转过期后可能要重传目标）。 */
    suspend fun retry(id: String) {
        val account = currentAccount()
        val move = store.archiveMoveItem(id)?.archiveMove
        if (account == null || move == null || move.accountBinding != account.binding) throw ApiError(1, tr("queue.moveAccountChanged"))
        store.updateArchiveMove(id, move.requestId, { currentAccount() == account }) {
            it.copy(retryRequested = true, registrationRejected = false, lastError = null)
        }
        onChange?.invoke()
    }

    suspend fun kick() = withContext(Dispatchers.IO) {
        synchronized(lock) {
            if (running) { runAgain = true; return@withContext }
            running = true
            runAgain = false
        }
        try {
            while (true) {
                round()
                synchronized(lock) {
                    if (!runAgain) { running = false; return@withContext }
                    runAgain = false
                }
            }
        } finally {
            synchronized(lock) { running = false }
        }
    }

    private suspend fun round() {
        val account = currentAccount() ?: return
        for (item in store.loadAll()) {
            if (currentAccount() != account) return
            val move = item.archiveMove ?: continue
            if (move.accountBinding != account.binding || move.status == ArchiveMoveStatus.done || move.registrationRejected ||
                (move.status == ArchiveMoveStatus.failed && !move.retryRequested)) continue
            advance(item, move, account)
        }
    }

    private suspend fun advance(item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount) {
        val isCurrent = { currentAccount() == account }
        try {
            if (!isCurrent()) return
            val reply: ArchiveMoveReply = when {
                // 登记必须先于上传，包括登记回复丢了之后
                !move.registered -> service.registerMove(move, account)
                move.retryRequested -> service.retryMove(move, account)
                else -> service.moveStatus(move, account)
            }
            if (!isCurrent()) return
            store.applyArchiveMoveReply(item.id, move.requestId, reply, isCurrent)
            onChange?.invoke()
            if (!isCurrent()) return
            val latest = store.archiveMoveItem(item.id) ?: return
            val pending = latest.archiveMove ?: return
            if (pending.requestId != move.requestId || pending.status != ArchiveMoveStatus.waitingTarget || pending.targetUploaded) return
            if (!latest.localFile.exists()) throw ApiError(1, tr("queue.copyMissing"))
            if (store.sha256(latest.localFile) != pending.sha256) throw ApiError(1, tr("queue.copyCorrupt"))
            if (!isCurrent()) return
            service.uploadMoveTarget(latest, pending, account)
            if (!isCurrent()) return
            store.updateArchiveMove(item.id, move.requestId, isCurrent) { it.copy(targetUploaded = true, lastError = null) }
            onChange?.invoke()
            if (!isCurrent()) return
            val status = service.moveStatus(pending, account)
            if (!isCurrent()) return
            store.applyArchiveMoveReply(item.id, move.requestId, status, isCurrent)
            onChange?.invoke()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!isCurrent()) return
            val message = if (e is ArchiveMoveRegistrationRejected) e.message ?: tr("queue.moveUnavailable")
                else userFacingMessage(e, tr("queue.moveUnavailable"))
            val rejected = !move.registered && e is ArchiveMoveRegistrationRejected
            runCatching {
                store.updateArchiveMove(item.id, move.requestId, isCurrent) {
                    if (rejected) it.copy(lastError = message, registrationRejected = true, status = ArchiveMoveStatus.failed, retryRequested = false)
                    else it.copy(lastError = message)
                }
            }
            onChange?.invoke()
        }
    }
}
