// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

/// 临时项目 is the cloud scratch project. Without persistent cloud storage the server refuses every
/// upload there (storageLimit), so those captures must return to the phone instead of failing.
final class ScratchUploadTests: XCTestCase {
    private let scratch = RelayProject(deviceId: "cloud", deviceName: nil, key: "41", name: "临时项目",
                                       projectUid: "scratch-uid", isDefault: true, projectType: "SCRATCH")
    private let desktop = RelayProject(deviceId: "mac", deviceName: "Mac", key: "7", name: "包晴天")
    private let device = DeviceFacts(model: "test", osVersion: "test", appVersion: "test")

    private func store() -> (EvidenceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (EvidenceStore(root: root), root)
    }

    func testScratchCaptureWithoutCloudStorageStaysLocalAndDesktopStillUploads() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try await store.save(data: Data([1]), kind: .photo, capturedAt: Date(), location: nil, device: device, project: scratch)
        let audio = try await store.save(data: Data([2]), kind: .audio, capturedAt: Date(), location: nil, device: device, project: desktop)

        let claimed = try await store.claimNextUpload(scratchWritable: false)
        XCTAssertEqual(claimed?.id, audio.id, "desktop-linked uploads are untouched")
        let none = try await store.claimNextUpload(scratchWritable: false)
        XCTAssertNil(none)

        let reloaded = try await EvidenceStore(root: root).loadAll()
        let local = try XCTUnwrap(reloaded.first { $0.id == photo.id })
        XCTAssertNil(local.project)
        XCTAssertEqual(local.state, .waiting)
        XCTAssertNil(local.lastError)
        XCTAssertTrue(local.canMoveToProject, "never attempted, so it can still be filed directly")
    }

    func testStuckFailedScratchUploadBecomesUnassignedOnRetry() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await store.save(data: Data([3]), kind: .photo, capturedAt: Date(), location: nil, device: device, project: scratch)
        // The 1.12.0 failure: claimed, rejected with storageLimit, left failed.
        _ = try await store.claimNextUpload()
        try await store.updateState(item.id, to: .failed, error: "云端写入暂不可用或已达到空间安全上限")

        let none = try await store.claimNextUpload(scratchWritable: false)
        XCTAssertNil(none)
        let all = try await store.loadAll()
        let local = try XCTUnwrap(all.first { $0.id == item.id })
        XCTAssertNil(local.project)
        XCTAssertEqual(local.state, .waiting)
        XCTAssertNil(local.lastError)
        XCTAssertTrue(local.uploadAttempted, "an attempted idempotency key is never silently rerouted")
        XCTAssertFalse(local.canMoveToProject)
    }

    func testSubscriberScratchUploadsStillClaimed() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await store.save(data: Data([4]), kind: .photo, capturedAt: Date(), location: nil, device: device, project: scratch)
        let claimed = try await store.claimNextUpload(scratchWritable: true)
        XCTAssertEqual(claimed?.id, item.id)
        XCTAssertEqual(claimed?.project?.isScratch, true)
    }

    func testPersistentWritableNeedsKnownFreeQuota() {
        func usage(_ used: Int64?, _ quota: Int64?, _ available: Bool? = nil) -> API.MediaUsage {
            API.MediaUsage(usedBytes: 0, quotaBytes: 200, persistentUsedBytes: used, persistentQuotaBytes: quota, persistentQuotaAvailable: available)
        }
        XCTAssertFalse(usage(9_000, 0).persistentCloudWritable, "the reported 9 KB / 0 bytes account")
        XCTAssertFalse(usage(0, nil).persistentCloudWritable)
        XCTAssertFalse(usage(0, 3_000, false).persistentCloudWritable)
        XCTAssertFalse(usage(3_000, 3_000).persistentCloudWritable)
        XCTAssertTrue(usage(9_000, 3_221_225_472).persistentCloudWritable)
    }
}
