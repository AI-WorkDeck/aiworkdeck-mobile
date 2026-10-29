import AVFoundation
import XCTest
@testable import Workdeck

/// Simulator integration: real AAC file, recorder stop, durable library commit and playback.
@MainActor
final class AudioRecorderIntegrationTests: XCTestCase {
    func testInterruptedRecordingStopsViaIntentAndPersistsPlayableAudioOnce() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant simulator microphone permission before this integration test")
        }
        let service = AudioRecorderService.shared
        let callback = service.onStored
        service.onStored = nil
        defer { service.onStored = callback }
        let before = try await EvidenceStore.shared.loadAll().count
        await service.toggle(project: nil, location: nil)
        XCTAssertTrue(service.isRecording, service.lastError ?? "Recording did not start")
        guard service.isRecording else { return }
        let draftID = service.activeDraft?.id
        await service.start(project: nil, location: nil)
        XCTAssertTrue(service.isRecording, "A repeated start must never stop the recording")
        XCTAssertEqual(service.activeDraft?.id, draftID)
        try await Task.sleep(for: .seconds(2))
        await service.checkRecordingStatus()
        XCTAssertGreaterThanOrEqual(service.recordingSeconds, 1)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<50 where service.isRecording || service.isBusy {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.notice, tr("rec.interruption.saved"))
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        await service.checkRecordingStatus()
        XCTAssertFalse(service.isRecording, "An interruption must never automatically reopen the microphone")
        StopRecordingIntent.handler = { await service.stop() }
        _ = try await StopRecordingIntent().perform()
        await service.stop()
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isInterrupted)
        XCTAssertFalse(service.isBusy)
        let id = try XCTUnwrap(service.lastSavedID)
        let items = try await EvidenceStore.shared.loadAll()
        XCTAssertEqual(items.count, before + 1)
        let item = try XCTUnwrap(items.first { $0.id == id })
        let duration = try await AVURLAsset(url: item.localURL).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1)
        let activated = await configureAudioSession(active: true, playback: true)
        XCTAssertTrue(activated)
        let player = try AVAudioPlayer(contentsOf: item.localURL)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertGreaterThan(player.duration, 1)
        service.dismissNotice()
        await EvidenceStore.shared.delete(ids: [id])
        _ = await configureAudioSession(active: false)
    }
}
