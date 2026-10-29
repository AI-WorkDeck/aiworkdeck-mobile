package com.aiworkdeck.mobile.features.home

import androidx.browser.customtabs.CustomTabsIntent
import com.aiworkdeck.contract.ContractCapabilities
import com.aiworkdeck.mobile.services.ServiceLocator
import com.aiworkdeck.mobile.services.AccountRegion
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.aiworkdeck.mobile.AppModel
import com.aiworkdeck.mobile.BuildConfig
import com.aiworkdeck.mobile.Overlay
import com.aiworkdeck.mobile.ScreenshotMode
import com.aiworkdeck.mobile.design.Fonts
import com.aiworkdeck.mobile.design.Hairline
import com.aiworkdeck.mobile.design.StatusDot
import com.aiworkdeck.mobile.design.TallyRow
import com.aiworkdeck.mobile.design.Tk
import com.aiworkdeck.mobile.design.tr
import com.aiworkdeck.mobile.model.CaptureItem
import com.aiworkdeck.mobile.model.MediaKind
import com.aiworkdeck.mobile.model.TransferTally
import com.aiworkdeck.mobile.services.CameraService
import com.aiworkdeck.mobile.services.Loc
import com.aiworkdeck.mobile.services.LocationStamper
import com.aiworkdeck.mobile.services.RecordingService
import com.aiworkdeck.mobile.services.RecordingState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

/** 三档采集模式。录音走前台服务 [RecordingService]，不经过相机会话——麦克风不需要点亮摄像头。 */
private enum class CapMode { photo, video, audio }

/**
 * 首页 = 取景器。现场是单手、光线差、要快，所以进来就是镜头，不再隔一层「按转盘进取景页」。
 * 信息各归其位：业务归属在顶部，画面在中间（淡水印叠加），快门与模式在拇指够得到的下方。
 * 镜像 iOS `HomeView`。
 *
 * 水印只叠加在取景与展示层，**不烧录进照片字节**（决策 D3，见 [Watermark]）。
 */
