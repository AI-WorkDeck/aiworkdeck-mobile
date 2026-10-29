// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class ArchiveMoveTests: XCTestCase {
    private let a = RelayProject(deviceId: "a", deviceName: "A", key: "1", name: "Alpha")
    private let b = RelayProject(deviceId: "b", deviceName: "B", key: "2", name: "Beta")
    private let account = ArchiveMoveAccount(binding: "test-account-a", baseURL: URL(string: "https://unit.invalid")!, sessionID: "test-session")

    private func saved(_ store: EvidenceStore, state: TransferState = .arrived) async throws -> CaptureItem {
        let item = try await store.save(data: Data([1, 2, 3, 4]), kind: .audio,
            capturedAt: Date(timeIntervalSince1970: 100), location: nil,
            device: DeviceFacts(model: "fixture", osVersion: "fixture", appVersion: "fixture"), project: a)
        _ = try await store.claimNextUpload(currentWatchBinding: account.binding)
        try await store.updateState(item.id, to: state, progress: 1)
        return item
    }

    private func loaded(_ store: EvidenceStore, _ id: UUID) async throws -> CaptureItem {
        let result = try await store.archiveMoveItem(id)
        return try XCTUnwrap(result)
    }

    func testPersistBeforeRegistrationAndOnlyDoneChangesProjectAndRemoteIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        do { _ = try await store.beginArchiveMove(item.id, target: a, accountBinding: account.binding); XCTFail("same project") } catch {}
        let move = try await store.beginArchiveMove(item.id, target: b, accountBinding: account.binding)
        let reloaded = try await loaded(EvidenceStore(root: root), item.id)
        XCTAssertEqual(reloaded.archiveMove?.requestID, move.requestID)
        XCTAssertEqual(reloaded.archiveMove?.targetClientMediaID, move.targetClientMediaID)
        XCTAssertEqual(reloaded.project, a)
        XCTAssertFalse(try XCTUnwrap(reloaded.archiveMove).registered)
        for state in [ArchiveMove.Status.waitingTarget, .waitingSource, .done] {
            try await store.applyArchiveMoveReply(item.id, requestID: move.requestID, reply:
                ArchiveMoveReply(requestId: move.requestID, status: state, targetClientMediaId: move.targetClientMediaID, error: ""))
            let current = try await loaded(EvidenceStore(root: root), item.id)
            XCTAssertNil(current.archiveMove?.lastError)
            XCTAssertEqual(current.project, state == .done ? b : a)
            XCTAssertEqual(current.effectiveClientMediaId, state == .done ? move.targetClientMediaID : item.id)
            XCTAssertEqual(current.id, item.id)
            XCTAssertEqual(current.manifest.clientMediaId, item.id)
            XCTAssertEqual(current.manifest.sha256, item.manifest.sha256)
            XCTAssertEqual(current.localURL, item.localURL)
            XCTAssertEqual(try Data(contentsOf: current.localURL), Data([1, 2, 3, 4]))
        }
        let next = try await store.beginArchiveMove(item.id, target: a, accountBinding: account.binding)
        XCTAssertEqual(next.sourceClientMediaID, move.targetClientMediaID)
        XCTAssertNotEqual(next.requestID, move.requestID)
        try await store.applyArchiveMoveReply(item.id, requestID: move.requestID, reply:
            ArchiveMoveReply(requestId: move.requestID, status: .done, targetClientMediaId: move.targetClientMediaID, error: nil))
        let afterOldReply = try await loaded(store, item.id)
        XCTAssertEqual(afterOldReply.archiveMove?.requestID, next.requestID)
        XCTAssertEqual(afterOldReply.archiveMove?.status, .waitingTarget)
        XCTAssertEqual(afterOldReply.project, b)
    }

    func testActiveMoveBlocksDeleteCopyRerouteAndOrdinaryUploadClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store, state: .waiting)
        _ = try await store.beginArchiveMove(item.id, target: b, accountBinding: account.binding)
        let claimed = try await store.claimNextUpload(currentWatchBinding: account.binding)
        XCTAssertNil(claimed)
        let deleted = await store.delete(ids: [item.id])
        XCTAssertFalse(deleted)
        try await store.updateState(item.id, to: .arrived)
        let retained = try await loaded(store, item.id)
        XCTAssertEqual(retained.state, .waiting)
        do { _ = try await store.beginArchiveMove(item.id, target: b, accountBinding: account.binding); XCTFail("duplicate move") } catch {}
        do { try await store.moveToProject(item.id, b); XCTFail("local reroute") } catch {}
        do { _ = try await store.copyToProject(item.id, b); XCTFail("copy during move") } catch {}
        do { try await store.purgeMedia(item.id); XCTFail("purge during move") } catch {}
        XCTAssertEqual(try Data(contentsOf: item.localURL), Data([1, 2, 3, 4]))
    }

    func testLostRegistrationResponseReusesBothIDsBeforeUploading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        let service = MoveServiceFixture()
        await service.failRegistrationOnce(.unknown)
        let account = account
        var queue = ArchiveMoveQueue(store: store, service: service, currentAccount: { account })
        try await queue.begin(item.id, target: b)
        await queue.kick()
        let afterLoss = try await loaded(store, item.id)
        XCTAssertFalse(try XCTUnwrap(afterLoss.archiveMove).registered)
        XCTAssertTrue(afterLoss.moveBlocksMutation)
        var calls = await service.calls
        XCTAssertEqual(calls.map(\.kind), ["register"])
        queue = ArchiveMoveQueue(store: EvidenceStore(root: root), service: service, currentAccount: { account })
        await queue.kick()
        calls = await service.calls
        XCTAssertEqual(calls.map(\.kind), ["register", "register", "upload", "status"])
        XCTAssertEqual(Set(calls.map(\.requestID)).count, 1)
        XCTAssertEqual(Set(calls.map(\.targetID)).count, 1)
        let current = try await loaded(store, item.id)
        XCTAssertEqual(current.archiveMove?.status, .waitingSource)
        XCTAssertEqual(current.project, a)
        XCTAssertEqual(calls.last?.sourceURL, item.localURL)
    }

    func testLostTargetUploadResponseRetriesSameBytesAndIDWithoutReregistering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        let service = MoveServiceFixture()
        await service.failUploadOnce()
        let account = account
        let queue = ArchiveMoveQueue(store: store, service: service, currentAccount: { account })
        try await queue.begin(item.id, target: b)
        await queue.kick()
        var current = try await loaded(store, item.id)
        XCTAssertEqual(current.archiveMove?.registered, true)
        XCTAssertEqual(current.archiveMove?.targetUploaded, false)
        let restarted = ArchiveMoveQueue(store: EvidenceStore(root: root), service: service, currentAccount: { account })
        await restarted.kick()
        let calls = await service.calls
        XCTAssertEqual(calls.map(\.kind), ["register", "upload", "status", "upload", "status"])
        XCTAssertEqual(Set(calls.map(\.targetID)).count, 1)
        current = try await loaded(store, item.id)
        XCTAssertEqual(current.archiveMove?.targetUploaded, true)
        XCTAssertEqual(current.project, a)
        await restarted.kick()
        let allCalls = await service.calls
        XCTAssertEqual(allCalls.filter { $0.kind == "upload" }.count, 2)
    }

    func testServerFailureRequiresManualRetryOfOriginalRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        let service = MoveServiceFixture()
        await service.setAfterUpload(.failed)
        let account = account
        let queue = ArchiveMoveQueue(store: store, service: service, currentAccount: { account })
        try await queue.begin(item.id, target: b)
        await queue.kick()
        let failed = try await loaded(store, item.id)
        XCTAssertEqual(failed.archiveMove?.status, .failed)
        await queue.kick()
        var calls = await service.calls
        XCTAssertEqual(calls.map(\.kind), ["register", "upload", "status"])
        await service.setRetryStatus(.waitingSource)
        try await queue.retry(item.id)
        await queue.kick()
        calls = await service.calls
        XCTAssertEqual(calls.last?.kind, "retry")
        XCTAssertEqual(Set(calls.map(\.requestID)).count, 1)
        await service.setStatus(.done)
        await queue.kick()
        let done = try await loaded(store, item.id)
        XCTAssertEqual(done.project, b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.localURL.path))
    }

    func testExplicitNoJobRejectionAllowsReselectAndDeleteWhileUnknownErrorDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        let service = MoveServiceFixture()
        await service.failRegistrationOnce(.rejected)
        let account = account
        let queue = ArchiveMoveQueue(store: store, service: service, currentAccount: { account })
        try await queue.begin(item.id, target: b)
        await queue.kick()
        let rejected = try await loaded(store, item.id)
        XCTAssertFalse(rejected.moveBlocksMutation)
        XCTAssertTrue(rejected.canRequestArchiveMove)
        let oldID = rejected.archiveMove?.requestID
        try await queue.begin(item.id, target: b)
        let replacement = try await loaded(store, item.id)
        XCTAssertNotEqual(replacement.archiveMove?.requestID, oldID)
        await service.failRegistrationOnce(.rejected)
        await queue.kick()
        let deleted = await store.delete(ids: [item.id])
        XCTAssertTrue(deleted)
    }

    func testAccountChangeAfterRegisterOrUploadStopsNextStepAndOldResponseMutation() async throws {
        for switchAt in ["register", "upload", "status"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = EvidenceStore(root: root)
            let item = try await saved(store)
            let box = MoveAccountBox(account)
            let service = MoveServiceFixture()
            await service.switchAccount(at: switchAt) { box.set(nil) }
            let queue = ArchiveMoveQueue(store: store, service: service, currentAccount: { box.get() })
            try await queue.begin(item.id, target: b)
            await queue.kick()
            let current = try await loaded(store, item.id)
            XCTAssertEqual(current.project, a)
            XCTAssertEqual(current.archiveMove?.registered, switchAt != "register")
            XCTAssertEqual(current.archiveMove?.targetUploaded, switchAt == "status")
            let calls = await service.calls
            XCTAssertEqual(calls.last?.kind, switchAt)
            XCTAssertTrue(calls.allSatisfy { $0.account == account })
            await queue.kick()
            let callsAfterLogout = await service.calls
            XCTAssertEqual(callsAfterLogout.count, calls.count)
            box.set(ArchiveMoveAccount(binding: "other-account", baseURL: account.baseURL, sessionID: "other-session"))
            await queue.kick()
            let callsAfterOtherLogin = await service.calls
            XCTAssertEqual(callsAfterOtherLogin.count, calls.count)
            box.set(account)
            await queue.kick()
            let resumed = try await loaded(store, item.id)
            XCTAssertEqual(resumed.archiveMove?.requestID, current.archiveMove?.requestID)
        }
    }

    func testMismatchedReplyCannotCommitAndMissingOrCorruptOriginalCannotRegister() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        let move = try await store.beginArchiveMove(item.id, target: b, accountBinding: account.binding)
        for reply in [ArchiveMoveReply(requestId: UUID(), status: .done, targetClientMediaId: move.targetClientMediaID, error: nil),
                      ArchiveMoveReply(requestId: move.requestID, status: .done, targetClientMediaId: UUID(), error: nil)] {
            do { try await store.applyArchiveMoveReply(item.id, requestID: move.requestID, reply: reply); XCTFail("mismatch") } catch {}
        }
        let current = try await loaded(store, item.id)
        XCTAssertEqual(current.project, a)
        for corrupt in [false, true] {
            let other = try await saved(store)
            if corrupt { try Data([9]).write(to: other.localURL) }
            else { try FileManager.default.removeItem(at: other.localURL) }
            do { _ = try await store.beginArchiveMove(other.id, target: b, accountBinding: account.binding); XCTFail("unavailable bytes") } catch {}
            let retained = try await loaded(store, other.id)
            XCTAssertNil(retained.archiveMove)
        }
    }
    func testRegistrationOnlyUnlocksForExplicitNoJobKindAndNeverFor5xx() throws {
        for (status, body, rejected) in [
            (200, #"{"code":1,"kind":"MOVE_NOT_REGISTERED","message":"expired"}"#, true),
            (400, #"{"code":1,"kind":"MOVE_NOT_REGISTERED"}"#, true),
            (500, #"{"code":1,"kind":"MOVE_NOT_REGISTERED"}"#, false),
            (200, #"{"code":1,"message":"unknown transaction result"}"#, false),
            (404, #"{"code":1,"message":"not found"}"#, false),
            (200, "invalid body", false)
        ] {
            do {
                _ = try API.decodeMoveResponse(Data(body.utf8), statusCode: status, registration: true)
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error is ArchiveMoveRegistrationRejected, rejected, "HTTP \(status) \(body)")
            }
        }
        let body = #"{"code":1,"kind":"MOVE_NOT_REGISTERED"}"#
        XCTAssertThrowsError(try API.decodeMoveResponse(Data(body.utf8), statusCode: 200, registration: false)) {
            XCTAssertFalse($0 is ArchiveMoveRegistrationRejected)
        }
    }

    func testExplicitRetryCanReuploadExpiredTargetWithSameIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let item = try await saved(store)
        let service = MoveServiceFixture()
        await service.setAfterUpload(.failed)
        let account = account
        let queue = ArchiveMoveQueue(store: store, service: service, currentAccount: { account })
        try await queue.begin(item.id, target: b)
        await queue.kick()
        await service.setRetryStatus(.waitingTarget)
        await service.setAfterUpload(.waitingSource)
        try await queue.retry(item.id)
        await queue.kick()
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0.kind == "upload" }.count, 2)
        XCTAssertEqual(Set(calls.map(\.targetID)).count, 1)
        let current = try await loaded(store, item.id)
        XCTAssertEqual(current.archiveMove?.status, .waitingSource)
        XCTAssertEqual(current.project, a)
    }

    func testOnlyVerifiedStableAccountBindingSurvivesSessionRefresh() throws {
        let suite = "archive-move-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = account.baseURL
        XCTAssertNil(WatchAccountScope.stableBinding(session: "old-session", baseURL: base, defaults: defaults))
        WatchAccountScope.rememberVerifiedUser(7, session: "old-session", baseURL: base, defaults: defaults)
        let stable = try XCTUnwrap(WatchAccountScope.stableBinding(session: "old-session", baseURL: base, defaults: defaults))
        XCTAssertNil(WatchAccountScope.stableBinding(session: "new-session", baseURL: base, defaults: defaults))
        WatchAccountScope.rememberVerifiedUser(7, session: "new-session", baseURL: base, defaults: defaults)
        XCTAssertEqual(WatchAccountScope.stableBinding(session: "new-session", baseURL: base, defaults: defaults), stable)
        XCTAssertNil(WatchAccountScope.stableBinding(session: "new-session", baseURL: URL(string: "https://other.invalid")!, defaults: defaults))
        WatchAccountScope.rememberVerifiedUser(8, session: "other-user-session", baseURL: base, defaults: defaults)
        XCTAssertNotEqual(WatchAccountScope.stableBinding(session: "other-user-session", baseURL: base, defaults: defaults), stable)
    }

}

