import AVFoundation
import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class HomeCameraLifecycleTests: XCTestCase {
    func testVisibleCameraStartsAfterPendingAudioRecoveryFinishesWithoutModeSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let draft = RecordingDraft(id: UUID(), startedAt: Date(), project: nil,
            latitude: nil, longitude: nil, accuracy: nil,
            device: DeviceFacts(model: "test", osVersion: "test", appVersion: "test"))
        try draft.persist()
        defer {
            draft.remove()
            try? FileManager.default.removeItem(at: root)
        }
        try writeAudio(to: draft.audioURL)
        let recorder = AudioRecorderService(store: EvidenceStore(root: root), pendingDrafts: { [draft] })
        let recoverySaving = expectation(description: "Recovery reaches its asynchronous completion callback")
        var finishSaving: CheckedContinuation<Void, Never>?
        recorder.onStored = {
            await withCheckedContinuation { continuation in
                finishSaving = continuation
                recoverySaving.fulfill()
            }
        }
        let recovery = Task { await recorder.recoverPending() }
        defer { finishSaving?.resume() }
        await fulfillment(of: [recoverySaving], timeout: 5)
        XCTAssertTrue(recorder.isBusy)
        XCTAssertFalse(recorder.isRecording)

        var startRequests = 0
        let view = HomeView(paused: false, onOpenLibrary: {}, onOpenQueue: {}, onOpenSettings: {},
            recorder: recorder, cameraStartForTesting: { startRequests += 1 })
            .environment(AppModel())
            .environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(containsAttachedPreview(host.view), "Exercise the real preview window-attachment callback")
        let requestsWhileBusy = startRequests

        finishSaving?.resume()
        finishSaving = nil
        await recovery.value
        XCTAssertFalse(recorder.isBusy)
        for _ in 0..<50 where startRequests == requestsWhileBusy {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(startRequests, requestsWhileBusy + 1,
            "Busy → idle must retrigger HomeView's camera task without changing mode or reattaching the preview")
        XCTAssertTrue(containsAttachedPreview(host.view))
    }

    private func containsAttachedPreview(_ view: UIView) -> Bool {
        if view is CameraPreview.PreviewView { return view.window != nil }
        return view.subviews.contains(where: containsAttachedPreview)
    }

    private func writeAudio(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0..<44_100 { samples[frame] = 0.1 * sin(Float(frame) * 0.05) }
        }
        try file.write(from: buffer)
    }
}
