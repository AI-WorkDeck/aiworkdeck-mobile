package com.aiworkdeck.mobile

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.WorkManager
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.RelayProject
import com.aiworkdeck.mobile.model.TransferState
import com.aiworkdeck.mobile.model.TransferTally
import com.aiworkdeck.mobile.services.AccountRegion
import com.aiworkdeck.mobile.services.AccountUser
import com.aiworkdeck.mobile.services.switchAccountRegion
import com.aiworkdeck.mobile.services.BillingBalance
import com.aiworkdeck.mobile.services.Loc
import com.aiworkdeck.mobile.services.LoginResult
import com.aiworkdeck.mobile.services.MediaUsage
import com.aiworkdeck.mobile.services.RecordingState
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.Unauthorized
import com.aiworkdeck.mobile.services.UploadWorker
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.util.logging.Logger

/** 主界面之上盖着的整屏。None = 只有取景器。 */
enum class Overlay { None, Library, Queue, Settings }

/**
 * 全局状态。界面只读它，写入一律经过这里，保证磁盘上的库与屏幕上的画面不会各说各话。
 * 镜像 iOS `AppModel`（ios/Sources/App/AppModel.swift），差别只在 Flow 与 ViewModel 的形制。
 *
 * 依赖从 [ServiceLocator] 取而不是构造参数注入：UploadWorker 也走同一份实例，两边必须是
 * 同一个队列、同一份库，否则会出现「界面显示待传、Worker 说没活干」。
 */
class AppModel(app: Application) : AndroidViewModel(app) {
    private val logger = Logger.getLogger("AppModel")
    private val evidence = ServiceLocator.store
    private val backend = ServiceLocator.backend
    private val queue = ServiceLocator.queue
    private val prefs = ServiceLocator.prefs

    private val _didRestore = MutableStateFlow(false)
    /** 恢复会话与项目之前不画任何一屏，免得登录页闪一下再跳走。 */
    val didRestore: StateFlow<Boolean> = _didRestore.asStateFlow()

    private val _isSignedIn = MutableStateFlow(false)
    val isSignedIn: StateFlow<Boolean> = _isSignedIn.asStateFlow()

    private val _account = MutableStateFlow<AccountUser?>(null)
    /** 本次登录拿到的账号。冷启动只恢复会话不恢复账号（那要多打一次网络），所以可能为 null。 */
    val account: StateFlow<AccountUser?> = _account.asStateFlow()

    private val _selectedProject = MutableStateFlow<RelayProject?>(null)
    val selectedProject: StateFlow<RelayProject?> = _selectedProject.asStateFlow()

    private val _items = MutableStateFlow<List<CaptureItem>>(emptyList())
    /** 全部影像，跨项目。图集切项目、队列页数「别处还有多少」都要看全量。 */
    val items: StateFlow<List<CaptureItem>> = _items.asStateFlow()

    private val _currentItems = MutableStateFlow<List<CaptureItem>>(emptyList())
    val currentItems: StateFlow<List<CaptureItem>> = _currentItems.asStateFlow()

    private val _tally = MutableStateFlow(TransferTally.zero)
    /** 三段计数只数当前项目——进度跟着项目走。 */
    val tally: StateFlow<TransferTally> = _tally.asStateFlow()

    private val _otherPendingCount = MutableStateFlow(0)
    val otherPendingCount: StateFlow<Int> = _otherPendingCount.asStateFlow()

    private val _cloudExpiry = MutableStateFlow<Map<String, String>>(emptyMap())
    /** 未投递件的中转区到期时刻（键 clientMediaId 小写）。队列页做到期提醒用。 */
    val cloudExpiry: StateFlow<Map<String, String>> = _cloudExpiry.asStateFlow()

    private val _desktopOnline = MutableStateFlow(false)
    val desktopOnline: StateFlow<Boolean> = _desktopOnline.asStateFlow()

    val uploadProgress: StateFlow<Map<String, Double>> = queue.progress

    /**
     * 存相册的挂钩，由相机层（Task 8）装上。AppModel 不直接依赖 MediaStore：
     * 相册与上传是两条互不影响的链，任何一条断了另一条都要继续走。
     */
    var albumSaver: ((CaptureItem) -> Unit)? = null

