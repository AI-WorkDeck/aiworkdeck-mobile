package com.aiworkdeck.mobile

import android.app.Application
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.video.VideoFrameDecoder
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.Backend
import com.aiworkdeck.mobile.services.BackendUploader
import com.aiworkdeck.mobile.services.EvidenceStore
import com.aiworkdeck.mobile.services.Prefs
import com.aiworkdeck.mobile.services.RecordingService
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.SessionStores
import com.aiworkdeck.mobile.services.UploadQueue
import com.aiworkdeck.mobile.services.UploadWorker
import com.aiworkdeck.mobile.services.deviceFacts
import java.io.File

/**
 * 进程级装配。这里只搭线、不发请求——冷启动第一屏是取景器，任何网络等待都要往后放
 * （真正的恢复与心跳在 [AppModel.bootstrap]）。
 *
 * 装配放在 Application 而不是 Activity：UploadWorker 由 WorkManager 唤起，Activity 可能
 * 根本没起来，队列却必须能用。
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        val prefs = Prefs(this, AccountRegion.ofDefault(BuildConfig.DEFAULT_REGION))
        val store = EvidenceStore(File(filesDir, "FieldEvidence"), deviceFacts())
        // 主机跟着账号区域现取，不在这里定死：登录页换区后同一个 Backend 下一个请求就打新主机
        val backend = Backend(
            baseUrlProvider = { prefs.accountRegion.baseUrl },
            session = SessionStores.create(this),
            languageProvider = { L10n.wireCode },
            accountActive = { prefs.hasPrivacyConsent },
        )
        // 界面语言跟随已存偏好或区域；要在任何一屏、任何通知渠道建出来之前定好
        L10n.applyPreference(prefs.appLocale, prefs.accountRegion)
        ServiceLocator.prefs = prefs
        ServiceLocator.store = store
        ServiceLocator.backend = backend
        ServiceLocator.queue = UploadQueue(
            store = store,
            uploader = BackendUploader(backend) { prefs.deviceId },
        )
        // 通知渠道先建好：Worker 要举前台通知，渠道不存在时通知不显示，任务会被系统当作
        // 无前台的长任务掐掉。
        UploadWorker.ensureChannel(this)
        RecordingService.ensureChannel(this)
        // 缩略图：录像要抽首帧，Coil 默认的解码器组里没有视频解码器，装一次给全局用
        SingletonImageLoader.setSafe { ctx ->
            ImageLoader.Builder(ctx).components { add(VideoFrameDecoder.Factory()) }.build()
        }
    }
}
