// AVFoundation 的类型全都不是 Sendable，而 session 配置本来就必须在专用串行队列上做。
// @preconcurrency 是这里的正解：不是掩盖问题，是声明「这个模块的并发标注还没跟上，
// 隔离由我们自己的 sessionQueue 保证」。
@preconcurrency import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

/// 相机。取证要求「确实来自相机」，所以全程自己控制 AVCaptureSession，
/// 不用 UIImagePickerController（那个可以选相册，来源说不清）。
///
/// 照片走 maxPhotoQualityPrioritization = .quality 直出 JPEG，不做二次压缩——
/// 压缩会改变字节，哈希就证明不了「原始采集」。
@MainActor
@Observable
final class CameraService: NSObject {
    /// 进程级单例。**不要再用 `@State private var camera = CameraService()` 持有**：
    /// `@State` 的初始值表达式在每次重建 HomeView 结构体时都会被求值，也就是每次
    /// RootView body 走一遍就 new 一个 AVCaptureSession 再丢掉。在 Mac
    /// （Designed for iPad）上建会话是主线程上的一次 XPC（FigCaptureSessionCreate），
    /// 而这一下恰好落在「呈现设置页全屏浮层」的那次更新里（dev-board#418）。
    static let shared = CameraService()

    enum Mode { case photo, video }

    /// 会话正被系统中断（别的客户端抢走了摄像头 / 麦克风、来电、分屏）。
    /// 中断结束会自己恢复——旧实现连「被中断了」都不知道，只能重开 App（dev-board#461）。
    private(set) var isInterrupted = false
    private(set) var isRecording = false
    private(set) var isStartingRecording = false
    private(set) var permissionDenied = false
    private(set) var recordingSeconds = 0
    var mode: Mode = .photo

    let session = AVCaptureSession()
    private(set) var device: AVCaptureDevice?
    private(set) var configurationRevision = 0
    private var rotation: AVCaptureDevice.RotationCoordinator?


    private var startIntent = CameraStartIntent()
    private var photoRequests = CameraCaptureRequests()
    var isCapturingPhoto: Bool { !photoRequests.isEmpty }

