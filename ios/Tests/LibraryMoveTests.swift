import XCTest
@testable import Workdeck

final class LibraryMoveTests: XCTestCase {
    private let a = RelayProject(deviceId: "device-a", deviceName: "Desktop", key: "7", name: "Same name")
    private let b = RelayProject(deviceId: "device-b", deviceName: "Desktop", key: "7", name: "Same name")

    func testUnassignedCaptureWaitsForExplicitMoveAndPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        for kind in [MediaKind.audio, .photo] {
            let bytes = Data([7, 8, 9])
            let item = try await store.save(data: bytes, kind: kind, capturedAt: Date(timeIntervalSince1970: 100),
                                           location: nil, device: DeviceFacts(model: "test", osVersion: "test", appVersion: "test"), project: nil)
            let unassigned = try await store.claimNextUpload()
            XCTAssertNil(unassigned)
            try await store.moveToProject(item.id, a)
            try await store.moveToProject(item.id, b)
            let restored = try await EvidenceStore(root: root).loadAll()
            let moved = try XCTUnwrap(restored.first { $0.id == item.id })
            XCTAssertEqual(moved.projectID, b.id)
            XCTAssertNotEqual(moved.projectID, a.id)
            XCTAssertEqual(moved.manifest.sha256, item.manifest.sha256)
            XCTAssertEqual(moved.capturedAt, item.capturedAt)
            XCTAssertEqual(moved.manifest.clientMediaId, item.manifest.clientMediaId)
            XCTAssertEqual(try Data(contentsOf: moved.localURL), bytes)
            let claimed = try await store.claimNextUpload()
            XCTAssertEqual(claimed?.projectID, b.id)
            XCTAssertEqual(claimed?.state, .uploading)
            await store.delete(ids: [item.id])
        }
    }

    func testLegacyUnassignedRecordsCanMoveButAssignedReceiptsStayBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        for project in [nil, a] {
            let item = try await store.save(data: Data([2]), kind: .photo, capturedAt: Date(), location: nil,
                                           device: DeviceFacts(model: "test", osVersion: "test", appVersion: "test"), project: project)
            let manifest = root.appendingPathComponent("manifest/\(item.id.uuidString).json")
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            legacy.removeValue(forKey: "uploadAttempted")
            try JSONSerialization.data(withJSONObject: legacy).write(to: manifest)
            let loaded = try await store.loadAll()
            let restored = try XCTUnwrap(loaded.first { $0.id == item.id })
            XCTAssertEqual(restored.canMoveToProject, project == nil)
            if project == nil { try await store.moveToProject(item.id, b) }
        }
    }

    func testUploadClaimPreventsMoveEvenAfterFailureOrRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await store.save(data: Data([1]), kind: .audio, capturedAt: Date(), location: nil,
                                       device: DeviceFacts(model: "test", osVersion: "test", appVersion: "test"), project: a)
        _ = try await store.claimNextUpload()
        for state in [TransferState.uploading, .uploaded, .arrived, .failed, .waiting] {
            try await store.updateState(item.id, to: state)
            do {
                try await EvidenceStore(root: root).moveToProject(item.id, b)
                XCTFail("An attempted upload must retain its destination: \(state)")
            } catch {}
            let restored = try await store.loadAll()
            XCTAssertEqual(restored.first?.projectID, a.id)
            XCTAssertEqual(restored.first?.state, state)
        }
    }

    func testCopyOfUploadedMediaHasIndependentIdentityAndPreservesOriginalEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        for kind in [MediaKind.photo, .video, .audio] {
            let bytes = Data([1, 3, 5, 7])
            let item = try await store.save(data: bytes, kind: kind, capturedAt: Date(timeIntervalSince1970: 100),
                location: (1, 2, 3), device: DeviceFacts(model: "Original device", osVersion: "original OS", appVersion: "1.8.0"), project: a)
            _ = try await store.claimNextUpload()
            try await store.updateState(item.id, to: .uploaded, progress: 1)
            let copy = try await store.copyToProject(item.id, b)
            XCTAssertNotEqual(copy.id, item.id)
            XCTAssertEqual(copy.manifest.clientMediaId, copy.id)
            XCTAssertNotEqual(copy.localURL, item.localURL)
            XCTAssertEqual(copy.projectID, b.id)
            XCTAssertEqual(copy.state, .waiting)
            XCTAssertFalse(copy.uploadAttempted)
            XCTAssertEqual(copy.manifest.sha256, item.manifest.sha256)
            XCTAssertEqual(copy.capturedAt, item.capturedAt)
            XCTAssertEqual(copy.manifest.latitude, item.manifest.latitude)
            XCTAssertEqual(copy.manifest.longitude, item.manifest.longitude)
            XCTAssertEqual(copy.manifest.horizontalAccuracy, item.manifest.horizontalAccuracy)
            XCTAssertEqual(copy.manifest.deviceModel, item.manifest.deviceModel)
            XCTAssertEqual(copy.manifest.appVersion, item.manifest.appVersion)
            XCTAssertNil(copy.manifest.serverReceivedAt)
            XCTAssertEqual(try Data(contentsOf: copy.localURL), bytes)
            let items = try await EvidenceStore(root: root).loadAll()
            let original = try XCTUnwrap(items.first { $0.id == item.id })
            XCTAssertEqual(original.projectID, a.id)
            XCTAssertEqual(original.state, .uploaded)
            XCTAssertTrue(original.uploadAttempted)
            XCTAssertEqual(try Data(contentsOf: original.localURL), bytes)
            let claimed = try await store.claimNextUpload()
            XCTAssertEqual(claimed?.id, copy.id)
            XCTAssertEqual(claimed?.projectID, b.id)
            await store.delete(ids: [copy.id])
            XCTAssertEqual(try Data(contentsOf: original.localURL), bytes)
        }
    }

    func testCopyDoesNotCreateAnEntryWhenOriginalIsMissingOrCorrupted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await store.save(data: Data([1]), kind: .photo, capturedAt: Date(), location: nil,
            device: DeviceFacts(model: "test", osVersion: "test", appVersion: "test"), project: a)
        try Data([2]).write(to: item.localURL)
        do { _ = try await store.copyToProject(item.id, b); XCTFail("Do not copy altered evidence") } catch {}
        var items = try await store.loadAll()
        XCTAssertEqual(items.map(\.id), [item.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("media"), includingPropertiesForKeys: nil).count, 1)
        try FileManager.default.removeItem(at: item.localURL)
        do { _ = try await store.copyToProject(item.id, b); XCTFail("Do not copy a missing original") } catch {}
        items = try await store.loadAll()
        XCTAssertEqual(items.map(\.id), [item.id])
    }

    func testCopyPreservesArrivedReceiptAndExplicitWatchAccountAssignment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await store.save(data: Data([4]), kind: .audio, capturedAt: Date(), location: nil,
            device: DeviceFacts(model: "watch", osVersion: "test", appVersion: "test"), project: a,
            watchAccountBinding: "account-a")
        _ = try await store.claimNextUpload(currentWatchBinding: "account-a")
        try await store.updateState(item.id, to: .arrived, progress: 1)
        let copy = try await store.copyToProject(item.id, b, currentWatchBinding: "account-b")
        XCTAssertEqual(copy.watchAccountBinding, "account-b")
        let items = try await store.loadAll()
        let original = try XCTUnwrap(items.first { $0.id == item.id })
        XCTAssertEqual(original.state, .arrived)
        XCTAssertEqual(original.watchAccountBinding, "account-a")
        let claimed = try await store.claimNextUpload(currentWatchBinding: "account-c")
        XCTAssertNil(claimed)
    }
}
