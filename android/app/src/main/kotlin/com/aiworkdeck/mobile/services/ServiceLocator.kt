package com.aiworkdeck.mobile.services

/**
 * 最小服务定位器。UploadWorker 跑在 WorkManager 自己起的进程/线程里，拿不到 Compose 那套
 * DI，只能走这个全局单例。App 启动时装配一次；装配前 Worker 直接放弃这一轮（返回成功）。
 */
object ServiceLocator {
    lateinit var store: EvidenceStore
    lateinit var backend: Backend
    lateinit var queue: UploadQueue
    lateinit var prefs: Prefs
    lateinit var archiveMoves: ArchiveMoveQueue
    lateinit var playRecharge: PlayRechargeCoordinator

    fun queueOrNull(): UploadQueue? = if (::queue.isInitialized) queue else null
}
