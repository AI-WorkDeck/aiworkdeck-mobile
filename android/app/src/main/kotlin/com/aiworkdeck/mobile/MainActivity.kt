package com.aiworkdeck.mobile

import android.os.Bundle
import android.content.Intent
import com.aiworkdeck.mobile.features.personal.PersonalWorkspaceScreen
import com.aiworkdeck.mobile.features.personal.PersonalWorkspaceState
import com.aiworkdeck.mobile.services.CalendarReminders
import androidx.compose.ui.platform.LocalContext
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.tr
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aiworkdeck.mobile.design.L10n
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.WorkdeckTheme
import com.aiworkdeck.mobile.features.auth.LoginScreen
import com.aiworkdeck.mobile.features.auth.ProjectPickerScreen
import com.aiworkdeck.mobile.features.home.HomeScreen
import com.aiworkdeck.mobile.features.workspace.WorkspaceScreen
import com.aiworkdeck.mobile.features.settings.BackupConsentScreen
import com.aiworkdeck.mobile.features.library.LibraryScreen
import com.aiworkdeck.mobile.features.library.ViewerScreen
import com.aiworkdeck.mobile.features.queue.QueueScreen
import com.aiworkdeck.mobile.features.settings.SettingsScreen
import com.aiworkdeck.mobile.features.settings.PrivacyConsentScreen
import com.aiworkdeck.contract.ContractCapabilities
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
    private var calendarEventId by mutableStateOf<String?>(null)
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); calendarEventId = intent.getStringExtra("calendarEventId") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 内容画到系统栏下面：底部系统导航栏不再是一条灰带，各屏自己按 safeDrawing 让位。
        enableEdgeToEdge()
        // 三键导航时系统默认给导航栏垫一层半透明浅色，压在深色底部栏下面成了一条灰带
        if (android.os.Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
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
        calendarEventId = intent.getStringExtra("calendarEventId")
        setContent {
            var accepted by remember { mutableStateOf(ServiceLocator.prefs.hasPrivacyConsent) }
            if (accepted) {
                LaunchedEffect(Unit) { model.bootstrap() }
                Root(model, calendarEventId)
            } else {
                CompositionLocalProvider(LocalLayoutDirection provides if (L10n.isRtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                    WorkdeckTheme(dark = false) {
                        PrivacyConsentScreen(
                            onAccept = {
                                ServiceLocator.prefs.privacyConsentVersion = ContractCapabilities.privacyPolicyVersion
                                accepted = true
                            },
                            onDecline = { finishAndRemoveTask() },
                        )
                    }
                }
            }
        }
    }
}

/** 登录后的三栏，与 iOS `PersonalWorkspaceView` 的 TabView 同序：采集为首页。 */
enum class MainTab(val labelKey: String, val icon: Int) {
    capture("workspace.capture", R.drawable.ic_tab_capture),
    calendar("personal.calendar", R.drawable.ic_tab_calendar),
    assistant("personal.assistant", R.drawable.ic_tab_assistant),
}

/**
 * 根路由：恢复会话 → 登录 → 底部三栏（采集 / 日程 / 助理），采集为首页；
 * 资料库、队列、设置、选项目等是盖在三栏之上的全屏浮层。
 *
 * 深色不是主题跟随而是功能性的：取景器与影像浏览要深色（现场看屏、不干扰夜视），
 * 登录、日程、助理等普通表单屏走浅色。
 */
