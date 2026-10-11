import Foundation
import CryptoKit

/// Account-bound client. The owner must close it when leaving the workspace or logging out.
actor ProjectFilesService: ProjectFilesServing {
    static let maximumPreviewBytes: Int64 = 200 * 1024 * 1024

    private let context: ProjectFilesContext
    private let session: URLSession
    private let pollingInterval: UInt64
    private let pollingAttempts: Int
    private let cacheDirectory: URL
    private let recoveryDirectory: URL
    private let noRedirect = ProjectFilesNoRedirect()
    private var closed = false
    private var desktopAvailability: [String: Bool] = [:]
    private var downloads: [UUID: Task<URL, Error>] = [:]
    private var previews: [UUID: Preview] = [:]
    private var bytesOnDisk: Int64 = 0
    private var ledger: [String: Pending]?

    private struct Pending: Codable {
        let pull: ProjectFilePull
        var transferID: Int64?
        var attempted = false
        var previewFile: String?
        var previewSize: Int64?
        var acknowledged = false
    }

    private struct Preview {
        let pull: ProjectFilePull
        let url: URL
        let size: Int64
    }

    init(context: ProjectFilesContext, session: URLSession = .shared,
         pollingInterval: UInt64 = 1_000_000_000, pollingAttempts: Int = 60,
         recoveryRoot: URL? = nil) {
        self.context = context
        self.session = session
        self.pollingInterval = pollingInterval
        self.pollingAttempts = pollingAttempts
        self.cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-preview-" + UUID().uuidString, isDirectory: true)
        let fingerprint = SHA256.hash(data: Data((context.baseURL.absoluteString + "\n" + context.sessionID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.recoveryDirectory = (recoveryRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectFileTransfers", isDirectory: true))
            .appendingPathComponent(fingerprint, isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: cacheDirectory) }

    func backupConsent() async throws -> BackupConsent {
        let data = try await response(request("/api/mobile/backup-consent"))
        return try decode(BackupConsent.self, data)
    }

    func setBackupConsent(enabled: Bool) async throws -> BackupConsent {
        var req = try request("/api/mobile/backup-consent", body: ["enabled": enabled, "consentVersion": ContractCapabilities.backupConsentVersion])
        req.httpMethod = "PUT"
        let data = try await response(req)
        return try decode(BackupConsent.self, data)
    }

    func projects() async throws -> [RelayProject] {
        let data = try await response(request("/api/mobile/catalog"))
        if let envelope = try? JSONDecoder().decode(CodeOnly.self, from: data), envelope.code != 0 {
            throw APIError(message: envelope.message ?? tr("files.error.response"))
        }
        return try decode([RelayProject].self, data)
    }

    func files(in project: RelayProject) async throws -> ProjectFileListing {
        var desktopOffline = desktopAvailability[project.legacyID].map { !$0 }
            ?? (project.locations?.first(where: { $0.alias == project.legacyID })?.online == false)
        if desktopOffline, !project.isCloud {
            if let refreshed = try? await projects().first(where: { $0.matches(project) }),
               let online = refreshed.locations?.first(where: { $0.alias == project.legacyID })?.online {
                desktopOffline = !online
            }
            try ensureOpen()
            desktopAvailability[project.legacyID] = !desktopOffline
        }
        if project.isCloud || desktopOffline { return try await catalogFiles(in: project) }
        do {
            let created: Created = try await json("/api/mobile/transfer/list", body: [
                "deviceId": project.deviceId, "projectKey": project.key, "requestId": UUID().uuidString,
            ])
            let transfer = try await poll(id: created.id, kind: "LIST", until: "DONE")
            guard let files = transfer.files else { throw failure("files.error.response") }
            desktopAvailability[project.legacyID] = true
            if project.projectUid != nil, let cloud = try? await catalogFiles(in: project) {
                try ensureOpen()
                let additional = cloud.files.filter { candidate in
                    !files.contains { local in
                        if let uid = candidate.uid, let localUID = local.uid { return uid == localUID }
                        return candidate.source == "desktop" && local.id == candidate.id
                    }
                }
                return ProjectFileListing(files: files + additional,
                                          totalCount: transfer.totalCount.map { $0 + additional.count },
                                          truncated: (transfer.truncated ?? (files.count >= 2000)) || cloud.truncated)
            }
            try ensureOpen()
            return ProjectFileListing(files: files, count: transfer.count,
                                      totalCount: transfer.totalCount, truncated: transfer.truncated)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // The online bit is a snapshot. A desktop may disconnect after the
            // catalog was fetched; only a fresh authorized cloud listing can recover it.
            desktopAvailability[project.legacyID] = false
            guard project.projectUid != nil else { throw error }
            let listing = try await catalogFiles(in: project)
            guard !listing.files.isEmpty else { throw failure("files.desktopRequired") }
            return listing
        }
    }

    private func catalogFiles(in project: RelayProject) async throws -> ProjectFileListing {
        guard let uid = project.projectUid else { throw failure("files.desktopRequired") }
        let data = try await response(request("/api/mobile/catalog/\(uid)/files"))
        if let envelope = try? JSONDecoder().decode(CodeOnly.self, from: data), envelope.code != 0 {
            throw APIError(message: envelope.message ?? tr("files.error.response"))
        }
        let listing = try decode(CatalogFiles.self, data)
        let files = listing.files.filter {
            if $0.source == "cloud" || (project.isCloud && $0.source == nil) { return true }
            return ($0.source == "backup" || $0.source == "desktop") && $0.deviceId == project.deviceId && $0.projectKey == project.key
        }
        return ProjectFileListing(files: files, count: files.count,
                                  totalCount: nil, truncated: listing.truncated)
    }

    func quote(for file: RemoteProjectFile, in project: RelayProject) async throws -> ProjectFileQuote {
        try validatePreview(file)
        try await validateAccess(project: project, file: file)
        if project.isCloud || file.source == "cloud" || file.source == "backup" {
            return ProjectFileQuote(credits: 0, balanceCents: nil)
        }
        return try await json("/api/mobile/transfer/quote?bytes=\(max(1, file.size))")
    }

    private func validateAccess(project: RelayProject, file: RemoteProjectFile) async throws {
        if project.isCloud || file.source == "backup" || file.source == "cloud" {
            guard try await backupConsent().canReadCloud else { throw failure("files.desktopRequired") }
        } else if (desktopAvailability[project.legacyID] ?? project.locations?.first(where: { $0.alias == project.legacyID })?.online) == false {
            throw failure("files.desktopRequired")
        }
    }

    func preparePull(project: RelayProject, file: RemoteProjectFile) throws -> ProjectFilePull {
        try ensureOpen()
        try validatePreview(file)
        if let preview = previews.values.first(where: { $0.pull.matches(project: project, file: file) }) {
            return preview.pull
        }
        try loadLedger()
        if let pending = ledger?.values.first(where: { $0.pull.matches(project: project, file: file) }) {
            return pending.pull
        }
        let pull = ProjectFilePull(project: project, file: file)
        ledger?[pull.requestID.uuidString] = Pending(pull: pull)
        try saveLedger()
        return pull
    }

    func download(_ pull: ProjectFilePull) async throws -> URL {
        try ensureOpen()
        try validatePreview(pull.file)
        try await validateAccess(project: pull.project, file: pull.file)
        if let task = downloads[pull.requestID] { return try await task.value }
        let task = Task {
            do { return try await self.performDownload(pull) }
            catch is CancellationError { throw CancellationError() }
            catch let error as APIError { throw error }
            catch let error as ProjectFileTerminalError { throw error }
            catch is URLError { throw self.failure("error.network") }
            catch { throw self.failure("files.error.response") }
        }
        downloads[pull.requestID] = task
        defer { downloads[pull.requestID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel(_ pull: ProjectFilePull) async throws {
        if let task = downloads[pull.requestID] {
            task.cancel()
            _ = await task.result
        }
        try ensureOpen()
        try loadLedger()
        let key = pull.requestID.uuidString
        if previews[pull.requestID] != nil { throw failure("files.error.transferFailed") }
        guard let pending = ledger?[key] else { return }
        guard let id = pending.transferID else {
            // A lost creation response is ambiguous. Retry the same PULL first; never charge to cancel.
            guard !pending.attempted else { throw failure("files.error.transferFailed") }
            ledger?[key] = nil
            try saveLedger()
            return
        }
        // The server rejects STAGED cancellation; preserve it for retry, with the same UUID.
        let _: CodeOnly = try await json("/api/mobile/transfer/\(id)/cancel", body: [:])
        ledger?[key] = nil
        try saveLedger()
    }

    func removePreview(_ url: URL) {
        guard let entry = previews.first(where: { $0.value.url == url }) else { return }
        try? FileManager.default.removeItem(at: entry.value.url)
        bytesOnDisk -= entry.value.size
        previews[entry.key] = nil
    }

    func close() {
        closed = true
        for task in downloads.values { task.cancel() }
        try? FileManager.default.removeItem(at: cacheDirectory)
        previews.removeAll()
        // In-flight streams release their own reserved bytes when cancellation resumes them.
    }

    private func performDownload(_ pull: ProjectFilePull) async throws -> URL {
        try validateSize(pull.file.size)
        if let preview = previews[pull.requestID] { return preview.url }
        try loadLedger()
        let key = pull.requestID.uuidString
        if ledger?[key] == nil {
            ledger?[key] = Pending(pull: pull)
            try saveLedger()
        }
        if pull.project.isCloud || pull.file.source == "backup" || pull.file.source == "cloud" {
            guard let projectUID = pull.project.projectUid, let fileUID = pull.file.uid else { throw failure("files.error.response") }
            let source = try await saveContent(path: "/api/mobile/preview/catalog/\(projectUID)/files/\(fileUID)/content",
                                               name: pull.file.name, expectedSize: pull.file.size)
            var saved = false
            defer {
                if !saved { try? FileManager.default.removeItem(at: source); bytesOnDisk -= pull.file.size }
            }
            try ensureOpen()
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let destination = cacheDirectory.appendingPathComponent(source.lastPathComponent)
            ledger?[key] = nil
            try saveLedger()
            try FileManager.default.moveItem(at: source, to: destination)
            previews[pull.requestID] = Preview(pull: pull, url: destination, size: pull.file.size)
            saved = true
            return destination
        }
        var id: Int64
        if let existing = ledger?[key]?.transferID { id = existing }
        else {
            ledger?[key]?.attempted = true
            try saveLedger()
            let created: Created = try await json("/api/mobile/preview/pull", body: [
                "deviceId": pull.project.deviceId, "projectKey": pull.project.key,
                "remoteFileId": pull.file.id, "fileName": pull.file.name,
                "fileSize": pull.file.size, "requestId": pull.requestID.uuidString,
            ])
            id = created.id
            ledger?[key]?.transferID = id
            try saveLedger()
        }
        if ledger?[key]?.previewFile == nil {
            let transfer: Transfer
            do { transfer = try await poll(id: id, kind: "PULL", until: "STAGED") }
            catch let error as ProjectFileTerminalError {
                // This branch has no saved local bytes. Transport errors never discard the UUID.
                ledger?[key] = nil
                try saveLedger()
                throw error
            }
            guard let size = transfer.fileSize else { throw failure("files.error.response") }
            try validateSize(size)
            let url = try await saveContent(path: "/api/mobile/transfer/\(id)/content", name: pull.file.name, expectedSize: size)
            ledger?[key]?.previewFile = url.lastPathComponent
            ledger?[key]?.previewSize = size
            try saveLedger()
        }
        guard let pending = ledger?[key], let filename = pending.previewFile, let size = pending.previewSize,
              filename == (filename as NSString).lastPathComponent else { throw failure("files.error.response") }
        let source = recoveryDirectory.appendingPathComponent(filename)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == size else { throw failure("files.error.response") }
        if !pending.acknowledged {
            let _: CodeOnly = try await json("/api/mobile/transfer/\(id)/ack", body: [:])
            ledger?[key]?.acknowledged = true
            try saveLedger()
        }
        try ensureOpen()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: destination)
        ledger?[key] = nil
        do { try saveLedger() }
        catch {
            ledger?[key] = pending
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try? FileManager.default.removeItem(at: source)
        previews[pull.requestID] = Preview(pull: pull, url: destination, size: size)
        return destination
    }

    private func saveContent(path: String, name: String, expectedSize: Int64) async throws -> URL {
        try ensureOpen()
        let (stream, response) = try await session.bytes(for: request(path), delegate: noRedirect)
        defer { stream.task.cancel() }
        try ensureOpen()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.mimeType?.lowercased() == "application/octet-stream",
              http.expectedContentLength == expectedSize else { throw failure("files.error.response") }
        try validateSize(expectedSize)
        guard bytesOnDisk + expectedSize <= Self.maximumPreviewBytes else { throw failure("files.error.tooLarge") }
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let partial = recoveryDirectory.appendingPathComponent(UUID().uuidString + ".partial")
        // Remote names and paths never form a local path; only a short extension is retained for Quick Look.
        let ext = (name as NSString).pathExtension
        let safeExtension = ext.count <= 12 && ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? ext : ""
        let destination = recoveryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(safeExtension)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil,
                                              attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else { throw failure("files.error.response") }
        defer { try? FileManager.default.removeItem(at: partial) }
        let handle = try FileHandle(forWritingTo: partial)
        var saved = false
        var count: Int64 = 0
        bytesOnDisk += expectedSize
        defer {
            try? handle.close()
            if !saved { bytesOnDisk -= expectedSize }
        }
        var chunk = Data()
        for try await byte in stream {
            try ensureOpen()
            count += 1
            guard count <= expectedSize else { throw failure("files.error.response") }
            chunk.append(byte)
            if chunk.count == 65_536 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        guard count == expectedSize else { throw failure("files.error.response") }
        try ensureOpen()
        try handle.write(contentsOf: chunk)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: partial, to: destination)
        saved = true
        return destination
    }

    private func poll(id: Int64, kind: String, until status: String) async throws -> Transfer {
        for attempt in 0..<pollingAttempts {
            let result: TransferResponse = try await json("/api/mobile/transfer/\(id)")
            let transfer = result.transfer
            guard transfer.id == id, transfer.kind == kind else { throw failure("files.error.response") }
            if transfer.status == status { return transfer }
            if transfer.status == "FAILED" || transfer.status == "EXPIRED" {
                throw ProjectFileTerminalError(message: transfer.error ?? tr("files.error.transferFailed"))
            }
            guard transfer.status == "PENDING" else {
                throw APIError(message: transfer.error ?? tr("files.error.transferFailed"))
            }
            if attempt + 1 < pollingAttempts { try await Task.sleep(nanoseconds: pollingInterval) }
        }
        throw failure("files.error.timeout")
    }

    private func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        try ensureOpen()
        guard let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL else { throw failure("files.error.response") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(context.sessionID, forHTTPHeaderField: "X-Session-Id")
        request.setValue(context.language, forHTTPHeaderField: "X-App-Language")
        if let body {
            request.httpMethod = "POST"
            if !body.isEmpty {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        return request
    }

    private func response(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: noRedirect) }
        catch {
            try ensureOpen()
            throw failure("error.network")
        }
        try ensureOpen()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw failure("files.error.response")
        }
        return data
    }

    private func json<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        let data = try await response(request(path, body: body))
        let envelope = try decode(CodeOnly.self, data)
        guard envelope.code == 0 else { throw APIError(message: envelope.message ?? tr("files.error.response")) }
        return try decode(T.self, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw failure("files.error.response") }
    }

    private func ensureOpen() throws {
        try Task.checkCancellation()
        if closed { throw failure("files.error.closed") }
    }

    private func validatePreview(_ file: RemoteProjectFile) throws {
        guard file.supportsPreview else { throw failure("workspace.unsupportedPreview") }
        try validateSize(file.size)
    }

    private func validateSize(_ size: Int64) throws {
        guard size >= 0, size <= Self.maximumPreviewBytes else { throw failure("files.error.tooLarge") }
    }

    private func loadLedger() throws {
        guard ledger == nil else { return }
        let url = recoveryDirectory.appendingPathComponent("pending.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { ledger = try JSONDecoder().decode([String: Pending].self, from: Data(contentsOf: url)) }
            catch { throw failure("files.error.response") }
            bytesOnDisk += ledger?.values.compactMap(\.previewSize).reduce(0, +) ?? 0
        } else { ledger = [:] }
    }

    private func saveLedger() throws {
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            var directory = recoveryDirectory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            try JSONEncoder().encode(ledger ?? [:]).write(to: directory.appendingPathComponent("pending.json"),
                                                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw failure("files.error.response") }
    }

    private func failure(_ key: String) -> APIError { APIError(message: tr(key)) }

    private struct CatalogFiles: Decodable {
        let files: [RemoteProjectFile]
        let count: Int?
        let totalCount: Int?
        let truncated: Bool?
    }
    private struct Created: Decodable { let id: Int64 }
    private struct TransferResponse: Decodable { let transfer: Transfer }
    private struct Transfer: Decodable {
        let id: Int64
        let kind: String
        let status: String
        let fileSize: Int64?
        let error: String?
        let files: [RemoteProjectFile]?
        let count: Int?
        let totalCount: Int?
        let truncated: Bool?
    }
}

private final class ProjectFilesNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
