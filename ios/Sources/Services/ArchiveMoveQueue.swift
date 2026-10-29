// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Resumes the same persisted transaction after an unknown network outcome.
/// A target delivery receipt alone never authorizes a local project change.
actor ArchiveMoveQueue {
    static let shared = ArchiveMoveQueue(store: .shared, service: API.shared)
    private let store: EvidenceStore
    private let service: any ArchiveMoveServing
    private let currentAccount: @Sendable () -> ArchiveMoveAccount?
    private var onChange: (@Sendable () async -> Void)?
    private var running = false
    private var runAgain = false

    init(store: EvidenceStore, service: any ArchiveMoveServing,
         currentAccount: @escaping @Sendable () -> ArchiveMoveAccount? = { .current }) {
        self.store = store; self.service = service; self.currentAccount = currentAccount
    }

    func configure(onChange: (@Sendable () async -> Void)?) { self.onChange = onChange }

    func begin(_ id: UUID, target: RelayProject) async throws {
        guard let account = currentAccount() else { throw APIError(message: tr("queue.moveAccountChanged")) }
        let provider = currentAccount
        _ = try await store.beginArchiveMove(id, target: target, accountBinding: account.binding,
                                             accountIsCurrent: { provider() == account })
        await onChange?()
    }

    func retry(_ id: UUID) async throws {
        guard let account = currentAccount(), let item = try await store.archiveMoveItem(id),
              let move = item.archiveMove, move.accountBinding == account.binding else {
            throw APIError(message: tr("queue.moveAccountChanged"))
        }
        let provider = currentAccount
        try await store.updateArchiveMove(id, requestID: move.requestID,
                                          accountIsCurrent: { provider() == account }) {
            $0.retryRequested = true
            $0.registrationRejected = false
            $0.lastError = nil
        }
        await onChange?()
    }

    func kick() async {
        if running { runAgain = true; return }
        running = true
        defer { running = false }
        repeat {
            runAgain = false
            guard let account = currentAccount() else { return }
            let items = (try? await store.loadAll()) ?? []
            for item in items {
                guard currentAccount() == account else { return }
                guard let move = item.archiveMove, move.accountBinding == account.binding,
                      move.status != .done, !move.registrationRejected,
                      move.status != .failed || move.retryRequested else { continue }
                await advance(item, move: move, account: account)
            }
        } while runAgain
    }

    private func advance(_ item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount) async {
        let provider = currentAccount
        let isCurrent: @Sendable () -> Bool = { provider() == account }
        do {
            guard isCurrent() else { return }
            let reply: ArchiveMoveReply
            if !move.registered {
                // Registration must precede upload, including after a lost registration response.
                reply = try await service.registerMove(move, account: account)
            } else if move.retryRequested {
                reply = try await service.retryMove(move, account: account)
            } else {
                reply = try await service.moveStatus(move, account: account)
            }
            guard isCurrent() else { return }
            try await store.applyArchiveMoveReply(item.id, requestID: move.requestID, reply: reply,
                                                  accountIsCurrent: isCurrent)
            await onChange?()
            guard isCurrent(), let latest = try await store.archiveMoveItem(item.id),
                  let pending = latest.archiveMove, pending.requestID == move.requestID,
                  pending.status == .waitingTarget, !pending.targetUploaded else { return }
            guard FileManager.default.fileExists(atPath: latest.localURL.path) else {
                throw APIError(message: tr("queue.copyMissing"))
            }
            guard try EvidenceStore.sha256(of: latest.localURL) == pending.sha256 else {
                throw APIError(message: tr("queue.copyCorrupt"))
            }
            guard isCurrent() else { return }
            try await service.uploadMoveTarget(latest, move: pending, account: account)
            guard isCurrent() else { return }
            try await store.updateArchiveMove(item.id, requestID: move.requestID, accountIsCurrent: isCurrent) {
                $0.targetUploaded = true; $0.lastError = nil
            }
            await onChange?()
            guard isCurrent() else { return }
            let status = try await service.moveStatus(pending, account: account)
            guard isCurrent() else { return }
            try await store.applyArchiveMoveReply(item.id, requestID: move.requestID, reply: status,
                                                  accountIsCurrent: isCurrent)
            await onChange?()
        } catch {
            guard isCurrent() else { return }
            let message = error.localizedDescription
            let rejected = !move.registered && error is ArchiveMoveRegistrationRejected
            try? await store.updateArchiveMove(item.id, requestID: move.requestID, accountIsCurrent: isCurrent) {
                $0.lastError = message
                if rejected { $0.registrationRejected = true; $0.status = .failed; $0.retryRequested = false }
            }
            await onChange?()
        }
    }
}
