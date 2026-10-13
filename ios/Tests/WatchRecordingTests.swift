import XCTest
@testable import Workdeck

final class WatchRecordingTests: XCTestCase {
    private func recording(binding: String = "account-a") -> WatchRecording {
        WatchRecording(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000_000),
            destination: WatchDestination(binding: binding, deviceId: "desktop-a", deviceName: "Mac A",
                key: "project-a", name: "Original project", projectUid: "cloud-a"),
            deviceModel: "Apple Watch", osVersion: "watchOS", appVersion: "test", complete: true)
    }

    func testContractFixtureDecodesWithTheSharedWatchModel() throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixtures", withExtension: nil))
        let value = try JSONDecoder().decode(WatchRecording.self,
            from: Data(contentsOf: root.appendingPathComponent("watch-recording.json")))
        XCTAssertTrue(value.complete)
        XCTAssertEqual(value.destination?.deviceId, "desktop-a")
        XCTAssertEqual(value.destination?.key, "project-a")
        XCTAssertEqual(value.deviceModel, "Apple Watch")
    }

    func testInboxCopiesBeforeCallbackFileDisappearsAndSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: source)
        let value = recording()
        let inbox = WatchRecordingStore(root: root.appendingPathComponent("inbox"))
        try inbox.stage(value, from: source)
        try FileManager.default.removeItem(at: source)
        let restarted = WatchRecordingStore(root: inbox.root)
        XCTAssertEqual(try restarted.pending().map(\.id), [value.id])
        XCTAssertEqual(try Data(contentsOf: restarted.audioURL(value.id)), Data([1, 2, 3, 4]))
        XCTAssertFalse(restarted.hasReceipt(value.id))
        try restarted.markReceived(value.id)
        try restarted.acknowledge(value.id)
        XCTAssertTrue(try restarted.pending().isEmpty)
        XCTAssertTrue(restarted.hasReceipt(value.id), "A retry must not resurrect a user-deleted recording")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.audioURL(value.id).path))
    }

    func testDuplicateDeliveryPreservesUploadedStateAndOriginalProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchRecordingStore(root: root.appendingPathComponent("inbox"))
        let value = recording()
        try inbox.save(value)
        try Data([1, 2, 3]).write(to: inbox.audioURL(value.id))
        let store = EvidenceStore(root: root.appendingPathComponent("evidence"))
        let first = try await store.saveWatchRecording(value, audioURL: inbox.audioURL(value.id), currentBinding: "account-a")
        try await store.updateState(first.id, to: .uploaded)
        let duplicate = try await store.saveWatchRecording(value, audioURL: inbox.audioURL(value.id), currentBinding: "account-b")
        XCTAssertEqual(duplicate.state, .uploaded)
        XCTAssertEqual(duplicate.project?.key, "project-a")
        XCTAssertEqual(duplicate.project?.projectUid, "cloud-a")
        XCTAssertEqual(duplicate.watchAccountBinding, "account-a")
        XCTAssertEqual(duplicate.manifest.deviceModel, "Apple Watch")
        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 1)
    }

    func testChangedAccountDoesNotAdoptPhoneCurrentProjectAndUserCanAssign() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchRecordingStore(root: root.appendingPathComponent("inbox"))
        let value = recording()
        try inbox.save(value)
        try Data([1, 2, 3]).write(to: inbox.audioURL(value.id))
        let store = EvidenceStore(root: root.appendingPathComponent("evidence"))
        let item = try await store.saveWatchRecording(value, audioURL: inbox.audioURL(value.id), currentBinding: "account-b")
        XCTAssertNil(item.project)
        let claimedBeforeMove = try await store.claimNextUpload()
        XCTAssertNil(claimedBeforeMove)
        try await store.moveToProject(item.id, RelayProject(deviceId: "desktop-b", deviceName: "Mac B", key: "project-b", name: "New"), currentWatchBinding: "account-b")
        let claimedAfterMove = try await store.claimNextUpload(currentWatchBinding: "account-b")
        XCTAssertEqual(claimedAfterMove?.project?.key, "project-b")
        XCTAssertTrue(claimedAfterMove?.uploadAttempted == true)
    }

    func testAccountBoundUploadIsNotClaimedByAnotherLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchRecordingStore(root: root.appendingPathComponent("inbox"))
        let value = recording(binding: "not-the-current-login")
        try inbox.save(value)
        try Data([1, 2, 3]).write(to: inbox.audioURL(value.id))
        let store = EvidenceStore(root: root.appendingPathComponent("evidence"))
        _ = try await store.saveWatchRecording(value, audioURL: inbox.audioURL(value.id), currentBinding: "not-the-current-login")
        let claimed = try await store.claimNextUpload()
        XCTAssertNil(claimed)
        try await store.moveToProject(value.id,
            RelayProject(deviceId: "desktop-a", deviceName: "Mac A", key: "moved", name: "Moved"),
            currentWatchBinding: "not-the-current-login")
        let afterMove = try await store.claimNextUpload(currentWatchBinding: "another-login")
        XCTAssertNil(afterMove, "Manual moves must not remove Watch account ownership")
        let stored = try await store.loadAll()
        XCTAssertEqual(stored.first?.watchAccountBinding, "not-the-current-login")
        XCTAssertEqual(stored.first?.state, .failed)
    }

    func testFailedStageDoesNotCommitMetadataAndIncompleteRecordingCannotImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = WatchRecordingStore(root: root)
        var value = recording()
        XCTAssertThrowsError(try inbox.stage(value, from: root.appendingPathComponent("missing")))
        XCTAssertTrue(try inbox.pending().isEmpty)
        value.complete = false
        try inbox.save(value)
        try Data([1]).write(to: inbox.audioURL(value.id))
        do {
            _ = try await EvidenceStore(root: root.appendingPathComponent("evidence"))
                .saveWatchRecording(value, audioURL: inbox.audioURL(value.id), currentBinding: "account-a")
            XCTFail("Never acknowledge incomplete audio")
        } catch { XCTAssertFalse(inbox.hasReceipt(value.id)) }
    }
}
