package com.aiworkdeck.mobile.features.queue

import com.aiworkdeck.mobile.model.ArchiveMoveStatus
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.TransferState

/**
 * 队列页的五段。镜像 iOS `QueueView` 的 failed / unassigned / active / staged / landed 过滤：
 * 移动中的件算「上传中」，移动失败算「失败」；没项目的待传件单列「未归类」。纯函数，JVM 单测直接调。
 */
data class QueueSections(
    val failed: List<CaptureItem>,
    val unassigned: List<CaptureItem>,
    val active: List<CaptureItem>,
    val staged: List<CaptureItem>,
    val landed: List<CaptureItem>,
) {
    companion object {
        fun of(items: List<CaptureItem>): QueueSections {
            fun moveFailed(it: CaptureItem) = it.archiveMove?.status == ArchiveMoveStatus.failed
            return QueueSections(
                failed = items.filter { moveFailed(it) || (!it.moveBlocksMutation && it.state == TransferState.failed) },
                unassigned = items.filter { it.project == null && it.state == TransferState.waiting },
                active = items.filter {
                    !moveFailed(it) && (it.moveBlocksMutation ||
                        (it.state == TransferState.waiting && it.project != null) || it.state == TransferState.uploading)
                },
                staged = items.filter { !it.moveBlocksMutation && !moveFailed(it) && it.state == TransferState.uploaded },
                landed = items.filter { !it.moveBlocksMutation && !moveFailed(it) && it.state == TransferState.arrived },
            )
        }
    }
}
