package com.aiworkdeck.mobile.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.aiworkdeck.mobile.ScreenshotMode
import com.aiworkdeck.mobile.design.tr
import kotlinx.coroutines.CancellationException

/**
 * WorkManager 驱动的上传任务。约束联网才跑；唯一名 "upload" 去重排队——
 * 拍摄再快，也不会同时起两个上传任务互相抢文件。真正的上传逻辑都在 UploadQueue，
 * 这里只负责把它从后台唤醒，能举通知就顺带举一个。
 */
class UploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (!ServiceLocator.prefs.hasPrivacyConsent) return Result.success()
        // API 31+ 后台不许启动前台服务：拿不到通知就不举，上传照跑
        //（API<31 的 expedited 路径由 WorkManager 自己调 getForegroundInfo）
        try { setForeground(getForegroundInfo()) }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { /* WorkManager may still run without foreground promotion. */ }
        val queue = ServiceLocator.queueOrNull() ?: return Result.success()
        // 失败件按退避重排本来是 AppModel 那个 60 秒心跳的活，可应用真退到后台后进程会被冻结，
        // 心跳走不到下一轮——后台还醒着的只有这个 Worker，所以这一步得它来做。断网时拍的件
        // 落库当场就试过一次并落到 failed，联网后靠 kick() 是捞不回来的（kick 只认 waiting）。
        queue.autoKick()
        while (true) {
            // 会话失效：交给前台登出，别对每件打一次 401
            if (queue.lastUnauthorized != null) return Result.success()
            if (queue.kick(waitForCurrent = true) != KickResult.hasMoreWaiting) break
            // 失败退避已经排到了将来，这一轮别再硬冲——留给下次 enqueue 或 autoKick。
            if (System.currentTimeMillis() < queue.nextAutoKickAt) break
        }
        // 还有没传完的（待传，或还在退避里等重排的失败件）说明这一轮是被打断的：交回
        // WorkManager 按它的退避重排。次数封顶免得长期无网时无限重排。
        val unfinished = queue.hasWaiting() || queue.hasRetryableFailed()
        return if (unfinished && runAttemptCount < 8) Result.retry() else Result.success()
    }

    override suspend fun getForegroundInfo(): ForegroundInfo {
        ensureChannel(applicationContext)
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle(tr("notify.uploading"))
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .build()
        return ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    companion object {
        private const val CHANNEL_ID = "upload"
        private const val NOTIFICATION_ID = 1

        /** 唯一名去重：已经排队/在跑的一份就够了，新的一份直接让位（KEEP）。 */
        fun enqueue(context: Context) {
            // 截图模式下队列里摆的是灌进去的假件，一上传就会被打成 failed，那正是要拍的三段状态
            if (ScreenshotMode.enabled) return
            val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            val request = OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(constraints)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("upload", ExistingWorkPolicy.KEEP, request)
        }

        /** 幂等：渠道已存在时再建一次只会更新名字（界面语言跟着区域换了，系统设置里的渠道名也跟着换）。 */
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            val channel = NotificationChannel(
                CHANNEL_ID, tr("notify.channel.upload"), NotificationManager.IMPORTANCE_LOW,
            )
            manager.createNotificationChannel(channel)
        }
    }
}