@Composable
fun HomeScreen(model: AppModel, onOpen: (Overlay) -> Unit) {
    val context = LocalContext.current
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val landscape = configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    val project by model.selectedProject.collectAsStateWithLifecycle()
    val items by model.currentItems.collectAsStateWithLifecycle()
    val tally by model.tally.collectAsStateWithLifecycle()
    val desktopOnline by model.desktopOnline.collectAsStateWithLifecycle()

    val camera = remember { CameraService(context, lifecycleOwner) }
    val stamper = remember { LocationStamper(context) }
    val previewView = remember { PreviewView(context) }

    var mode by remember { mutableStateOf(if (RecordingState.isRecording) CapMode.audio else CapMode.photo) }
    var loc by remember { mutableStateOf(if (ScreenshotMode.enabled) ScreenshotMode.loc else null) }
    var now by remember { mutableStateOf(Instant.now()) }
    var flash by remember { mutableStateOf(false) }
    var pauseError by remember { mutableStateOf<String?>(null) }
    var cameraError by remember { mutableStateOf(false) }
    var cameraRetry by remember { mutableStateOf(0) }

    var hasCamera by remember { mutableStateOf(granted(context, Manifest.permission.CAMERA)) }
    var hasMic by remember { mutableStateOf(granted(context, Manifest.permission.RECORD_AUDIO)) }
    var hasLocation by remember { mutableStateOf(locationGranted(context)) }

    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        hasCamera = granted(context, Manifest.permission.CAMERA)
        hasMic = granted(context, Manifest.permission.RECORD_AUDIO)
        hasLocation = locationGranted(context)
    }

    // Only request the permission needed by the selected capture mode. Location is opt-in below.
    LaunchedEffect(mode) {
        val permission = if (mode == CapMode.audio) Manifest.permission.RECORD_AUDIO else Manifest.permission.CAMERA
        if (!granted(context, permission)) ask.launch(arrayOf(permission))
    }
    LaunchedEffect(mode, hasCamera) {
        if (mode == CapMode.video && hasCamera && !hasMic) ask.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
    }
    var afterNotificationPermission by remember { mutableStateOf<(() -> Unit)?>(null) }
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        afterNotificationPermission?.invoke()
        afterNotificationPermission = null
    }
    fun requestLocation() {
        ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
    }

    // 水印的秒针与录制计时共用这一个心跳
    LaunchedEffect(Unit) {
        while (true) {
            now = Instant.now()
            delay(1_000)
        }
    }

    // 定位每 10 秒续一次，按快门时直接取最近一次的结果：现场按下快门到落库不能等 GPS。
    // 拿不到新定位就留着上一次的，不清空——上一次的坐标仍然说明「在这栋楼」。
    LaunchedEffect(hasLocation) {
        if (ScreenshotMode.enabled) return@LaunchedEffect
        if (!hasLocation) loc = null
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (hasLocation) {
                stamper.current()?.let { loc = it }
                delay(10_000)
            }
        }
    }

    LaunchedEffect(RecordingState.isRecording) {
        if (RecordingState.isRecording) mode = CapMode.audio
    }

    LaunchedEffect(configuration.orientation) {
        androidx.compose.runtime.withFrameNanos { }
        previewView.display?.let { camera.updateRotation(it.rotation) }
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                if (RecordingState.isRecording) RecordingState.backgroundAlertsUnavailable = !RecordingService.canSendReminder(context)
                hasCamera = granted(context, Manifest.permission.CAMERA)
                hasMic = granted(context, Manifest.permission.RECORD_AUDIO)
                hasLocation = locationGranted(context)
                cameraRetry++
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(mode, hasCamera, cameraRetry) {
        // 截图模式下取景区贴的是静态照，PreviewView 根本没挂进树，绑相机只会白烧一次会话
        if (ScreenshotMode.stage != null) return@LaunchedEffect
        if (!hasCamera) return@LaunchedEffect
        if (mode == CapMode.audio) camera.unbind()
        else {
            cameraError = false
            try { camera.bind(previewView, if (mode == CapMode.photo) CameraService.Mode.photo else CameraService.Mode.video) }
            catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (_: Exception) { cameraError = true }
        }
    }

    // 落库一律走 ViewModel 的作用域而不是 rememberCoroutineScope：退出登录、切项目会把这一屏
    // 整个换掉，组合作用域随之取消——正在写盘的那一件不能因为界面没了就丢。
    val storeScope = model.viewModelScope

    // 采集时刻取「开始」而不是「按停」：取证语义上什么时候开始录比什么时候按停重要（iOS 同）。
    // 项目也在这里就定死：落库是异步的，中途用户去设置页切了项目，这一件该记的仍是
    // 按下快门时屏幕上显示的那个项目。
    fun stopVideoAndStore() {
        storeScope.launch { runCatching { camera.stopVideo() } }
    }

    /**
     * 在录的录像停下并落库。退后台与这一屏被换掉走的是同一条路。
     * 只管录像：录音由前台服务 [RecordingService] 承担，退后台、换屏都不停（dev-board#405）。
     */
    fun stopRecordingAndStore() {
        if (camera.isRecording) stopVideoAndStore()
    }

    // 录像到一半退到后台：停表并落库，不丢已录的内容——现场不可复现。
    // 相机会话本身跟着 lifecycle 自动解绑，这里要的是把那段已经写好的文件收进库。
    // 录音不在此列：它跟着前台服务走，锁屏、切别的应用都继续录。
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event != Lifecycle.Event.ON_STOP) return@LifecycleEventObserver
            stopRecordingAndStore()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // 这一屏被换掉（退出登录、切项目回到选项目页）时相机不跟着 Activity 生命周期走，
    // 得自己放开，否则镜头一直亮着、别的应用也拿不到相机。先收在录的那一段再解绑。
    DisposableEffect(camera) {
        onDispose {
            stopRecordingAndStore()
            camera.unbind()
        }
    }

    fun shoot() {
        if (RecordingState.isRecording) { RecordingService.stop(context); return }
        when (mode) {
            CapMode.photo -> {
                if (!hasCamera) { ask.launch(arrayOf(Manifest.permission.CAMERA)); return }
                val at = Instant.now()
                val target = project
                flash = true
                storeScope.launch { runCatching { model.store(MediaKind.photo, camera.takePhoto(), at, loc, target) } }
                scope.launch { delay(120); flash = false }
            }
            CapMode.video -> if (camera.isRecording) stopVideoAndStore() else {
                if (!hasCamera) { ask.launch(arrayOf(Manifest.permission.CAMERA)); return }
                val at = Instant.now(); val target = project; val location = loc
                camera.startVideo { file ->
                    storeScope.launch { runCatching { model.store(MediaKind.video, file, at, location, target) } }
                }
            }
            CapMode.audio -> when {
                RecordingState.isRecording -> RecordingService.stop(context)
                !granted(context, Manifest.permission.RECORD_AUDIO) -> ask.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
                else -> RecordingService.start(context, project, loc)
            }
        }
    }

    fun shootWithNotificationPermission() {
        val needsNotification = !RecordingState.isRecording && !camera.isRecording &&
            (mode == CapMode.audio || project != null)
        if (needsNotification && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !granted(context, Manifest.permission.POST_NOTIFICATIONS) && !ServiceLocator.prefs.notificationPermissionAsked) {
            ServiceLocator.prefs.notificationPermissionAsked = true
            afterNotificationPermission = ::shoot
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else shoot()
    }

    androidx.compose.runtime.LaunchedEffect(RecordingState.message) { if (RecordingState.message != null) mode = CapMode.audio }

    val recording = camera.isRecording || RecordingState.isRecording
    val paused = if (camera.isRecording) camera.isPaused else RecordingState.isPaused
    val elapsed = (if (camera.isRecording) camera.elapsedMs else RecordingState.elapsedMs) / 1000
    if (RecordingState.silenceConfirmation && RecordingState.isRecording && !RecordingState.isPaused) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = {},
            title = { Text(tr("rec.silence.title")) },
            text = { Text(tr("rec.silence.message")) },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { RecordingService.stop(context) }) { Text(tr("rec.silence.stop")) } },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { RecordingService.keepRecording(context) }) { Text(tr("rec.silence.continue")) } },
        )
    }

    Column(Modifier.fillMaxSize().background(Tk.D.bg).safeDrawingPadding()) {
        Row {
            androidx.compose.material3.TextButton(onClick = { onOpen(Overlay.Projects) }, enabled = !camera.isRecording) { Text(project?.name ?: tr("library.unknownProject"), color = Tk.D.fg) }
            androidx.compose.material3.TextButton(onClick = { onOpen(Overlay.Personal) }, enabled = !camera.isRecording) { Text(tr("personal.assistant"), color = Tk.D.fg) }
            if (project != null) androidx.compose.material3.TextButton(onClick = { onOpen(Overlay.Files) }, enabled = !camera.isRecording) { Text(tr("workspace.files"), color = Tk.D.fg) }
            if (BuildConfig.FLAVOR == "cn" && ServiceLocator.prefs.accountRegion == AccountRegion.cn) androidx.compose.material3.TextButton(
                onClick = { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, android.net.Uri.parse(ContractCapabilities.ddClientPortalUrl)) },
                enabled = !camera.isRecording && !RecordingState.isRecording,
            ) { Text(tr("dd.title"), color = Tk.D.fg) }
            if (landscape) androidx.compose.material3.TextButton(onClick = { onOpen(Overlay.Settings) }) { Text(tr("home.settings"), color = Tk.D.fg) }
        }
        if (!landscape) Header(
            projectName = project?.name.orEmpty(),
            loc = loc,
            hasLocation = hasLocation,
            tally = tally,
            onOpenQueue = { onOpen(Overlay.Queue) },
            onOpenSettings = { onOpen(Overlay.Settings) },
            onRequestLocation = ::requestLocation,
        )

        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = Tk.Sp.s2)
                .background(Color.Black).border(1.dp, Tk.D.rule),
            contentAlignment = Alignment.Center,
        ) {
            when {
                mode == CapMode.audio -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    AudioStage(hasMic, RecordingState.isRecording, RecordingState.isPaused, elapsed, context)
                    if (RecordingState.isRecording && RecordingState.backgroundAlertsUnavailable) Text(tr("rec.silence.backgroundUnavailable"), color = Color.White, modifier = Modifier.padding(Tk.Sp.s3))
                    if (RecordingState.analysisUnavailable) Text(tr("rec.silence.unavailable"), color = Color.White, modifier = Modifier.padding(Tk.Sp.s3))
                    RecordingState.message?.let { message ->
                        Text(message, color = Color.White, modifier = Modifier.padding(Tk.Sp.s3)
                            .clickable { onOpen(Overlay.Library) })
                        if (!RecordingState.isRecording) androidx.compose.material3.TextButton(onClick = { model.retryRecordingDrafts() }, enabled = !RecordingState.isSaving) {
                            Text(tr("rec.retrySave"), color = Tk.D.fg)
                        }
                    }
                }
                !hasCamera -> PermissionStage(tr("home.permission.camera"), context)
                cameraError -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(tr("camera.error.start"), color = Tk.D.fg)
                    androidx.compose.material3.TextButton(onClick = { cameraRetry++ }) { Text(tr("project.retry"), color = Tk.D.fg) }
                }
                // 截图模式：模拟器没有相机，取景区贴一张静态现场照，水印照常叠上去
                ScreenshotMode.stage != null -> {
                    AsyncImage(
                        model = ScreenshotMode.stage,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                    Watermark(
                        now = ScreenshotMode.stamp(now), projectName = project?.name.orEmpty(), loc = loc,
                        modifier = Modifier.align(Alignment.BottomStart).padding(Tk.Sp.s3),
                    )
                }
                else -> {
                    CameraPreview(previewView, Modifier.fillMaxSize())
                    Watermark(
                        now = now, projectName = project?.name.orEmpty(), loc = loc,
                        modifier = Modifier.align(Alignment.BottomStart).padding(Tk.Sp.s3),
                    )
                }
            }
            // 快门白闪：唯一的「拍到了」即时反馈，比任何提示都快
            if (flash) Box(Modifier.fillMaxSize().background(Color.White))
        }

        if (recording) {
            if (paused) Text(tr("rec.pause.remember"), color = Color.White, modifier = Modifier.fillMaxWidth().background(Tk.S.failed).padding(Tk.Sp.s2), textAlign = TextAlign.Center)
            pauseError?.let { Text(it, color = Color.White, modifier = Modifier.padding(Tk.Sp.s2)) }
            Row(Modifier.fillMaxWidth()) {
            androidx.compose.material3.TextButton(
                onClick = {
                    pauseError = null
                    if (camera.isRecording) {
                        val success = if (paused) camera.resumeVideo() else camera.pauseVideo()
                        if (!success) pauseError = tr(if (paused) "rec.resume.videoFailed" else "rec.pause.failed")
                    } else if (paused) RecordingService.resume(context) else RecordingService.pause(context)
                },
                enabled = !camera.transitionPending,
                modifier = Modifier.weight(1f),
            ) {
                Text(tr(if (paused) { if (camera.isRecording) "rec.resume.video" else "rec.resume.audio" } else { if (camera.isRecording) "rec.pause.video" else "rec.pause.audio" }), color = Color.White)
            }
            androidx.compose.material3.TextButton(onClick = ::shoot, modifier = Modifier.weight(1f)) { Text(tr("rec.silence.stop"), color = Color.White) }
            }
        }
        Controls(
            mode = mode,
            onMode = { mode = it },
            recording = recording,
            paused = paused,
            recordingVideo = camera.isRecording,
            elapsed = elapsed,
            recent = items.firstOrNull(),
            total = tally.total,
            desktopOnline = desktopOnline,
            assigned = project != null,
            onShoot = ::shootWithNotificationPermission,
            onOpenLibrary = { onOpen(Overlay.Library) },
            onOpenQueue = { onOpen(Overlay.Queue) },
        )
    }
}

