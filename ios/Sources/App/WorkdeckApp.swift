import SwiftUI

@main
struct WorkdeckApp: App {
    @State private var model = AppModel()

    init() {
        // 锁屏卡片 / 灵动岛的「停止录音」在主进程执行，落到录音单例。
        // 顺带在启动时就把单例建起来：它的 init 会收掉上次进程遗留的 Live Activity。
        let recorder = AudioRecorderService.shared
        StopRecordingIntent.handler = { await recorder.stop() }
        // 界面语言跟账号区域走（dev-board#837）：大陆版中文、海外版英文，不跟设备语言。
        // 存量用户没有区域键 → 缺省大陆版 → 中文，与升级前一致。
        L10n.apply(region: .current)
        WatchPhoneBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                // 内购的双通道重放（design §4）：挂上 Transaction.updates 听进程外完成的交易，
                // 再补一次 Transaction.unfinished——钱已经付了、上次没入成账的就躺在那里。
                // 两件事都放在这个 .task 里：起监听写进 App 的属性初始化式会被 SwiftUI 反复执行，
                // 起出无数个监听把主线程拖死在启动屏（见 IAP.startObservingUpdates 的注释）。
                .task {
                    IAP.startObservingUpdates()
                    await IAP.replayUnfinished()
                }
        }
    }
}

private struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let recorder = AudioRecorderService.shared
    @State private var showingProjects = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.didRestore {
                // 恢复会话前先给一张与主界面同色的空屏，避免登录页闪一下再跳走
                Color(T.L.bg).ignoresSafeArea()
            } else if isScreenshotting {
                // 上架截图：用启动参数直接落到第 n 屏，不靠坐标点击一层层点进去
                screenshotStage
            } else if recordingTest {
                CaptureFlowView(onClose: {}).environment(model)
            } else if !model.isSignedIn {
                // 外壳浅色。取景首页与影像浏览自己强制深色，不跟随系统——
                // 那两处的深色是功能性的，不是主题偏好。
                LoginView().environment(model)
                    .preferredColorScheme(.light)
            } else if showingProjects {
                WorkspaceView().environment(model)
            } else {
                CaptureFlowView(onClose: { showingProjects = true }).environment(model)
            }
        }
        .task(id: "\(model.accountGeneration)-\(model.didRestore)-\(model.isSignedIn)") {
            if model.didRestore { await model.refreshBackupConsent() }
        }
        .sheet(isPresented: Binding(get: { model.showBackupPrompt }, set: { model.showBackupPrompt = $0 })) {
            BackupConsentView().environment(model)
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            showingProjects = false
        }
        .alert(tr("rec.notice.title"), isPresented: Binding(
            get: { recorder.notice != nil },
            set: { if !$0 { recorder.dismissNotice() } }
        )) {
            if recorder.canRetrySave {
                Button(tr("rec.retrySave")) { Task { await recorder.recoverPending(retry: true) } }
            }
            Button(tr("common.close"), role: .cancel) { recorder.dismissNotice() }
        } message: { Text(recorder.notice ?? "") }
        .alert(tr("rec.silence.title"), isPresented: Binding(
            get: { recorder.silence.needsConfirmation && recorder.isRecording && scenePhase == .active },
            set: { if !$0 && scenePhase == .active { recorder.continueAfterSilence() } }
        )) {
            Button(tr("rec.silence.stop")) { Task { await recorder.stop() } }
            Button(tr("rec.silence.continue"), role: .cancel) { recorder.continueAfterSilence() }
        } message: { Text(tr("rec.silence.message")) }
        .task(id: model.didRestore) {
            if model.didRestore {
                await recorder.recoverPending()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-AWDSilenceReminderUITest") {
                    recorder.beginFakeRecording(seconds: 300)
                }
                if ProcessInfo.processInfo.arguments.contains("-AWDPauseRecordingUITest") {
                    recorder.beginFakeRecording(seconds: 35, paused: true)
                }
                if ProcessInfo.processInfo.arguments.contains("-AWDPausedVideoUITest") {
                    CameraService.shared.beginFakePausedVideo()
                }
#endif
            }
        }
        .onChange(of: scenePhase) { _, phase in
            recorder.recordingSceneChanged(active: phase == .active)
            if phase == .active {
                Task {
                    await recorder.checkRecordingStatus()
                    await recorder.recoverPending()
                }
            }
        }
        .animation(T.A.base, value: model.isSignedIn)
        .animation(T.A.base, value: model.selectedProject)
        .environment(\.layoutDirection, L10n.isRTL ? .rightToLeft : .leftToRight)
    }

    private var recordingTest: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-AWDRecordingUITest")
