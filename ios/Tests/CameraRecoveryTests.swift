import AVFoundation
import XCTest
import UIKit
@testable import Workdeck

/// 相机会话的存活策略（dev-board#461）。
///
/// 真机上的「切完标签取景黑屏、快门无声失败」在 CI 里复现不了——AVFoundation
/// 的设备与中断都不在模拟器上。能钉住的只有「什么信号 → 做哪几步」这层判定，
/// 所以 CameraRecovery 走 CameraSessionControl 这个接缝，这里用假实现记调用序。
@MainActor
final class CameraRecoveryTests: XCTestCase {
    private final class FakeControl: CameraSessionControl {
        enum Action: Equatable {
            case stopRunning, reconfigure, startRunning, addMicrophone, removeMicrophone
        }
        private(set) var actions: [Action] = []
        func stopRunning() { actions.append(.stopRunning) }
        func reconfigure() { actions.append(.reconfigure) }
        func startRunning() { actions.append(.startRunning) }
        func addMicrophone() { actions.append(.addMicrophone) }
        func removeMicrophone() { actions.append(.removeMicrophone) }
    }

    private var control = FakeControl()
    private var recovery: CameraRecovery!

    override func setUp() {
        super.setUp()
        control = FakeControl()
        recovery = CameraRecovery(control: control)
    }

    func testPreviewReportsWindowAttachmentBeforeCameraStartupAndDetachmentOnClose() {
        let preview = CameraPreview.PreviewView()
        var visibility: [Bool] = []
        preview.onVisibilityChanged = { _, visible in visibility.append(visible) }
        XCTAssertTrue(visibility.isEmpty, "Constructing a capture screen must not start the camera before presentation")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.addSubview(preview)
        XCTAssertEqual(visibility, [true])
        preview.removeFromSuperview()
        XCTAssertEqual(visibility, [true, false])
        window.addSubview(preview)
        XCTAssertEqual(visibility, [true, false, true], "Reopening capture must issue a fresh start without mode switching")
    }

    // MARK: - 媒体服务重置

    /// mediaServicesWereReset 之后会话里的输入输出全是空壳，只能拆干净重建。
    /// 旧实现的 configured 是一次性闩锁，重建这一步根本不存在，于是只能重开 App。
    func testMediaServicesResetRebuildsAndRestarts() {
        recovery.desiredRunning = true
        recovery.handleRuntimeError(.mediaServicesWereReset)
        XCTAssertEqual(control.actions, [.stopRunning, .reconfigure, .startRunning])
    }

    /// 恢复只按用户意图点亮相机。锁屏后台录音（UIBackgroundModes audio）期间
    /// desiredRunning 是 false，这时重建会话不能顺手把摄像头打开——那是隐私事故。
    func testMediaServicesResetDoesNotRelightCameraWhenNotDesired() {
        recovery.desiredRunning = false
        recovery.handleRuntimeError(.mediaServicesWereReset)
        XCTAssertEqual(control.actions, [.stopRunning, .reconfigure])
        XCTAssertFalse(control.actions.contains(.startRunning))
    }

    /// 重建是一次昂贵的 XPC，不是万能锤：别的运行时错误不重建。
    func testOtherRuntimeErrorDoesNotRebuild() {
        recovery.desiredRunning = true
        recovery.handleRuntimeError(.deviceNotConnected)
        XCTAssertEqual(control.actions, [])
    }

    // MARK: - 中断

    /// 被别的客户端抢走设备（来电、Siri、另一个 App 占麦克风）之后，
    /// 系统发 interruptionEnded，会话要自己起来，不能等用户重开 App。
    func testInterruptionEndedRestartsWhenDesired() {
        recovery.desiredRunning = true
        recovery.handleInterruptionEnded()
        XCTAssertEqual(control.actions, [.startRunning])
    }

    /// 用户此刻停在录音档（camera.stop() 已置 desiredRunning = false），
    /// 中断结束不能把取景会话拉起来。
    func testInterruptionEndedDoesNotStartWhenNotDesired() {
        recovery.desiredRunning = false
        recovery.handleInterruptionEnded()
        XCTAssertEqual(control.actions, [])
    }

    // MARK: - 麦克风归属

    /// 触发器本体：录像收声把麦克风输入加进捕获会话，旧实现的 micAdded 是单向闩，
    /// 加进去就再也不摘。之后每次 AVAudioRecorder 用 .record 会话开录，
    /// 都是两个客户端抢同一个麦克风。开录前必须先把它还回去。
    func testMicrophoneIsReleasedBeforeAudioRecording() {
        recovery.acquireMicrophone()
        XCTAssertTrue(recovery.micHeld)
        recovery.releaseMicrophone()
        XCTAssertEqual(control.actions, [.addMicrophone, .removeMicrophone])
        XCTAssertFalse(recovery.micHeld)
    }

    /// 还回去之后再进录像档要能重新拿到——单向闩的时候这一步是不可能的。
    func testMicrophoneCanBeReacquiredAfterRelease() {
        recovery.acquireMicrophone()
        recovery.releaseMicrophone()
        recovery.acquireMicrophone()
        XCTAssertEqual(control.actions, [.addMicrophone, .removeMicrophone, .addMicrophone])
        XCTAssertTrue(recovery.micHeld)
    }

    /// 重复调用不重复出站：加两次只加一次，摘两次只摘一次。
    func testMicrophoneOwnershipIsIdempotent() {
        recovery.acquireMicrophone()
        recovery.acquireMicrophone()
        recovery.releaseMicrophone()
        recovery.releaseMicrophone()
        XCTAssertEqual(control.actions, [.addMicrophone, .removeMicrophone])
    }

    /// 会话被拆干净重建之后麦克风已经不在里面了，归属标记必须跟着归零，
    /// 否则下一次录像会以为麦克风还在，录出没有声音的视频。
    func testSessionRebuildDropsMicrophoneOwnership() {
        recovery.desiredRunning = true
        recovery.acquireMicrophone()
        recovery.handleRuntimeError(.mediaServicesWereReset)
        XCTAssertFalse(recovery.micHeld)
    }
}
