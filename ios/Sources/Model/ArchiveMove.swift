import Foundation

/// The local evidence identity never changes. These IDs describe only the remote move.
struct ArchiveMove: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case waitingTarget = "WAITING_TARGET", waitingSource = "WAITING_SOURCE"
        case done = "DONE", failed = "FAILED"
        var caption: String {
            switch self {
            case .waitingTarget: tr("queue.moveWaitingTarget")
            case .waitingSource: tr("queue.moveWaitingSource")
            case .failed: tr("queue.moveFailed")
            case .done: TransferState.arrived.caption
            }
        }
    }
    let requestID: UUID
    let sourceClientMediaID: UUID
    let targetClientMediaID: UUID
    let source: RelayProject
    let target: RelayProject
    let sha256: String
    let fileSize: Int64
    let accountBinding: String
    var registered = false
    var targetUploaded = false
    var status: Status = .waitingTarget
    var lastError: String? = nil
    var retryRequested = false
    /// Only the server's explicit MOVE_NOT_REGISTERED rejection unlocks a failed registration.
    var registrationRejected = false
    var blocksMutation: Bool { status != .done && !registrationRejected }
}

struct ArchiveMoveReply: Decodable, Sendable {
    let requestId: UUID
    let status: ArchiveMove.Status
    let targetClientMediaId: UUID
    let error: String?
}

/// Credentials are frozen for each round, but never persisted in a move manifest.
struct ArchiveMoveAccount: Equatable, Sendable {
    let binding: String
    let baseURL: URL
    let sessionID: String
    static var current: ArchiveMoveAccount? {
        let baseURL = Backend.baseURL
        guard let sessionID = SessionStore.current,
              let binding = WatchAccountScope.binding(session: sessionID, baseURL: baseURL) else { return nil }
        return Self(binding: binding, baseURL: baseURL, sessionID: sessionID)
    }
}

struct ArchiveMoveRegistrationRejected: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ArchiveMoveServing: Sendable {
    func registerMove(_ move: ArchiveMove, account: ArchiveMoveAccount) async throws -> ArchiveMoveReply
    func moveStatus(_ move: ArchiveMove, account: ArchiveMoveAccount) async throws -> ArchiveMoveReply
    func retryMove(_ move: ArchiveMove, account: ArchiveMoveAccount) async throws -> ArchiveMoveReply
    func uploadMoveTarget(_ item: CaptureItem, move: ArchiveMove, account: ArchiveMoveAccount) async throws
}