#else
        false
#endif
    }

    /// Release 里恒为 false，整段截图分支被优化掉。
    private var isScreenshotting: Bool {
#if DEBUG
        Shot.isOn
#else
        false
#endif
    }

    /// 第 n 屏对应哪一页，见 docs/specs/2026-09-13-store-assets-design.md §2。
    /// 1 / 2 首页取景，3 队列，4 图集，5 查看器，6 录音中，7 设置，8 项目选择器。
    @ViewBuilder
    private var screenshotStage: some View {
#if DEBUG
        switch Shot.screen {
        case 3:
            QueueView(onClose: {}).environment(model).preferredColorScheme(.light)
        case 4:
            LibraryView(onClose: {}).environment(model).preferredColorScheme(.dark)
        case 5:
            screenshotViewer
        case 7:
            SettingsView(onClose: {}).environment(model).preferredColorScheme(.light)
        case 8:
            ProjectPickerView().environment(model).preferredColorScheme(.light)
        default:
            HomeView(paused: false, onOpenLibrary: {}, onOpenQueue: {}, onOpenSettings: {})
                .environment(model)
                .preferredColorScheme(.dark)
        }
#else
        EmptyView()
#endif
    }

#if DEBUG
    /// 查看器直接铺满，不必先进图集再点开——它本来就是全屏页。
    @ViewBuilder
    private var screenshotViewer: some View {
        let day = LibraryGrouping.days(model.currentItems).first
        let items = day?.items ?? []
        if items.isEmpty {
            Color(T.D.bg).ignoresSafeArea()
        } else {
            // 挑一张已落盘的照片：顶栏的状态点、时间、哈希前缀都要有内容
            let i = items.firstIndex { $0.kind == .photo && $0.state == .arrived } ?? 0
            ViewerView(items: items, index: i, onClose: {})
        }
    }
#endif

}

struct CaptureFlowView: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void
    @State private var route: Route?
    private enum Route: Hashable, Identifiable {
        case library, queue, settings
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Label(tr("workspace.closeCapture"), systemImage: "folder")
                        .frame(minHeight: T.touchMin)
                        .contentShape(Rectangle())
                }
                    .accessibilityIdentifier("capture.close")
                    .disabled(CameraService.shared.isRecording || CameraService.shared.isStartingRecording || CameraService.shared.isCapturingPhoto || AudioRecorderService.shared.isBusy)
                Spacer()
            }.padding(.horizontal).padding(.top, 8)
            capture
        }
        .background(T.D.bg)
        .alert(tr("error.generic"), isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button(tr("common.close")) { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
        .preferredColorScheme(.dark)
        .onDisappear {
            if !CameraService.shared.isRecording { CameraService.shared.stop() }
            LocationStamper.shared.end()
        }
    }

    private var capture: some View {
        HomeView(
            paused: route != nil || model.showBackupPrompt,
            onOpenLibrary: { route = .library },
            onOpenQueue: { route = .queue },
            onOpenSettings: { route = .settings },
            projectContents: { AnyView(CaptureProjectContentsView(project: $0)) }
        )
        .environment(model)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $route) { r in
            Group {
                switch r {
                case .queue:
                    QueueView(onClose: { route = nil }).environment(model)
                        .preferredColorScheme(.light)
                case .settings:
                    SettingsView(onClose: { route = nil }).environment(model)
                        .preferredColorScheme(.light)
                case .library:
                    LibraryView(onClose: { route = nil })
                        .environment(model)
                        .preferredColorScheme(.dark)
                }
            }
            .environment(\.layoutDirection, L10n.isRTL ? .rightToLeft : .leftToRight)
        }
    }
}
