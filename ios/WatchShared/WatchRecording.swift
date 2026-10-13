import Foundation

/// No credentials cross WatchConnectivity. The opaque binding only prevents
/// an old recording from being uploaded by a different phone login/region.
struct WatchDestination: Codable, Equatable, Sendable {
    let binding: String
    let deviceId: String
    let deviceName: String?
    let key: String
    let name: String
    let projectUid: String?
}

struct WatchContext: Codable, Sendable {
    let destination: WatchDestination?
    let locale: String
}

struct WatchRecording: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let destination: WatchDestination?
    let deviceModel: String
    let osVersion: String
    let appVersion: String
    var complete: Bool
}

/// Both the Watch outbox and iPhone inbox survive suspension/termination.
/// Locked because WCSession file callbacks must copy synchronously before return.
final class WatchRecordingStore: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()

    init(root: URL) { self.root = root }

    static func directory(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    func audioURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id).m4a") }
    private func metadataURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id).json") }

    func save(_ recording: WatchRecording) throws {
        lock.lock(); defer { lock.unlock() }
        try prepare()
        try write(recording)
    }

    /// Audio first, then metadata. A failed import is never acknowledged.
    func stage(_ recording: WatchRecording, from source: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try prepare()
        let destination = audioURL(recording.id)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = root.appendingPathComponent(UUID().uuidString + ".incoming")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try write(recording)
    }

    func hasReceipt(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id).receipt").path)
    }

    /// iPhone tombstone prevents a lost acknowledgement from resurrecting an
    /// already imported recording that the user subsequently deleted.
    func markReceived(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try prepare()
        try Data().write(to: root.appendingPathComponent("\(id).receipt"), options: .atomic)
    }

    func pending() throws -> [WatchRecording] {
        lock.lock(); defer { lock.unlock() }
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(WatchRecording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Called only after the receiving app has durably committed the recording.
    func acknowledge(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for url in [metadataURL(id), audioURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func write(_ recording: WatchRecording) throws {
        try JSONEncoder().encode(recording).write(to: metadataURL(recording.id),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
