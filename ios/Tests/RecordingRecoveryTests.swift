import AVFoundation
import XCTest
@testable import Workdeck

@MainActor
final class RecordingRecoveryTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private lazy var store = EvidenceStore(root: root)

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeDraft() throws -> RecordingDraft {
        let draft = RecordingDraft(id: UUID(), startedAt: Date(), project: nil,
            latitude: nil, longitude: nil, accuracy: nil,
            device: DeviceFacts(model: "test", osVersion: "test", appVersion: "test"))
        try draft.persist()
        return draft
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

    func testRecoveredAudioIsPlayableAndDoesNotRestartMicrophone() async throws {
        let draft = try makeDraft()
        let service = AudioRecorderService(store: store, pendingDrafts: { [draft] })
        defer { draft.remove() }
        try writeAudio(to: draft.audioURL)
        await service.recoverPending(retry: true)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.lastSavedID, draft.id)
        XCTAssertTrue(service.notice?.contains(tr("rec.recovery.saved", ["count": "1"])) == true)
        let items = try await store.loadAll()
        let saved = try XCTUnwrap(items.first { $0.id == draft.id })
        let player = try AVAudioPlayer(contentsOf: saved.localURL)
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.metadataURL.path))
        service.dismissNotice()
        await service.recoverPending()
        XCTAssertNil(service.notice, "Do not repeatedly announce already recovered recordings")
        await store.delete(ids: [draft.id])
    }

    func testMissingAudioRetainsDraftAndRetryCanRecoverIt() async throws {
        let draft = try makeDraft()
        let service = AudioRecorderService(store: store, pendingDrafts: { [draft] })
        defer { draft.remove() }
        await service.recoverPending(retry: true)
        XCTAssertNil(service.lastSavedID)
        XCTAssertTrue(service.canRetrySave)
        XCTAssertTrue(service.notice?.contains(tr("rec.recovery.noAudio", ["count": "1"])) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.metadataURL.path))
        service.dismissNotice()
        await service.recoverPending()
        XCTAssertNil(service.notice, "Dismissed failures must not loop on every foreground")
        try writeAudio(to: draft.audioURL)
        await service.recoverPending(retry: true)
        XCTAssertEqual(service.lastSavedID, draft.id)
        XCTAssertFalse(service.canRetrySave)
        XCTAssertNil(service.lastError)
        await store.delete(ids: [draft.id])
    }

    func testLibraryWriteFailureKeepsPlayableDraftForRetry() async throws {
        let draft = try makeDraft()
        let service = AudioRecorderService(store: store, pendingDrafts: { [draft] })
        defer { draft.remove() }
        try writeAudio(to: draft.audioURL)
        let blockedManifest = root.appendingPathComponent("manifest/\(draft.id.uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedManifest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blockedManifest) }
        await service.recoverPending(retry: true)
        XCTAssertNil(service.lastSavedID)
        XCTAssertTrue(service.canRetrySave)
        XCTAssertTrue(service.notice?.contains(tr("rec.recovery.saveFailed", ["count": "1"])) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.metadataURL.path))
        try FileManager.default.removeItem(at: blockedManifest)
        await service.recoverPending(retry: true)
        XCTAssertEqual(service.lastSavedID, draft.id)
        XCTAssertFalse(service.canRetrySave)
        await store.delete(ids: [draft.id])
    }

    func testMixedRecoveryDoesNotHideInvalidRecordingBehindSuccess() async throws {
        let valid = try makeDraft(), invalid = try makeDraft()
        let service = AudioRecorderService(store: store, pendingDrafts: { [valid, invalid] })
        defer { valid.remove(); invalid.remove() }
        try writeAudio(to: valid.audioURL)
        try Data([1, 2, 3]).write(to: invalid.audioURL)
        await service.recoverPending(retry: true)
        XCTAssertEqual(service.lastSavedID, valid.id)
        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.canRetrySave)
        XCTAssertTrue(service.notice?.contains(tr("rec.recovery.saved", ["count": "1"])) == true)
        XCTAssertTrue(service.notice?.contains(tr("rec.recovery.noAudio", ["count": "1"])) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.metadataURL.path))
        await store.delete(ids: [valid.id])
    }
}