// MARK: - 顶部信息

@Composable
private fun Header(
    projectName: String,
    loc: Loc?,
    hasLocation: Boolean,
    tally: TransferTally,
    onOpenQueue: () -> Unit,
    onOpenSettings: () -> Unit,
    onRequestLocation: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.gutter, vertical = Tk.Sp.s2),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s1),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                tr("home.eyebrow").uppercase(), style = Fonts.nano(),
                color = Color.White.copy(alpha = 0.45f), modifier = Modifier.weight(1f),
            )
            // 位置精度：没有精度的坐标在质证时说明不了问题，所以直接显示出来
            Row(modifier = Modifier.heightIn(min = Tk.touchMin).clickable(onClick = onRequestLocation), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(
                    Modifier.size(5.dp).clip(CircleShape)
                        .background(if (loc == null) Color.White.copy(alpha = 0.3f) else Tk.S.arrivedOnDark),
                )
                Text(if (hasLocation) WatermarkFormat.chip(loc) else tr("home.location.enable"), style = Fonts.mono(Tk.Ty.nano), color = Color.White.copy(alpha = 0.6f))
            }
            Text(
                tr("home.settings").uppercase(), style = Fonts.nano(), color = Color.White.copy(alpha = 0.55f),
                modifier = Modifier.padding(start = Tk.Sp.s3).heightIn(min = Tk.touchMin)
                    .clickable(onClick = onOpenSettings).wrapContentHeight(),
            )
        }

        Text(projectName.ifEmpty { tr("library.unknownProject") }, style = Fonts.title(), color = Tk.D.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            if (projectName.isEmpty()) tr("workspace.unassignedHint") else tr(
                "home.archiveTo",
                mapOf("path" to tr("archive.path", mapOf("date" to ScreenshotMode.archiveDate()))),
            ),
            style = Fonts.nano(), color = Color.White.copy(alpha = 0.4f),
        )
        Box(Modifier.fillMaxWidth().heightIn(min = 28.dp).clickable(onClick = onOpenQueue), contentAlignment = Alignment.CenterStart) {
            TallyRow(tally, onDark = true)
        }
    }
}