    private let sessionQueue = DispatchQueue(label: "com.aiworkdeck.mobile.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var timer: Timer?
    private var recordingRequest: CameraCaptureRequests.Request?

    /// 用户意图与麦克风归属都记在这里，具体动作由本类执行（见文件末尾的
    /// CameraSessionControl 一节）。拆开是为了让判定能被单测钉住。
    private var recovery: CameraRecovery!

    /// 一条采集完成后回调。UI 层拿去落库。
    var onCaptured: ((Data, MediaKind, Date) -> Void)?

    /// 一次采集失败后回调。取证 App 里「按了快门却什么都没发生」不能是静默的：
    /// 现场不可复现，用户当场就得知道这一张没拍上。
    var onError: ((String) -> Void)?

    private override init() {
        super.init()
        recovery = CameraRecovery(control: self)
        observeSessionHealth()
    }

    // MARK: - 生命周期

    func start() async {
        guard !AudioRecorderService.shared.isRecording, !AudioRecorderService.shared.isBusy else { return }
#if DEBUG
        // 截图模式一律不点相机。守在这里而不是调用点：进前台、切模式、浮层收起
        // 都会各自 start() 一次，漏一处就是一张带权限弹窗的截图。
        if Shot.isOn || WorkspaceUITestSeed.isOn || ProcessInfo.processInfo.arguments.contains("-AWDRecordingUITest") { return }
#endif
        let intent = startIntent.begin()
        recovery.desiredRunning = true
        let authorized = await ensureAuthorized(.video)
        guard startIntent.accepts(intent) else { return }
        guard !Task.isCancelled else { stop(); return }
        guard authorized else {
            permissionDenied = true
            recovery.desiredRunning = false
            return
        }
        // 去系统设置里把权限打开再回来：拒绝态要能自愈，不能一直停在提示页
        permissionDenied = false
        // 意图先落：中断结束与媒体服务重置都只按它决定要不要把相机点亮
        recovery.desiredRunning = true
        await configureIfNeeded()
        guard startIntent.accepts(intent) else { return }
        guard !Task.isCancelled, !AudioRecorderService.shared.isRecording,
              !AudioRecorderService.shared.isBusy else { stop(); return }
        startRunning()
    }

    func stop() {
        startIntent.stop()
        recovery.desiredRunning = false
        stopRunning()
    }

    /// 把麦克风还给系统。现场录音必须独占麦克风：录过一次像之后麦克风输入会一直
    /// 挂在捕获会话上，与 AVAudioRecorder 的 `.record` 会话抢同一个设备，
    /// 捕获会话被中断后（旧实现无人恢复）就是黑屏 + 快门失灵（dev-board#461）。
    func releaseMicrophone() { recovery.releaseMicrophone() }

    /// Wait for the capture queue to relinquish audio before activating the recorder.
    func prepareForAudioRecording() async {
        stop()
        releaseMicrophone()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [session] in
                session.automaticallyConfiguresApplicationAudioSession = false
                continuation.resume()
            }
        }
    }

    /// 会话健康：中断、中断结束、运行时错误。这三个观察者是本次修复的核心——
    /// 旧实现一个都没有，会话一旦死掉就永远是黑的，只有重开 App 才好。
    /// 单例活到进程结束，不用留 token 反注册（同 AudioRecorderService）。
    private func observeSessionHealth() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: .main
        ) { [weak self] note in
            // Notification 不是 Sendable，跨 actor 之前先把要用的值取出来
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            Task { @MainActor in self?.sessionWasInterrupted(reason: reason) }
        }
        center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sessionInterruptionEnded() }
        }
        center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: .main
        ) { [weak self] note in
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)
                .flatMap { AVError.Code(rawValue: $0.code) }
            Task { @MainActor in self?.sessionRuntimeError(code) }
        }
    }

    private func sessionWasInterrupted(reason: Int) {
        isInterrupted = true
        // 原因编号要留痕：现场不可复现，事后只能靠它回答「那一下为什么黑了」
        cameraLog.error("capture session interrupted, reason=\(reason, privacy: .public)")
    }

    private func sessionInterruptionEnded() {
        isInterrupted = false
        cameraLog.log("capture session interruption ended")
        recovery.handleInterruptionEnded()
    }

    private func sessionRuntimeError(_ code: AVError.Code?) {
        cameraLog.error("capture session runtime error, code=\(code?.rawValue ?? -1, privacy: .public)")
        guard let code else { return }
        recovery.handleRuntimeError(code)
    }

    private var configured = false

    private func configureIfNeeded() async {
        guard !configured else { return }
        configured = true

        device = await withCheckedContinuation { cont in
            sessionQueue.async { [session, photoOutput, movieOutput] in
                cont.resume(returning: Self.applyConfiguration(session: session, photoOutput: photoOutput, movieOutput: movieOutput))
            }
        }
        if let device { rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil) }
        configurationRevision += 1
    }

    /// 在 sessionQueue 上跑。首次配置与重置后的重建共用这一份——
    /// 两处各写一遍是这类会话代码最容易走样的地方。
    private nonisolated static func applyConfiguration(
        session: AVCaptureSession,
        photoOutput: AVCapturePhotoOutput,
        movieOutput: AVCaptureMovieFileOutput
    ) -> AVCaptureDevice? {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        session.commitConfiguration()
        return session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }?.device
    }

    /// 麦克风按需申请：只拍照的用户不该被要求授权录音。
    /// 用完要还（releaseMicrophone），不能像旧实现那样加进去就一直留着。
    private func addMicIfNeeded() async {
        guard !recovery.micHeld, await ensureAuthorized(.audio) else { return }
        recovery.acquireMicrophone()
    }

    private func ensureAuthorized(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    // MARK: - 采集

    func shoot() {
        guard !isRecording, !isCapturingPhoto else { return }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .quality
        photoRequests.begin(id: settings.uniqueID, at: Date(), completed: onCaptured, failed: onError)
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        sessionQueue.async { [photoOutput, weak self] in
            guard let self else { return }
            guard let connection = photoOutput.connection(with: .video), connection.isActive else {
                Task { @MainActor in
                    self.photoRequests.take(id: settings.uniqueID)?.failed?(tr("error.captureNoData"))
                }
                return
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func toggleRecording() async {
        guard !isStartingRecording else { return }
        if isRecording {
            sessionQueue.async { [movieOutput] in movieOutput.stopRecording() }
            return
        }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let intent = startIntent.generation
        let request = CameraCaptureRequests.Request(capturedAt: Date(), completed: onCaptured, failed: onError)
        await addMicIfNeeded()
        guard startIntent.accepts(intent), !Task.isCancelled else { releaseMicrophone(); return }
        recordingRequest = request
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).mov")
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        sessionQueue.async { [movieOutput, weak self] in
            guard let self else { return }
            if let connection = movieOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
        isRecording = true
        recordingSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingSeconds += 1 }
        }
    }
}

// MARK: - 会话动作

/// CameraRecovery 决定「做哪几步」，这里是「怎么做」。全部只往 sessionQueue 上排队：
/// 那是一条串行队列，入队顺序就是执行顺序，不需要另外同步。
extension CameraService: CameraSessionControl {
    func startRunning() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stopRunning() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// mediaServicesWereReset 之后会话里的输入输出全成了空壳，拆干净重来。
    /// configured 保持 true：这一次调用本身就是一次完整的重新配置。
    func reconfigure() {
        configured = true
        sessionQueue.async { [session, photoOutput, movieOutput, weak self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            let device = Self.applyConfiguration(session: session, photoOutput: photoOutput, movieOutput: movieOutput)
            Task { @MainActor [weak self] in
                self?.device = device
                self?.rotation = device.map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: nil) }
                self?.configurationRevision += 1
            }
        }
    }

    func addMicrophone() {
        sessionQueue.async { [session] in
            session.automaticallyConfiguresApplicationAudioSession = true
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic),
                  session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.addInput(input)
            session.commitConfiguration()
        }
    }

    /// 按媒体类型扫出来再摘，不另存一份引用：引用要跨队列同步，
    /// 而「会话里此刻挂着哪些输入」本来就只有在 sessionQueue 上问才准。
    func removeMicrophone() {
        sessionQueue.async { [session] in
            let mics = session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .filter { $0.device.hasMediaType(.audio) }
            guard !mics.isEmpty else { return }
            session.beginConfiguration()
            mics.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }
}

