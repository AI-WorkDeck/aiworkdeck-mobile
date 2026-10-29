import CryptoKit
import Foundation

/// 影像与归档信息的本地仓库。
///
/// 两条硬规矩：
/// 1. **原图只写应用沙盒，绝不进系统相册。** 手机丢了、相册被翻，尽调材料不在里面。
/// 2. **落盘顺序是「先原图、再算哈希、最后写 manifest」。** manifest 存在即代表这条
///    记录完整可信；中途崩溃只会留下孤儿原图，下次启动扫掉，不会产生「有记录但没哈希」
///    的半成品。
actor EvidenceStore {
    static let shared = EvidenceStore()

    // FileManager 不是 Sendable，但 FileManager.default 是线程安全的，
    // 且这里所有调用都在本 actor 内。存成属性会让它「逃出」actor 隔离，改为每次取。
    private var fm: FileManager { .default }

    /// 沙盒里的根目录。Application Support 不进 iCloud 备份也不被系统清理，
    /// 比 Caches 稳妥——现场照片丢了不可复现。
    private let rootOverride: URL?
    private lazy var root: URL = {
        if let rootOverride { return rootOverride }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FieldEvidence", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var b = base
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? b.setResourceValues(rv)
        return base
    }()

    private var mediaDir: URL { root.appendingPathComponent("media", isDirectory: true) }
    private var manifestDir: URL { root.appendingPathComponent("manifest", isDirectory: true) }

    init(root: URL? = nil) { self.rootOverride = root }

    private func ensureDirs() throws {
        for d in [mediaDir, manifestDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    // MARK: - 写入

    /// 存一条新采集。data 是相机直出的原始字节，不做任何再压缩——
    /// 压缩会改变哈希，取证链上说不清。
    func save(
        data: Data,
        kind: MediaKind,
        capturedAt: Date,
        location: (lat: Double, lon: Double, accuracy: Double)?,
        device: DeviceFacts,
        project: RelayProject?,
        id: UUID = UUID(),
        watchAccountBinding: String? = nil
    ) throws -> CaptureItem {
        try ensureDirs()

        let ext = Self.ext(for: kind)
        let url = mediaDir.appendingPathComponent("\(id.uuidString).\(ext)")

        // 1. 原图先落盘
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        // 2. 对落盘后的文件算哈希（不是对内存里的 data）——
        //    要证明的是「磁盘上这个文件」没被改过。
        let digest = try Self.sha256(of: url)

        let manifest = CaptureManifest(
            clientMediaId: id,
            sha256: digest,
            capturedAt: capturedAt,
            serverReceivedAt: nil,
            latitude: location?.lat,
            longitude: location?.lon,
            horizontalAccuracy: location?.accuracy,
            deviceModel: device.model,
            osVersion: device.osVersion,
            appVersion: device.appVersion,
            fromCamera: true,
            tsaToken: nil
        )

        // 3. manifest 最后写。它存在 == 这条记录完整。
        let item = CaptureItem(
            id: id, kind: kind, state: .waiting,
            manifest: manifest, localURL: url, progress: 0,
            lastError: nil, savedToAlbum: false, project: project,
            watchAccountBinding: watchAccountBinding
        )
        try writeManifest(item)
        return item
    }

    /// A retry after a crash must not create a second library entry or upload.
    func saveRecording(_ draft: RecordingDraft) throws -> CaptureItem {
        if let existing = try loadOne(draft.id) { return existing }
        let data = try Data(contentsOf: draft.audioURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return try save(data: data, kind: .audio, capturedAt: draft.startedAt,
                        location: draft.location, device: draft.device,
                        project: draft.project, id: draft.id)
    }

    /// A duplicate delivery must preserve upload state and the original destination.
    func saveWatchRecording(_ recording: WatchRecording, audioURL: URL,
                            currentBinding: String?) throws -> CaptureItem {
        if let existing = try loadOne(recording.id) { return existing }
        guard recording.complete else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let target = recording.destination.flatMap { destination -> RelayProject? in
            guard destination.binding == currentBinding else { return nil }
            return RelayProject(deviceId: destination.deviceId, deviceName: destination.deviceName,
                key: destination.key, name: destination.name, projectUid: destination.projectUid)
        }
        return try save(data: data, kind: .audio, capturedAt: recording.startedAt, location: nil,
            device: DeviceFacts(model: recording.deviceModel, osVersion: recording.osVersion,
                                appVersion: recording.appVersion),
            project: target, id: recording.id,
            watchAccountBinding: recording.destination?.binding ?? "")
    }

    /// Claim and project edits run in one actor without suspension, so an upload
    /// cannot send a stale destination while the user moves the item.
    func claimNextUpload(currentWatchBinding: String? = WatchAccountScope.current) throws -> CaptureItem? {
        for var item in try loadAll() where !item.moveBlocksMutation && item.state == .waiting && item.project != nil &&
            item.watchAccountBinding != nil && item.watchAccountBinding != currentWatchBinding {
            item.state = .failed
            item.lastError = tr("watch.accountChanged")
            try writeManifest(item)
        }
        guard var item = try loadAll().last(where: { !$0.moveBlocksMutation && $0.state == .waiting && $0.project != nil &&
            ($0.watchAccountBinding == nil || $0.watchAccountBinding == currentWatchBinding) }) else { return nil }
        item.state = .uploading
        item.uploadAttempted = true
        item.progress = 0
        item.lastError = nil
        try writeManifest(item)
        return item
    }

    func moveToProject(_ id: UUID, _ project: RelayProject, currentWatchBinding: String? = WatchAccountScope.current) throws {
        guard let item = try loadOne(id) else { throw APIError(message: tr("library.moveMissing")) }
        guard item.canMoveToProject else {
            throw APIError(message: tr("library.moveSynced"))
        }
        let updated = CaptureItem(
            id: item.id, kind: item.kind, state: .waiting, manifest: item.manifest,
            localURL: item.localURL, progress: 0, lastError: nil,
            savedToAlbum: item.savedToAlbum, project: project,
            watchAccountBinding: item.watchAccountBinding == nil ? nil : (currentWatchBinding ?? ""))
        try writeManifest(updated)
    }

    /// A sent item keeps its original receipt. Copy bytes into an independent
    /// transfer so the server's idempotency key cannot silently reroute it.
    func copyToProject(_ id: UUID, _ project: RelayProject,
                       currentWatchBinding: String? = WatchAccountScope.current) throws -> CaptureItem {
        guard let item = try loadOne(id) else { throw APIError(message: tr("library.moveMissing")) }
        guard !item.moveBlocksMutation else { throw APIError(message: tr("queue.moveInProgress")) }
        guard fm.fileExists(atPath: item.localURL.path) else { throw APIError(message: tr("queue.copyMissing")) }
        let copyID = UUID()
        let url = mediaDir.appendingPathComponent("\(copyID.uuidString).\(Self.ext(for: item.kind))")
        var saved = false
        defer { if !saved { try? fm.removeItem(at: url) } }
        try fm.copyItem(at: item.localURL, to: url)
        guard try Self.sha256(of: url) == item.manifest.sha256 else { throw APIError(message: tr("queue.copyCorrupt")) }
        let manifest = CaptureManifest(
            clientMediaId: copyID, sha256: item.manifest.sha256, capturedAt: item.capturedAt,
            serverReceivedAt: nil, latitude: item.manifest.latitude, longitude: item.manifest.longitude,
            horizontalAccuracy: item.manifest.horizontalAccuracy, deviceModel: item.manifest.deviceModel,
            osVersion: item.manifest.osVersion, appVersion: item.manifest.appVersion,
            fromCamera: item.manifest.fromCamera, tsaToken: item.manifest.tsaToken)
        let copy = CaptureItem(id: copyID, kind: item.kind, state: .waiting, manifest: manifest,
            localURL: url, progress: 0, lastError: nil, savedToAlbum: false, project: project,
            watchAccountBinding: item.watchAccountBinding == nil ? nil : (currentWatchBinding ?? ""))
        try writeManifest(copy)
        saved = true
        return copy
    }

    /// 用户主动删除：原图与记录一起删。记录留着而图没了，图集里会出现永远打不开的空格。
    @discardableResult
    func delete(ids: [UUID]) -> Bool {
        guard ids.allSatisfy({ (try? loadOne($0))?.moveBlocksMutation != true }) else { return false }
        for id in ids {
            guard let item = try? loadOne(id) else { continue }
            try? fm.removeItem(at: item.localURL)
            try? fm.removeItem(at: manifestDir.appendingPathComponent("\(id.uuidString).json"))
        }
        return true
    }

    func updateState(_ id: UUID, to state: TransferState, progress: Double = 0,
                     error: String? = nil) throws {
        guard var item = try? loadOne(id), !item.moveBlocksMutation else { return }
        item.state = state
        item.progress = progress
        // 成功时清掉旧的失败原因，否则界面会一直挂着上次那条已经不成立的错
        item.lastError = state == .failed ? error : nil
        try writeManifest(item)
    }

    func markSavedToAlbum(_ id: UUID) throws {
        guard var item = try? loadOne(id) else { return }
        item.savedToAlbum = true
        try writeManifest(item)
    }

    /// 桌面端确认落盘后调用：删掉本地原图，manifest 留着做本机台账。
    func purgeMedia(_ id: UUID) throws {
        guard let item = try? loadOne(id) else { return }
        guard !item.moveBlocksMutation else { throw APIError(message: tr("queue.moveInProgress")) }
        try? fm.removeItem(at: item.localURL)
    }

    func beginArchiveMove(_ id: UUID, target: RelayProject, accountBinding: String,
                          accountIsCurrent: @Sendable () -> Bool = { true }) throws -> ArchiveMove {
        guard accountIsCurrent() else { throw APIError(message: tr("queue.moveAccountChanged")) }
        guard var item = try loadOne(id) else { throw APIError(message: tr("library.moveMissing")) }
        guard !item.moveBlocksMutation else { throw APIError(message: tr("queue.moveInProgress")) }
        guard item.canRequestArchiveMove, let source = item.project else {
            throw APIError(message: tr("queue.moveUnavailable"))
        }
        guard !source.matches(target) else {
            throw APIError(message: tr("queue.moveSameProject"))
        }
        guard item.watchAccountBinding == nil || item.watchAccountBinding == accountBinding else {
            throw APIError(message: tr("queue.moveAccountChanged"))
        }
        guard fm.fileExists(atPath: item.localURL.path) else { throw APIError(message: tr("queue.copyMissing")) }
        guard try Self.sha256(of: item.localURL) == item.manifest.sha256 else {
            throw APIError(message: tr("queue.copyCorrupt"))
        }
        let size = try fm.attributesOfItem(atPath: item.localURL.path)[.size] as? NSNumber
        let move = ArchiveMove(requestID: UUID(), sourceClientMediaID: item.effectiveClientMediaId,
            targetClientMediaID: UUID(), source: source, target: target, sha256: item.manifest.sha256,
            fileSize: size?.int64Value ?? 0, accountBinding: accountBinding)
        item.archiveMove = move
        try writeManifest(item)
        return move
    }

    func archiveMoveItem(_ id: UUID) throws -> CaptureItem? { try loadOne(id) }

    func applyArchiveMoveReply(_ id: UUID, requestID: UUID, reply: ArchiveMoveReply,
                               accountIsCurrent: @Sendable () -> Bool = { true }) throws {
        guard accountIsCurrent(), var item = try loadOne(id), var move = item.archiveMove,
              move.requestID == requestID else { return }
        guard reply.requestId == move.requestID, reply.targetClientMediaId == move.targetClientMediaID else {
            throw APIError(message: tr("error.badResponse"))
        }
        // A late polling reply must never undo a completed transaction.
        guard move.status != .done else { return }
        // A manual retry may need the same target uploaded again after relay expiry.
        if move.retryRequested && reply.status == .waitingTarget { move.targetUploaded = false }
        move.registered = true
        move.registrationRejected = false
        move.status = reply.status
        move.lastError = reply.error
        move.retryRequested = false
        if reply.status == .waitingSource || reply.status == .done { move.targetUploaded = true }
        if reply.status == .done {
            item.project = move.target
            item.remoteClientMediaId = move.targetClientMediaID
            item.state = .arrived
            item.progress = 1
            item.lastError = nil
            // Bind future moves and uploads of the new remote receipt to its owner.
            item.watchAccountBinding = move.accountBinding
        }
        item.archiveMove = move
        try writeManifest(item)
    }

    func updateArchiveMove(_ id: UUID, requestID: UUID,
                           accountIsCurrent: @Sendable () -> Bool = { true },
                           change: @Sendable (inout ArchiveMove) -> Void) throws {
        guard accountIsCurrent(), var item = try loadOne(id), var move = item.archiveMove,
              move.requestID == requestID, move.status != .done else { return }
        change(&move)
        item.archiveMove = move
        try writeManifest(item)
    }

    // MARK: - 读取

    func loadAll() throws -> [CaptureItem] {
        try ensureDirs()
        let files = (try? fm.contentsOfDirectory(at: manifestDir, includingPropertiesForKeys: nil)) ?? []
        let items = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decode(at: $0) }
        return items.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 清理孤儿原图：有文件没 manifest，说明上次写到一半崩了。
    /// 这类文件没有哈希与采集环境，作为证据不成立，留着只会误导。
    func sweepOrphans() throws {
        try ensureDirs()
        let known = Set(try loadAll().map { $0.localURL.lastPathComponent })
        let files = (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where !known.contains(f.lastPathComponent) {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: - 私有

    private func loadOne(_ id: UUID) throws -> CaptureItem? {
        let u = manifestDir.appendingPathComponent("\(id.uuidString).json")
        guard fm.fileExists(atPath: u.path) else { return nil }
        return try decode(at: u)
    }

    private func decode(at url: URL) throws -> CaptureItem {
        let row = try JSONDecoder.iso.decode(StoredRow.self, from: Data(contentsOf: url))
        let ext = Self.ext(for: row.kind)
        return CaptureItem(
            id: row.manifest.clientMediaId,
            kind: row.kind,
            state: row.state,
            manifest: row.manifest,
            localURL: mediaDir.appendingPathComponent("\(row.manifest.clientMediaId.uuidString).\(ext)"),
            progress: row.progress,
            lastError: row.lastError,
            savedToAlbum: row.savedToAlbum ?? false,
            project: row.project,
            uploadAttempted: row.uploadAttempted ?? (row.project != nil),
            watchAccountBinding: row.watchAccountBinding,
            archiveMove: row.archiveMove, remoteClientMediaId: row.remoteClientMediaId
        )
    }

    private func writeManifest(_ item: CaptureItem) throws {
        let row = StoredRow(kind: item.kind, state: item.state, progress: item.progress,
                            manifest: item.manifest, lastError: item.lastError,
                            savedToAlbum: item.savedToAlbum, project: item.project,
                            uploadAttempted: item.uploadAttempted, watchAccountBinding: item.watchAccountBinding,
                            archiveMove: item.archiveMove, remoteClientMediaId: item.remoteClientMediaId)
        let u = manifestDir.appendingPathComponent("\(item.id.uuidString).json")
        try JSONEncoder.iso.encode(row).write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 落盘扩展名是存储层契约：写入与读取必须同源，否则 decode 会拼出不存在的路径。
    nonisolated static func ext(for kind: MediaKind) -> String {
        switch kind {
        case .photo: "jpg"
        case .video: "mov"
        case .audio: "m4a"
        }
    }

    /// 流式分块算哈希：现场录像可以到几百 MB，整份读进内存会被系统杀掉。
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct StoredRow: Codable {
    let kind: MediaKind
    let state: TransferState
    let progress: Double
    let manifest: CaptureManifest
    // 后加的两个字段用可选 + 默认值：老记录没有它们，解码不能因此整条失败
    var lastError: String?
    var savedToAlbum: Bool?
    /// 归档去向。未归类记录等待用户手动指定。
    var project: RelayProject?
    var uploadAttempted: Bool?
    var watchAccountBinding: String?
    var archiveMove: ArchiveMove?
    var remoteClientMediaId: UUID?
}

struct DeviceFacts: Sendable, Codable {
    let model: String
    let osVersion: String
    let appVersion: String
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
