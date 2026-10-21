package com.aiworkdeck.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.features.auth.LoginScreen
import com.aiworkdeck.mobile.features.auth.ProjectPickerScreen
import com.aiworkdeck.mobile.features.home.HomeScreen
import com.aiworkdeck.mobile.features.workspace.ProjectFilesScreen
import com.aiworkdeck.mobile.features.settings.BackupConsentScreen
import com.aiworkdeck.mobile.features.library.LibraryScreen
import com.aiworkdeck.mobile.features.library.ViewerScreen
import com.aiworkdeck.mobile.features.queue.QueueScreen
import com.aiworkdeck.mobile.features.settings.SettingsScreen
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.services.AlbumSaver
import com.aiworkdeck.mobile.services.ServiceLocator
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.logging.Logger

private val albumLogger = Logger.getLogger("AlbumScope")

/**
 * 存相册的协程作用域是进程级的：相册那一步与界面生命周期无关，Activity 没了也要把已经拍到的
 * 东西写完。失败不回滚——库里那份原件才是唯一可信的一份。
 *
 * 兜底两层（协程里漏出去的异常会直接崩进程，而相册只是锦上添花，不值得赔上一条现场记录）：
 * 作用域自带 handler 记一笔，lambda 体再各自 runCatching。
 */
private val albumScope = CoroutineScope(
    SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, e ->
        albumLogger.warning("存相册协程异常: ${e.message}")
    },
)

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 相册挂钩装在这里而不是 AppModel 里：AppModel 不认识 MediaStore，
        // 相册与上传是两条互不影响的链（是否要存由 Prefs.saveToAlbum 在 AppModel 里判定）。
        model.albumSaver = { item ->
            albumScope.launch {
                runCatching {
                    if (AlbumSaver.save(applicationContext, item.localFile, item.kind)) {
                        ServiceLocator.store.markSavedToAlbum(item.id)
                    }
                }.onFailure { albumLogger.warning("存相册失败: ${it.message}") }
            }
        }
        // 上架截图模式（debug-only，见 ScreenshotMode）。必须在 bootstrap 之前定下来。
        ScreenshotMode.configure(
            on = intent.getBooleanExtra(ScreenshotMode.EXTRA, false),
            screen = intent.getStringExtra(ScreenshotMode.EXTRA_SCREEN),
            filesDir = filesDir,
        )
        model.bootstrap()
        setContent { Root(model) }
    }
}

/**
 * 根路由：恢复会话 → 登录 → 直接采集；项目选择作为可关闭的浮层。
 *
 * 深色不是主题跟随而是功能性的：取景器与影像浏览要深色（现场看屏、不干扰夜视），
 * 登录与选项目是普通表单屏，走浅色。
 */
@Composable
fun Root(model: AppModel) {
    val didRestore by model.didRestore.collectAsStateWithLifecycle()
    val isSignedIn by model.isSignedIn.collectAsStateWithLifecycle()
    val project by model.selectedProject.collectAsStateWithLifecycle()

    var overlay by remember { mutableStateOf(Overlay.None) }
    // 全屏看大图的目标：同一天的件 + 起始下标。它盖在图集之上，图集盖在取景器之上。
    var viewer by remember { mutableStateOf<Pair<List<CaptureItem>, Int>?>(null) }

    // 上架截图：由启动参数直接落到某一屏，不靠脚本点坐标（debug-only，见 ScreenshotMode）
    val shotItems by model.currentItems.collectAsStateWithLifecycle()
    LaunchedEffect(shotItems, ScreenshotMode.screen) {
        when (ScreenshotMode.screen) {
            "queue" -> overlay = Overlay.Queue
            "library" -> overlay = Overlay.Library
            "settings" -> overlay = Overlay.Settings
            "viewer" -> {
                overlay = Overlay.Library
                val shown = shotItems.filter { it.kind != com.aiworkdeck.mobile.model.MediaKind.audio }
                if (shown.isNotEmpty() && viewer == null) viewer = shown to 0
            }
        }
    }

    LaunchedEffect(isSignedIn) {
        if (!isSignedIn) { overlay = Overlay.None; viewer = null }
        else if (!ScreenshotMode.enabled) {
            val consent = try { ServiceLocator.backend.backupConsent() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null }
            consent?.let {
                if (!it.decided) overlay = Overlay.Backup
            }
        }
    }

    val dark = didRestore && isSignedIn
    WorkdeckTheme(dark = dark) {
        when {
            // 恢复会话前先给一张与主界面同色的空屏，避免登录页闪一下再跳走
            !didRestore -> Column(Modifier.fillMaxSize().background(Tk.L.bg)) {}
            !isSignedIn -> LoginScreen(model)
            else -> {
                // 取景器一直在下面：图集是盖上去的一层，退回来时镜头还在原处，不用重新绑定
                HomeScreen(model, onOpen = { overlay = it })
                if (overlay == Overlay.Queue) {
                    QueueScreen(model, onClose = { overlay = Overlay.None })
                }
                if (overlay == Overlay.Settings) {
                    SettingsScreen(model, onClose = { overlay = Overlay.None }, onOpen = { overlay = it })
                }
                if (overlay == Overlay.Projects) {
                    ProjectPickerScreen(model, onClose = { overlay = Overlay.None }, onSelect = { model.selectProject(it); overlay = Overlay.None })
                }
                if (overlay == Overlay.Files) {
                    project?.let { ProjectFilesScreen(it, onClose = { overlay = Overlay.None }) }
                }
                if (overlay == Overlay.Backup) BackupConsentScreen(onClose = { overlay = Overlay.None })
                if (overlay == Overlay.Library) {
                    LibraryScreen(
                        model = model,
                        onOpenViewer = { items, index -> viewer = items to index },
                        onClose = { overlay = Overlay.None },
                    )
                    viewer?.let { (items, index) ->
                        ViewerScreen(items = items, start = index, onClose = { viewer = null })
                    }
                }
            }
        }
    }

    // 系统返回键按浮层的层序逐层收回，不是一下退出应用
    BackHandler(enabled = overlay != Overlay.None) {
        if (viewer != null) viewer = null else overlay = Overlay.None
    }
}