private final class MoveAccountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var account: ArchiveMoveAccount?
    init(_ account: ArchiveMoveAccount?) { self.account = account }
    func get() -> ArchiveMoveAccount? { lock.lock(); defer { lock.unlock() }; return account }
    func set(_ value: ArchiveMoveAccount?) { lock.lock(); defer { lock.unlock() }; account = value }
}

private actor MoveServiceFixture: ArchiveMoveServing {
    enum Failure { case unknown, rejected }
    struct Call: Sendable {
        let kind: String
        let requestID: UUID
        let targetID: UUID
        let account: ArchiveMoveAccount
        let sourceURL: URL?
    }
    private(set) var calls: [Call] = []
    private var registrationFailure: Failure?
    private var uploadFailure = false
    private var status: ArchiveMove.Status = .waitingTarget
    private var afterUpload: ArchiveMove.Status = .waitingSource
    private var retryStatus: ArchiveMove.Status = .waitingSource
    private var switchAt: String?
    private var onSwitch: (@Sendable () -> Void)?
    private var sourceURL: URL?
    func failRegistrationOnce(_ failure: Failure) { registrationFailure = failure }
    func failUploadOnce() { uploadFailure = true }
    func setStatus(_ state: ArchiveMove.Status) { status = state }
    func setAfterUpload(_ state: ArchiveMove.Status) { afterUpload = state }
    func setRetryStatus(_ state: ArchiveMove.Status) { retryStatus = state }
    func switchAccount(at step: String, action: @escaping @Sendable () -> Void) { switchAt = step; onSwitch = action }
    private func record(_ kind: String, _ move: ArchiveMove, _ account: ArchiveMoveAccount) {
        calls.append(Call(kind: kind, requestID: move.requestID, targetID: move.targetClientMediaID, account: account, sourceURL: sourceURL))
        if switchAt == kind { onSwitch?(); onSwitch = nil }
    }
    private func reply(_ move: ArchiveMove) -> ArchiveMoveReply {
        ArchiveMoveReply(requestId: move.requestID, status: status, targetClientMediaId: move.targetClientMediaID,
                         error: status == .failed ? "fixture failure" : nil)
    }
    func registerMove(_ move: ArchiveMove, account: ArchiveMoveAccount) async throws -> ArchiveMoveReply {
        record("register", move, account)
        if let failure = registrationFailure {
            registrationFailure = nil
            if failure == .rejected { throw ArchiveMoveRegistrationRejected(message: "fixture rejection") }
            throw URLError(.networkConnectionLost)
        }
        return reply(move)
    }
    func moveStatus(_ move: ArchiveMove, account: ArchiveMoveAccount) async throws -> ArchiveMoveReply {
        record("status", move, account); return reply(move)
    }
    func retryMove(_ move: ArchiveMove, account: ArchiveMoveAccount) async throws -> ArchiveMoveReply {
        record("retry", move, account); status = retryStatus; return reply(move)
    }
    func uploadMoveTarget(_ item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount) async throws {
        sourceURL = item.localURL
        record("upload", move, account)
        if uploadFailure { uploadFailure = false; throw URLError(.networkConnectionLost) }
        status = afterUpload
    }
}