// MARK: - 舞台

/** 录音模式没有取景画面：深色底，等宽计时器就是全部的界面。 */
@Composable
private fun AudioStage(hasMic: Boolean, recording: Boolean, paused: Boolean, elapsed: Long, context: Context) {
    if (!hasMic) {
        PermissionStage(tr("home.permission.mic"), context)
        return
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3)) {
        Text(WatermarkFormat.duration(elapsed), style = Fonts.hero(), color = Color.White)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s2)) {
            if (recording) Box(Modifier.size(7.dp).clip(CircleShape).background(Tk.S.failed))
            Text(
                (if (paused) tr("rec.pause.status") else if (recording) tr("home.recording.audio") else tr("home.audio.hint")).uppercase(),
                style = Fonts.nano(), color = Color.White.copy(alpha = 0.55f),
            )
        }
        // 录音中说一句「退后台也在录」：用户开会时最怕的就是切出去一下就断了
        if (recording && !paused) Text(tr("home.audio.backgroundOk"), style = Fonts.nano(), color = Color.White.copy(alpha = 0.35f))
    }
}

/** 权限缺失：说清楚缺什么，给一个能直接去开的入口。不在这里重复系统的措辞。 */
@Composable
private fun PermissionStage(title: String, context: Context) {
    Column(
        Modifier.padding(Tk.Sp.s8),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
    ) {
        Text(title, style = Fonts.heading(), color = Color.White, textAlign = TextAlign.Center)
        Text(
            tr("home.permission.open"), style = Fonts.small(), color = Tk.S.movingOnDark,
            modifier = Modifier.heightIn(min = Tk.touchMin).clickable { openAppSettings(context) }.wrapContentHeight(),
        )
    }
}