    private var lastProjectsSeenAt: Long? = null
    private var heartbeat: Job? = null

    init {
        // 录音由前台服务落库（用户可能从通知栏按停，界面未必活着），库变了这里跟着重读
        viewModelScope.launch { RecordingState.stored.collect { refresh() } }
    }

    // MARK: - 启动

    fun bootstrap() {
        viewModelScope.launch {
            // 上架截图模式：不碰网络、不起上传，只把界面摆到「已登录 + 桌面端在线」这一格。
            // 影像与当前项目由 capture 脚本灌进应用私有目录，这里照常从磁盘读。
            if (ScreenshotMode.enabled) {
                _isSignedIn.value = true
                _account.value = ScreenshotMode.account
                _selectedProject.value = prefs.selectedProject
                _desktopOnline.value = true
                refresh()
                _didRestore.value = true
                return@launch
            }
            // 本地有会话就直接进主界面。这里只判断「有没有」，会话是否还有效交给第一次真实
            // 请求的 401——启动多打一次网络请求会让离线开 App 卡住，而离线拍照正是主场景。
            _isSignedIn.value = backend.hasSession()
            _selectedProject.value = prefs.selectedProject
            evidence.sweepOrphans()
            refresh()
            _didRestore.value = true
            if (_selectedProject.value != null) {
                UploadWorker.enqueue(getApplication<Application>())
                _cloudExpiry.value = queue.checkDelivered()
                refresh()
            }
            startHeartbeat()
        }
    }

    /**
     * 上传自愈心跳（dev-board#241 的 Android 对应）：滞留的「传输中」与失败件不能等用户来点，
     * 现场拍完手机就揣兜里了。顺带刷新桌面端在线判定与投递回执。
     */
    private fun startHeartbeat() {
        if (heartbeat?.isActive == true) return
        heartbeat = viewModelScope.launch {
            while (isActive) {
                delay(60_000)
                if (!_isSignedIn.value) continue
                queue.autoKick()
                _cloudExpiry.value = queue.checkDelivered()
                refreshDesktopOnline()
                refresh()
                if (queue.consumeUnauthorized()) signOut()
            }
        }
    }

    /** 统一目录长期保留项目；在线状态只认来源位置的真实心跳。 */
    private suspend fun refreshDesktopOnline() {
        val current = _selectedProject.value ?: return
        try {
            val projects = backend.myProjects()
            lastProjectsSeenAt = if (projects.any { project -> project.locations.orEmpty().any {
                it.kind == "desktop" && it.deviceId == current.deviceId && it.online == true
            } }) System.currentTimeMillis() else null
        } catch (e: Unauthorized) {
            signOut()
            return
        } catch (_: Exception) {
            // 读不到不等于对面不在——网络抖一下就宣布离线是噪音，交给三分钟窗口自己过期
        }
        _desktopOnline.value = isDesktopOnline(lastProjectsSeenAt, System.currentTimeMillis())
    }

    // MARK: - 账号与项目

    fun didLogin(result: LoginResult) {
        _account.value = result.user
        _isSignedIn.value = true
        startHeartbeat()
        viewModelScope.launch { refresh() }
    }

    fun selectProject(project: RelayProject) {
        prefs.selectedProject = project
        _selectedProject.value = project
        val online = project.locations.orEmpty().any { it.kind == "desktop" && it.deviceId == project.deviceId && it.online == true }
        lastProjectsSeenAt = if (online) System.currentTimeMillis() else null
        _desktopOnline.value = online
        viewModelScope.launch {
            refresh()
            UploadWorker.enqueue(getApplication<Application>())
            queue.kick()
        }
    }

    /**
     * 登录页翻区域（只在未登录态）。除了偏好里的项目，内存里恢复出来的当前项目也一并清掉：
     * 本地有项目、会话却没了的情况下 bootstrap 会把它读进来，不清的话登进另一站会直接落到它上面。
     */
    fun switchAccountRegion(): AccountRegion {
        val next = switchAccountRegion(prefs)
        _selectedProject.value = null
        _desktopOnline.value = false
        lastProjectsSeenAt = null
        viewModelScope.launch { refresh() }
        return next
    }

