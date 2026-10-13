import SwiftUI

/// 首页 = 取景器。现场是单手、光线差、要快 —— 所以进来就是镜头，
/// 不再隔一层「按转盘进取景页」。信息各归其位：业务归属在顶部，
/// 画面在中间（淡水印叠加），快门与模式在拇指够得到的下方。
///
/// 水印只叠加在取景与展示层，**不烧录进照片字节**：
/// 照片是 JPEG 直出保 SHA-256「原始采集」，烧录会毁掉证据链（决策 D3）。
struct HomeView: View {
    /// 三档采集模式。photo/video 由相机会话承担，audio 走 AudioRecorderService——
    /// 录音本来就不该经过相机。三档并排显式给出，不藏在二级界面里。
    private enum CapMode: Hashable { case photo, video, audio }

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// 有全屏浮层（队列/影像/设置）压在上面时停相机省电；录像中除外，不能断录。
    let paused: Bool

    var onOpenLibrary: () -> Void
    var onOpenQueue: () -> Void
    var onOpenSettings: () -> Void

    /// 三个采集服务都是进程级单例。@Observable 对象不必用 @State 持有，body 里读它的
    /// 属性照样被观察；反过来用 @State 持有反而有害——初始值表达式每次重建结构体都会
    /// 求值一次，等于每次 RootView body 都在主线程上白建一个 AVCaptureSession /
    /// CLLocationManager 再丢掉（dev-board#418）。
    private let camera = CameraService.shared
    /// 锁屏卡片 / 灵动岛的停止意图要找到正在录的这一个
    private let recorder = AudioRecorderService.shared
    private let stamper = LocationStamper.shared
    @State private var mode: CapMode = .photo
    @State private var showFlash = false
    @State private var visiblePreviews: Set<UUID> = []