// MARK: - 底部控制

@Composable
private fun Controls(
    mode: CapMode,
    onMode: (CapMode) -> Unit,
    recording: Boolean,
    paused: Boolean,
    recordingVideo: Boolean,
    elapsed: Long,
    recent: CaptureItem?,
    total: Int,
    desktopOnline: Boolean,
    assigned: Boolean,
    onShoot: () -> Unit,
    onOpenLibrary: () -> Unit,
    onOpenQueue: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Tk.Sp.gutter).padding(top = Tk.Sp.s3, bottom = Tk.Sp.s2),
        verticalArrangement = Arrangement.spacedBy(Tk.Sp.s3),
    ) {
        if (recording) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 28.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1, Alignment.CenterHorizontally),
            ) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(Tk.S.failed))
                Text(WatermarkFormat.duration(elapsed), style = Fonts.mono(Tk.Ty.small), color = Color.White)
                Text(
                    (if (paused) tr("rec.pause.status") else if (recordingVideo) tr("home.recording.video") else tr("home.recording.audio")).uppercase(),
                    style = Fonts.nano(), color = Color.White.copy(alpha = 0.55f),
                )
            }
        } else {
            // 三档并排、点选切换。取证的模式必须显式可预期，不做横滑模式条，也不做快门手势
            // 切换——手滑录错模式是取证事故。
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s8, Alignment.CenterHorizontally),
            ) {
                ModeButton(tr("home.mode.photo"), mode == CapMode.photo) { onMode(CapMode.photo) }
                ModeButton(tr("home.mode.video"), mode == CapMode.video) { onMode(CapMode.video) }
                ModeButton(tr("home.mode.audio"), mode == CapMode.audio) { onMode(CapMode.audio) }
            }
        }

        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                RecentThumb(recent, onOpenLibrary)
            }
            Shutter(mode, recording, onShoot)
            Column(
                Modifier.weight(1f).clickable(onClick = onOpenQueue),
                horizontalAlignment = Alignment.End,
            ) {
                Text(total.toString(), style = Fonts.mono(Tk.Ty.heading), color = Color.White)
                Text(tr("home.counter.project").uppercase(), style = Fonts.nano(), color = Color.White.copy(alpha = 0.5f))
            }
        }

        Hairline(color = Tk.D.rule)

        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tk.Sp.s1)) {
            Box(
                Modifier.size(5.dp).clip(CircleShape)
                    .background(if (desktopOnline) Tk.S.arrivedOnDark else Color.White.copy(alpha = 0.3f)),
            )
            Text(
                (if (!assigned) tr("workspace.unassignedHint") else if (desktopOnline) tr("home.desktop.online") else tr("home.desktop.offline")).uppercase(),
                style = Fonts.nano(), color = Color.White.copy(alpha = 0.5f),
            )
        }
    }
}