    /** 切项目：清掉选择回到选择页。已拍的影像各自记着自己的项目，切项目不改变它们的去向。 */
    fun clearProjectSelection() {
        prefs.selectedProject = null
        _selectedProject.value = null
        _desktopOnline.value = false
        viewModelScope.launch { refresh() }
    }

    /**
     * 退出登录。**不清本地影像**——退出不等于放弃已经拍到的东西，现场是不可复现的，
     * 登出就删是灾难性的默认。
     */
    fun signOut() {
        backend.logout()
        heartbeat?.cancel()
        heartbeat = null
        // 排着的上传任务也撤掉：会话没了再被唤起只会对着每一件打一次 401
        runCatching { WorkManager.getInstance(getApplication()).cancelUniqueWork("upload") }
        _isSignedIn.value = false
        _account.value = null
        prefs.selectedProject = null
        _selectedProject.value = null
        _desktopOnline.value = false
        lastProjectsSeenAt = null
        viewModelScope.launch { refresh() }
    }

    /**
     * 注销账号。删的是**云端**的账号与数据；手机本地的影像不动——理由同 [signOut]。
     * App Store 审核指南 5.1.1(v) 与各安卓应用商店的账号删除要求都指向这个入口。
     */
    suspend fun deleteAccount() {
        backend.deleteAccount()
        signOut()
    }

    /** 云端中转区用量。设置页进页面拉一次；失败让调用方自己决定怎么显示（那里用「—」占位）。 */
    suspend fun mediaUsage(): MediaUsage = backend.mediaUsage()

    /** 统一账户余额。同样交调用方决定失败态怎么显示（读不到 vs 未关联账户）。 */
    suspend fun billingBalance(): BillingBalance = backend.billingBalance()

    // MARK: - 影像

    /**
     * 落一件。顺序是「先进库、再存相册、最后排上传」：库是唯一可信的那一份，
     * 相册与上传都从它派生，任何一条失败都不该回滚已经落好的原件。
     */
    suspend fun store(
        kind: MediaKind,
        tempFile: File,
        capturedAt: Instant,
        loc: Loc?,
        project: RelayProject? = selectedProject.value,
    ): CaptureItem {
        val item = evidence.save(kind, tempFile, capturedAt, loc, project)
        refresh()
        if (prefs.saveToAlbum && kind != MediaKind.audio) albumSaver?.invoke(item)
        UploadWorker.enqueue(getApplication<Application>())
        viewModelScope.launch { queue.kick() }
        return item
    }

    /** 单件重试。队列页每行都有，不用为了一条失败去点「全部重试」。 */
    fun retry(id: String) {
        viewModelScope.launch {
            try {
                evidence.updateState(id, TransferState.waiting, progress = 0.0)
                refresh()
                UploadWorker.enqueue(getApplication<Application>())
                queue.kick()
            } catch (e: Exception) {
                logger.warning("重试 $id 出错: ${e.message}")
            }
        }
    }

    fun retryFailedUploads() {
        viewModelScope.launch {
            try {
                queue.retryFailed()
                refresh()
            } catch (e: Exception) {
                logger.warning("全部重试出错: ${e.message}")
            }
        }
    }

    fun checkDelivered() {
        viewModelScope.launch {
            _cloudExpiry.value = queue.checkDelivered()
            refresh()
        }
    }

    fun delete(ids: Set<String>) {
        viewModelScope.launch {
            try {
                evidence.delete(ids)
                refresh()
            } catch (e: Exception) {
                logger.warning("删除出错: ${e.message}")
            }
        }
    }

    /** 从磁盘重读一遍并派生出各个视图值。读不出来不清空界面——宁可显示上一次的状态。 */
    suspend fun refresh() {
        val all = try { evidence.loadAll() } catch (_: Exception) { return }
        val selected = _selectedProject.value
        _items.value = all
        _currentItems.value = all.filter { if (selected == null) it.project == null else it.project?.matches(selected) == true }
        _tally.value = TransferTally.of(_currentItems.value)
        _otherPendingCount.value = otherPendingCount(all, selected)
    }
}