    private var shouldRunCamera: Bool {
        !visiblePreviews.isEmpty && !paused && scenePhase == .active && mode != .audio && !recorder.isRecording
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    stage
                    ScrollView {
                        VStack(spacing: 0) { header; controls }
                    }
                    .frame(width: min(360, geometry.size.width * 0.45))
                }
            } else {
                VStack(spacing: 0) { header; stage; controls }
            }
        }
        .background(T.D.bg.ignoresSafeArea())
        .task {
            // 采集失败与落库失败走同一个字段：失败必须有个落点，不能只留在日志里
            camera.onError = { msg in model.lastError = msg }
#if DEBUG
            // Recording/navigation fixtures do not need real location services.
            // Keep the host simulator's location daemon out of these isolated tests.
            if !WorkspaceUITestSeed.isOn && !ProcessInfo.processInfo.arguments.contains("-AWDRecordingUITest") {
                stamper.begin()
            }
#else
            stamper.begin()
#endif
#if DEBUG
            // 截图模式不点相机、不录音：模拟器没有摄像头，权限弹窗还会挡住画面。
            // 第 6 屏要的是「录音进行中」的首页，直接把录音的展示状态摆出来。
            if Shot.isOn {
                if Shot.screen == 6 {
                    mode = .audio
                    recorder.beginFakeRecording(seconds: 12 * 60 + 41)
                }
                return
            }
#endif
            if recorder.isRecording { mode = .audio }
        }
        .onChange(of: mode) { _, m in
            // 离开录像档就把麦克风还回去：只有录像收声需要它，留着就会在下一次
            // 现场录音时与 AVAudioRecorder 抢设备（dev-board#461）。
            if m != .video { camera.releaseMicrophone() }
            switch m {
            case .photo:
                camera.mode = .photo
            case .video:
                camera.mode = .video
            case .audio:
                // 录音不需要取景，停掉相机会话省电；切回来再启
                camera.stop()
            }
        }
        // A sheet's task can run before its preview is attached to a window.
        // Drive startup from actual visibility and foreground state, including
        // the return from the first permission prompt and full-screen covers.
        .task(id: shouldRunCamera) {
            if shouldRunCamera { await camera.start() }
            else if !camera.isRecording { camera.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if recorder.isRecording { mode = .audio }
                Task {
                    await recorder.checkRecordingStatus()
                    await recorder.recoverPending()
                }
                // 回前台立刻续传：后台被杀的上传此刻已是滞留态，kick 入口会回收
                model.kickUpload()
            case .background:
                // 录像退后台：停表并落库，不丢已录的内容——现场不可复现。
                // 录音不停：靠 UIBackgroundModes audio 在后台 / 锁屏继续录（dev-board#404）。
                if camera.isRecording { Task { await camera.toggleRecording() } }
                camera.stop()
            default:
                break
            }
        }
    }

    // MARK: - 顶部信息

    private var header: some View {
        VStack(alignment: .leading, spacing: T.Sp.s1) {
            HStack {
                Eyebrow(text: tr("home.eyebrow"), color: .white.opacity(0.45))
                Spacer()
                locationChip
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: T.touchMin, height: 28, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("home.settings"))
                .accessibilityIdentifier("capture.settings")
            }

            Text(model.project.name)
                .font(T.F.title())
                .kerning(-0.2)
                .foregroundStyle(T.D.fg)
                .lineLimit(1)

            Text(tr("home.archiveTo", ["path": model.project.archivePath]))
                .font(T.F.nano())
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.4))

            tallyLine
                .padding(.top, T.Sp.s1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, T.Sp.gutter)
        .padding(.top, T.Sp.s2)
        .padding(.bottom, T.Sp.s3)
    }

    /// 位置精度：没有精度的坐标在质证时说明不了问题，所以直接显示出来
    private var locationChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stamper.last == nil ? Color.white.opacity(0.3) : T.S.arrivedOnDark)
                .frame(width: 5, height: 5)
            Text(stamper.last.map { tr("home.gps.accuracy", ["m": String(Int($0.accuracy.rounded()))]) } ?? tr("home.gps.none"))
                .font(T.F.mono(10))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.trailing, T.Sp.s2)
    }

    private var tallyLine: some View {
        HStack(spacing: 0) {
            count(model.tally.uploading, TransferPhase.uploading.caption, T.S.waitingOnDark, failed: model.tally.failed)
            divider
            count(model.tally.staged, TransferPhase.staged.caption, T.S.movingOnDark)
            divider
            count(model.tally.landed, TransferPhase.landed.caption, T.S.arrivedOnDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenQueue)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tallyA11y)
        .accessibilityHint(tr("home.queue.a11yHint"))
        .accessibilityAddTraits(.isButton)
    }

    private var tallyA11y: String {
        let t = model.tally
        let f = t.failed > 0 ? tr("tally.summary.failedPart", ["m": String(t.failed)]) : ""
        return tr("tally.summary", ["u": String(t.uploading), "f": f, "s": String(t.staged), "l": String(t.landed)])
    }

    private func count(_ n: Int, _ label: String, _ color: Color, failed: Int = 0) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(n)")
                .font(T.F.mono(13, .medium))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(T.F.nano())
                .foregroundStyle(.white.opacity(0.45))
            if failed > 0 {
                // 失败不单独成桶，但不能藏：云端满、会话过期这类不重试也不会好
                Text(tr("tally.failedSuffix", ["m": String(failed)]))
                    .font(T.F.nano())
                    .foregroundStyle(T.S.failed)
            }
        }
    }

    private var divider: some View {
        Text("/")
            .font(T.F.micro())
            .foregroundStyle(.white.opacity(0.18))
            .padding(.horizontal, T.Sp.s2)
    }

    // MARK: - 取景舞台

    private var stage: some View {
        ZStack {
            if mode == .audio || recorder.isRecording {
                audioStage
            } else if let seed = screenshotSeed {
                // 模拟器没有摄像头，取景区是全黑的。截图模式下用一张现场照片顶上，
                // 水印照旧叠在上面——叠加层本来就与相机会话无关。
                GeometryReader { geo in
                    Image(uiImage: seed)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .overlay(alignment: .bottomLeading) { watermark }
            } else {
                CameraPreview(session: camera.session, device: camera.device, revision: camera.configurationRevision,
                              onVisibilityChanged: { id, visible in
                                  if visible { visiblePreviews.insert(id) }
                                  else { visiblePreviews.remove(id) }
                              })
                    .overlay(alignment: .bottomLeading) { watermark }
                    .overlay {
                        if camera.permissionDenied { denied.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black) }
                    }
            }

            // 快门白闪：唯一的「拍到了」即时反馈，比任何提示都快
            if showFlash {
                Color.white.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(T.D.rule, lineWidth: 1)
        }
        .padding(.horizontal, T.Sp.s2)
    }

    /// 淡水印：时间到秒、项目名、坐标与精度。白字低透明度加投影，
    /// 深浅背景都读得清，又不抢画面。只叠加显示，不写进照片。
    private var watermark: some View {
        VStack(alignment: .leading, spacing: 2) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.stamp(ctx.date))
                    .font(T.F.mono(12, .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Text(model.project.name)
                .font(T.F.micro())
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Text(coordLine)
                .font(T.F.mono(10))
                .foregroundStyle(.white.opacity(0.6))
        }
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .padding(T.Sp.s3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var coordLine: String {
        guard let l = stamper.last else { return tr("home.gps.locating") }
        return String(format: "%.5f, %.5f · ±%.0fm", l.lat, l.lon, l.accuracy)
    }

    /// 截图模式下取景区放哪一张现场照片。Release 里恒为 nil，走真相机。
    private var screenshotSeed: UIImage? {
#if DEBUG
        Shot.isOn ? Shot.sceneImage(Shot.screen) : nil
#else
        nil
#endif
    }

    private static func stamp(_ d: Date) -> String {
#if DEBUG
        // 水印上的秒也要定住：同一屏截两次不该差一秒
        if Shot.isOn { return stampFormatter.string(from: Shot.stampDate) }
#endif
        return stampFormatter.string(from: d)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - 底部控制

    private var controls: some View {
        VStack(spacing: T.Sp.s3) {
            if camera.isRecording || recorder.isRecording {
                HStack(spacing: T.Sp.s1) {
                    Circle().fill(T.S.failed).frame(width: 7, height: 7)
                    Text(timeString(camera.isRecording ? camera.recordingSeconds
                                                       : recorder.recordingSeconds))
                        .font(T.F.mono(13, .medium))
                        .foregroundStyle(.white)
                    Text(camera.isRecording ? tr("home.recording.video") : tr("home.recording.audio"))
                        .font(T.F.nano())
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(minHeight: 28)
            } else {
                modeRow.disabled(camera.isCapturingPhoto || camera.isStartingRecording)
            }

            HStack {
                libraryEntry
                    .frame(maxWidth: .infinity, alignment: .leading)
                shutter
                counter
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Hairline(color: T.D.rule)

            HStack {
                HStack(spacing: T.Sp.s1) {
                    BreathingDot(isOn: model.link.isOnline, color: T.S.arrivedOnDark)
                    Text(linkCaption)
                        .font(T.F.nano())
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(tr("home.stampFeatures"))
                    .font(T.F.nano())
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, T.Sp.gutter)
        .padding(.top, T.Sp.s3)
        .padding(.bottom, T.Sp.s2)
    }

    /// 三档并排、点选切换。取证的模式必须显式可预期，
    /// 不做横滑模式条，也不做快门手势切换——手滑录错模式是取证事故。
    private var modeRow: some View {
        HStack(spacing: T.Sp.s8) {
            modeButton(tr("home.mode.photo"), .photo)
            modeButton(tr("home.mode.video"), .video)
            modeButton(tr("home.mode.audio"), .audio)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 28)
    }

    private func modeButton(_ label: String, _ m: CapMode) -> some View {
        Button {
            guard mode != m else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(T.A.fast) { mode = m }
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: mode == m ? .semibold : .regular))
                    .tracking(1)
                    .foregroundStyle(mode == m ? .white : .white.opacity(0.45))
                Circle()
                    .fill(.white)
                    .frame(width: 3, height: 3)
                    .opacity(mode == m ? 1 : 0)
            }
            .frame(minWidth: T.touchMin, minHeight: T.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture.mode.\(m)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(mode == m ? [.isButton, .isSelected] : .isButton)
    }

    /// 最近一件的真缩略图，也是影像浏览的入口。
    private var libraryEntry: some View {
        Button(action: onOpenLibrary) {
            VStack(spacing: 3) {
                Group {
                    if let last = model.currentItems.first {
                        EvidenceThumb(item: last, onDark: true)
                            .overlay(alignment: .topLeading) {
                                StatusDot(state: last.state, size: 4, onDark: true)
                                    .padding(3)
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .stroke(T.D.rule, lineWidth: 1)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                    }
                }
                .frame(width: 44, height: 44)
                Text(tr("library.open")).font(T.F.nano()).foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture.library")
        .accessibilityLabel(tr("library.open"))
    }

    private var counter: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(model.tally.total)")
                .font(T.F.mono(17, .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(tr("home.counter.project"))
                .font(T.F.nano())
                .foregroundStyle(.white.opacity(0.5))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenQueue)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tr("home.queue.a11yHint"))
    }

    /// CameraCaptureRequests snapshots this callback at shutter time. Returning
    /// from Settings can change the next destination without rewriting a capture.
    private func bindCaptureDestination() {
        let captureProject = model.selectedProject
        camera.onCaptured = { data, kind, at in
            let loc = stamper.last
            Task { await model.store(data: data, kind: kind, at: at, location: loc, project: captureProject) }
        }
    }

    private var shutter: some View {
        Button {
            if recorder.isRecording {
                Task { await recorder.stop() }
                return
            }
            switch mode {
            case .photo:
                bindCaptureDestination()
                camera.shoot()
                flash()
            case .video:
                if !camera.isRecording { bindCaptureDestination() }
                Task { await camera.toggleRecording() }
            case .audio:
                Task { await recorder.toggle(project: model.selectedProject, location: stamper.last) }
            }
        } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 74, height: 74)
                if camera.isRecording || recorder.isRecording {
                    RoundedRectangle(cornerRadius: 5).fill(T.S.failed).frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(mode == .photo ? Color.white : T.S.failed)
                        .frame(width: 60, height: 60)
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isBusy || camera.isCapturingPhoto || camera.isStartingRecording)
        .accessibilityIdentifier("capture.shutter")
        .accessibilityLabel(shutterLabel)
    }

    private var shutterLabel: String {
        if camera.isRecording { return tr("home.shutter.stopVideo") }
        if recorder.isRecording { return tr("home.shutter.stopAudio") }
        switch mode {
        case .photo: return tr("home.shutter.photo")
        case .video: return tr("home.shutter.startVideo")
        case .audio: return tr("home.shutter.startAudio")
        }
    }

    private var linkCaption: String {
        guard model.link.isOnline else {
            // 离线时说清楚已经等了多久 —— 照片悬在中转区这件事不能藏
            if let t = model.link.lastSyncedAt {
                return "\(tr("home.desktop.offline")) · \(tr("home.desktop.waited", ["t": RelativeTime.short(t)]))"
            }
            return tr("home.desktop.offline")
        }
        if let t = model.link.lastSyncedAt {
            return "\(tr("home.desktop.online")) · \(RelativeTime.short(t))"
        }
        return tr("home.desktop.online")
    }

    private func flash() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.linear(duration: 0.06)) { showFlash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.easeOut(duration: 0.18)) { showFlash = false }
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - 录音舞台

    /// 录音模式没有取景画面：深色底，等宽计时器就是全部的界面。
    private var audioStage: some View {
        Group {
            if recorder.permissionDenied {
                micDenied
            } else {
                VStack(spacing: T.Sp.s3) {
                    Text(timeString(recorder.recordingSeconds))
                        .accessibilityIdentifier("recording.elapsed")
                        .font(T.F.hero())
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    HStack(spacing: T.Sp.s2) {
                        if recorder.isRecording {
                            Circle().fill(T.S.failed).frame(width: 7, height: 7)
                        }
                        Eyebrow(text: recorder.isRecording ? tr("home.recording.audio") : tr("home.audio.hint"),
                                color: .white.opacity(0.55))
                    }
                    if let error = recorder.lastError {
                        Text(error).font(T.F.micro()).foregroundStyle(T.S.failed)
                    }
                    if recorder.canRetrySave, !recorder.isRecording {
                        Button(tr("rec.retrySave")) { Task { await recorder.recoverPending(retry: true) } }
                            .disabled(recorder.isBusy)
                    }
                    if recorder.lastSavedID != nil, !recorder.isRecording {
                        Button(tr("rec.saved.open"), action: onOpenLibrary)
                            .font(T.F.small()).foregroundStyle(.white)
                    }
                    if recorder.isRecording {
                        // 中断后不会自动开麦；强制退出只能在下次启动检查草稿。
                        Text(tr("rec.background.limit"))
                            .font(T.F.micro())
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private var micDenied: some View {
        permissionStage(
            title: tr("home.permission.mic"),
            hint: tr("home.permission.micHint")
        )
    }

    private var denied: some View {
        permissionStage(
            title: tr("home.permission.camera"),
            hint: tr("home.permission.cameraHint")
        )
    }

    private func permissionStage(title: String, hint: String) -> some View {
        VStack(spacing: T.Sp.s3) {
            Text(title)
                .font(T.F.heading())
                .foregroundStyle(.white)
            Text(hint)
                .font(T.F.small())
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button(tr("home.permission.open")) {
                if let u = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(u)
                }
            }
            .font(T.F.small())
            .foregroundStyle(T.S.movingOnDark)
            .padding(.top, T.Sp.s2)
        }
        .padding(T.Sp.s8)
    }
}

#Preview {
    HomeView(paused: false, onOpenLibrary: {}, onOpenQueue: {}, onOpenSettings: {})
        .environment(AppModel())
}