@Composable
private fun ModeButton(label: String, selected: Boolean, onClick: () -> Unit) {
    Column(
        Modifier.width(Tk.touchMin).heightIn(min = Tk.touchMin).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        Text(
            label, style = Fonts.small(),
            color = if (selected) Color.White else Color.White.copy(alpha = 0.45f),
        )
        Box(
            Modifier.size(3.dp).clip(CircleShape)
                .background(if (selected) Color.White else Color.Transparent),
        )
    }
}

/** 快门。照片单击即拍；录像/录音单击切换开始与停止，录制中变红方块。 */
@Composable
private fun Shutter(mode: CapMode, recording: Boolean, onClick: () -> Unit) {
    val label = when {
        recording && mode == CapMode.video -> tr("home.shutter.stopVideo")
        recording -> tr("home.shutter.stopAudio")
        mode == CapMode.photo -> tr("home.shutter.photo")
        mode == CapMode.video -> tr("home.shutter.startVideo")
        else -> tr("home.shutter.startAudio")
    }
    Box(
        Modifier.size(74.dp).clip(CircleShape).border(2.dp, Color.White.copy(alpha = 0.9f), CircleShape)
            .clickable(onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        if (recording) {
            Box(Modifier.size(30.dp).clip(RoundedCornerShape(5.dp)).background(Tk.S.failed))
        } else {
            Box(
                Modifier.size(60.dp).clip(CircleShape)
                    .background(if (mode == CapMode.photo) Color.White else Tk.S.failed),
            )
        }
    }
}

/** 最近一件的真缩略图，也是影像浏览的入口。 */
@Composable
private fun RecentThumb(item: CaptureItem?, onClick: () -> Unit) {
    Box(Modifier.size(Tk.touchMin).clickable(onClick = onClick)) {
        when {
            item == null -> Box(Modifier.fillMaxSize().border(1.dp, Tk.D.rule))
            item.kind == MediaKind.audio -> Box(
                Modifier.fillMaxSize().background(Tk.D.surface),
                contentAlignment = Alignment.Center,
            ) { Text("♪", style = Fonts.body(), color = Color.White.copy(alpha = 0.6f)) }
            else -> AsyncImage(
                model = item.localFile,
                contentDescription = tr("home.thumb"),
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
        item?.let { StatusDot(it.state, onDark = true, size = 4.dp, modifier = Modifier.align(Alignment.TopStart).padding(3.dp)) }
    }
}

private fun granted(context: Context, permission: String): Boolean =
    context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

private fun openAppSettings(context: Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { context.startActivity(intent) }
}

private fun locationGranted(context: Context): Boolean =
    granted(context, Manifest.permission.ACCESS_FINE_LOCATION) || granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)