@Composable
fun Root(model: AppModel, notificationEventId: String? = null) {
    val context = LocalContext.current
    val didRestore by model.didRestore.collectAsStateWithLifecycle()
    val isSignedIn by model.isSignedIn.collectAsStateWithLifecycle()
    val project by model.selectedProject.collectAsStateWithLifecycle()

    var tab by remember { mutableStateOf(MainTab.capture) }
    var overlay by remember { mutableStateOf(Overlay.None) }
    var returnOverlay by remember { mutableStateOf(Overlay.None) }
    var personalFileProject by remember { mutableStateOf<com.aiworkdeck.mobile.model.RelayProject?>(null) }
    var captureBusy by remember { mutableStateOf(false) }
    val personal = remember(isSignedIn) { if (isSignedIn) PersonalWorkspaceState() else null }
    LaunchedEffect(notificationEventId) { if (notificationEventId != null && !captureBusy) { overlay = Overlay.None; tab = MainTab.calendar } }
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
        if (!isSignedIn) { tab = MainTab.capture; overlay = Overlay.None; viewer = null; CalendarReminders.clear(context) }
        else if (!ScreenshotMode.enabled) {
            val consent = try { ServiceLocator.backend.backupConsent() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null }
            consent?.let {
                if (!it.decided) overlay = Overlay.Backup
            }
        }
    }

    // 系统栏图标颜色跟着当前屏走：取景器深色要白图标，其余浅色屏要深图标
    val darkChrome = didRestore && isSignedIn && tab == MainTab.capture && overlay == Overlay.None
    val view = androidx.compose.ui.platform.LocalView.current
    androidx.compose.runtime.SideEffect {
        val window = (view.context as? android.app.Activity)?.window ?: return@SideEffect
        androidx.core.view.WindowCompat.getInsetsController(window, view).apply {
            isAppearanceLightStatusBars = !darkChrome
            isAppearanceLightNavigationBars = !darkChrome
        }
    }
    val layoutDir = if (L10n.isRtl) LayoutDirection.Rtl else LayoutDirection.Ltr
    CompositionLocalProvider(LocalLayoutDirection provides layoutDir) {
        WorkdeckTheme(dark = darkChrome) {
            when {
                // 恢复会话前先给一张与主界面同色的空屏，避免登录页闪一下再跳走
                !didRestore -> Column(Modifier.fillMaxSize().background(Tk.L.bg)) {}
                !isSignedIn -> LoginScreen(model)
                else -> Box(Modifier.fillMaxSize()) {
                    Column(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(1f).consumeWindowInsets(WindowInsets.navigationBars)) {
                            // 取景器一直留在组合里：切到日程/助理或盖上浮层时只放掉相机，切回来模式与计时都在
                            val captureActive = tab == MainTab.capture && overlay == Overlay.None
                            Box(if (captureActive) Modifier else Modifier.clearAndSetSemantics {}) {
                                HomeScreen(model, active = captureActive, onBusy = { captureBusy = it },
                                    onOpen = { returnOverlay = Overlay.None; personalFileProject = null; overlay = it })
                            }
                            if (tab != MainTab.capture && personal != null) PersonalWorkspaceScreen(personal, tab.name, notificationEventId,
                                onOpen = { returnOverlay = Overlay.None; overlay = it },
                                onProject = { returnOverlay = Overlay.None; personalFileProject = it; overlay = Overlay.Files })
                        }
                        MainTabBar(tab, dark = tab == MainTab.capture, enabled = !captureBusy) { tab = it }
                    }
                    if (overlay == Overlay.Queue) {
                        QueueScreen(model, onClose = { overlay = returnOverlay })
                    }
                    if (overlay == Overlay.Settings) {
                        SettingsScreen(model, onClose = { overlay = returnOverlay }, onOpen = { overlay = it })
                    }
                    if (overlay == Overlay.Projects) {
                        ProjectPickerScreen(model, onClose = { overlay = returnOverlay }, onSelect = { model.selectProject(it); overlay = returnOverlay },
                            onNone = { model.captureWithoutProject(); overlay = returnOverlay },
                            onBrowse = { personalFileProject = null; overlay = Overlay.Files })
                    }
                    if (overlay == Overlay.Files) {
                        // 采集顶栏/选项目页进来是整个工作区（先落在当前项目）；日程里点项目进来只看那一个项目
                        WorkspaceScreen(model, initialProject = personalFileProject ?: project, browse = personalFileProject == null,
                            onClose = { overlay = returnOverlay }, onOpen = { returnOverlay = Overlay.None; overlay = it })
                    }
                    if (overlay == Overlay.Backup) BackupConsentScreen(onClose = { overlay = returnOverlay })
                    if (overlay == Overlay.Library) {
                        LibraryScreen(
                            model = model,
                            onOpenViewer = { items, index -> viewer = items to index },
                            onClose = { overlay = returnOverlay },
                        )
                        viewer?.let { (items, index) ->
                            ViewerScreen(items = items, start = index, onClose = { viewer = null })
                        }
                    }
                }
            }
        }
    }

    // 系统返回键按浮层的层序逐层收回；没有浮层时从日程/助理回到采集，再按才退出应用
    // 备份同意页自己管返回（未做选择不能关），这里不接
    BackHandler(enabled = isSignedIn && overlay != Overlay.Backup && (overlay != Overlay.None || tab != MainTab.capture)) {
        when {
            viewer != null -> viewer = null
            overlay != Overlay.None -> overlay = returnOverlay
            !captureBusy -> tab = MainTab.capture
        }
    }
}

/** 底部三栏。采集栏选中时用深色（与取景器连成一片），其余用浅色。 */
@Composable
private fun MainTabBar(selected: MainTab, dark: Boolean, enabled: Boolean, onSelect: (MainTab) -> Unit) {
    val bg = if (dark) Tk.D.bg else Tk.L.bg
    val on = if (dark) Tk.D.fg else Tk.L.accent
    val off = if (dark) Tk.D.fgMuted else Tk.L.fgMuted
    Column(Modifier.background(bg)) {
        HorizontalDivider(color = if (dark) Tk.D.rule else Tk.L.rule)
        NavigationBar(containerColor = bg, tonalElevation = 0.dp) {
            for (t in MainTab.entries) {
                NavigationBarItem(
                    selected = t == selected,
                    enabled = enabled || t == selected,
                    onClick = { onSelect(t) },
                    icon = { Icon(painterResource(t.icon), contentDescription = null) },
                    label = { Text(tr(t.labelKey), style = Fonts.small()) },
                    colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = on, selectedTextColor = on,
                        unselectedIconColor = off, unselectedTextColor = off,
                        indicatorColor = if (dark) Tk.D.surface else Tk.L.accentWash,
                        disabledIconColor = off.copy(alpha = 0.4f), disabledTextColor = off.copy(alpha = 0.4f),
                    ),
                )
            }
        }
    }
}
