package com.aiworkdeck.mobile.model

import com.aiworkdeck.mobile.design.tr
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.security.MessageDigest

/** 已上传件改投到另一个项目的远端事务状态。镜像 iOS `ArchiveMove.Status`。 */
@Serializable
enum class ArchiveMoveStatus {
    @SerialName("WAITING_TARGET") waitingTarget,
    @SerialName("WAITING_SOURCE") waitingSource,
    @SerialName("DONE") done,
    @SerialName("FAILED") failed;

    val caption: String get() = when (this) {
        waitingTarget -> tr("queue.moveWaitingTarget")
        waitingSource -> tr("queue.moveWaitingSource")
        failed -> tr("queue.moveFailed")
        done -> TransferState.arrived.caption
    }
}

/**
 * 本机证据身份永不改变；这里的 ID 只描述远端那次移动。镜像 iOS `ArchiveMove`。
 * 账号凭据不落盘，只记账号绑定（[accountBinding]）——换了账号就不能续跑别人的事务。
 */
@Serializable
data class ArchiveMove(
    val requestId: String,
    val sourceClientMediaId: String,
    val targetClientMediaId: String,
    val source: RelayProject,
    val target: RelayProject,
    val sha256: String,
    val fileSize: Long,
    val accountBinding: String,
    val registered: Boolean = false,
    val targetUploaded: Boolean = false,
    val status: ArchiveMoveStatus = ArchiveMoveStatus.waitingTarget,
    val lastError: String? = null,
    val retryRequested: Boolean = false,
    /** 只有服务端明确的 MOVE_NOT_REGISTERED 拒绝才解锁一次失败的登记。 */
    val registrationRejected: Boolean = false,
) {
    val blocksMutation: Boolean get() = status != ArchiveMoveStatus.done && !registrationRejected
}

@Serializable
data class ArchiveMoveReply(
    val requestId: String,
    val status: ArchiveMoveStatus,
    val targetClientMediaId: String,
    val error: String? = null,
)

/** 每一轮冻结的凭据；从不写进 manifest。 */
data class ArchiveMoveAccount(val binding: String, val baseUrl: String, val sessionId: String) {
    companion object {
        /** 与 iOS WatchAccountScope 同式：账号绑定按「区域 + 用户 ID」算，跨会话轮换稳定。 */
        fun binding(baseUrl: String, userId: Long): String = hash("$baseUrl|user:$userId")
        fun sessionFingerprint(baseUrl: String, sessionId: String): String = hash("$baseUrl|$sessionId")
        private fun hash(value: String): String =
            MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}

class ArchiveMoveRegistrationRejected(message: String) : Exception(message)

/** ArchiveMoveQueue 依赖的远端接口；单测用假实现顶替 Backend。 */
interface ArchiveMoveService {
    suspend fun registerMove(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply
    suspend fun moveStatus(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply
    suspend fun retryMove(move: ArchiveMove, account: ArchiveMoveAccount): ArchiveMoveReply
    suspend fun uploadMoveTarget(item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount)
}