// MARK: - 代理

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let id = photo.resolvedSettings.uniqueID
        let data = photo.fileDataRepresentation()
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let request = self?.photoRequests.take(id: id) else { return }
            if let message {
                request.failed?(tr("error.captureFailed", ["reason": message]))
            } else if let data {
                request.completed?(data, .photo, request.capturedAt)
            } else {
                request.failed?(tr("error.captureNoData"))
            }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                error: Error?) {
        guard let error else { return }
        let id = resolvedSettings.uniqueID
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.photoRequests.take(id: id)?.failed?(tr("error.captureFailed", ["reason": message]))
        }
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let data = try? Data(contentsOf: outputFileURL, options: .mappedIfSafe)
        let message = error?.localizedDescription
        try? FileManager.default.removeItem(at: outputFileURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.timer?.invalidate()
            self.timer = nil
            self.recordingSeconds = 0
            let request = self.recordingRequest
            self.recordingRequest = nil
            if let message { request?.failed?(tr("error.videoFailed", ["reason": message])) }
            else if let data, let request { request.completed?(data, .video, request.capturedAt) }
            else { request?.failed?(tr("error.videoNoData")) }
        }
    }
}

// MARK: - 取景预览

/// AVCaptureVideoPreviewLayer 的 SwiftUI 包装。用 layerClass 而不是手动加子 layer，
/// 这样 layer 会自动跟随 view 的 bounds，旋转和分屏都不用自己处理。
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var device: AVCaptureDevice? = nil
    var revision = 0
    var onVisibilityChanged: (UUID, Bool) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.onVisibilityChanged = onVisibilityChanged
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.track(device, revision: revision)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.track(device, revision: revision) }

    final class PreviewView: UIView {
        var onVisibilityChanged: (UUID, Bool) -> Void = { _, _ in }
        private let visibilityID = UUID()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onVisibilityChanged(visibilityID, window != nil)
        }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        private var revision = -1
        func track(_ device: AVCaptureDevice?, revision: Int) {
            guard let device else { observation = nil; rotation = nil; return }
            guard rotation?.device !== device || self.revision != revision else { return }
            self.revision = revision
            rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            observation = rotation?.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor [weak self] in
                    guard let connection = self?.previewLayer.connection,
                          connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }
            }
        }

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - 位置

/// 一次性取位置：只在拍摄时读一次，不做后台定位。
/// 精度一并记下——没有精度的坐标在质证时说明不了问题。
@MainActor
@Observable
final class LocationStamper: NSObject, CLLocationManagerDelegate {
    /// 同 CameraService：CLLocationManager 的创建也是主线程上的一次 daemon 注册，
    /// 不该跟着 HomeView 结构体一遍遍重建（dev-board#418）。
    static let shared = LocationStamper()

    private let manager = CLLocationManager()
    private(set) var last: (lat: Double, lon: Double, accuracy: Double)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func begin() {
#if DEBUG
        // 截图模式给一个固定坐标与精度（规格要「±5 米」），不真起定位——
        // 模拟器没有位置，弹出的授权框还会挡住截图。
        if Shot.isOn {
            last = Shot.location
            return
        }
#endif
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func end() { manager.stopUpdatingLocation() }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        let v = (l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy)
        Task { @MainActor [weak self] in self?.last = v }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

enum Device {
    static var facts: DeviceFacts {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return DeviceFacts(
            model: model,
            osVersion: UIDevice.current.systemVersion,
            appVersion: "\(v) (\(b))"
        )
    }
}
