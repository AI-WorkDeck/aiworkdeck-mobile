import Foundation

/// One workspace retains one login snapshot for every step, including ACK and retries.
struct ProjectFilesContext: Sendable {
    let baseURL: URL
    let sessionID: String
    let language: String
}

struct RemoteProjectFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    var uid: String? = nil
    var source: String? = nil
    var isFolder: Bool? = nil
    var deviceId: String? = nil
    var projectKey: String? = nil
    var rowID: String { uid ?? [source ?? "desktop", deviceId ?? "", projectKey ?? "", id].joined(separator: ":") }
    var supportsPreview: Bool {
        isFolder != true && ContractCapabilities.previewExtensions.contains((name as NSString).pathExtension.lowercased())
    }
    func matches(_ other: RemoteProjectFile) -> Bool {
        if let uid, let otherUID = other.uid { return uid == otherUID }
        return id == other.id
    }
}

struct ProjectFileListing: Sendable {
    let files: [RemoteProjectFile]
    let count: Int
    let totalCount: Int?
    let truncated: Bool

    init(files: [RemoteProjectFile], count: Int? = nil, totalCount: Int? = nil, truncated: Bool? = nil) {
        self.files = files
        self.count = count ?? files.count
        self.totalCount = totalCount
        // Old desktops and servers returned no metadata at their 2,000-file ceiling.
        self.truncated = truncated ?? (files.count >= 2000)
    }
}

struct ProjectFileQuote: Decodable, Sendable {
    let credits: Int
    let balanceCents: Int64?
}

/// Confirmed server terminal state: a later transfer needs a new quote and explicit consent.
struct ProjectFileTerminalError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Keep this value for retry. Creating it is local; download creates the charged PULL.
struct ProjectFilePull: Codable, Sendable {
    let project: RelayProject
    let file: RemoteProjectFile
    let requestID: UUID

    init(project: RelayProject, file: RemoteProjectFile, requestID: UUID = UUID()) {
        self.project = project
        self.file = file
        self.requestID = requestID
    }
    func matches(project: RelayProject, file: RemoteProjectFile) -> Bool {
        guard self.project.matches(project) else { return false }
        let originalCloud = self.project.isCloud || self.file.source == "cloud" || self.file.source == "backup"
        let requestedCloud = project.isCloud || file.source == "cloud" || file.source == "backup"
        guard originalCloud == requestedCloud else { return false }
        if self.file.uid != nil && file.uid != nil { return self.file.matches(file) }
        return self.project.legacyID == project.legacyID && self.file.id == file.id
    }
}

struct BackupConsent: Decodable, Sendable {
    let enabled: Bool
    let decided: Bool
    let subscriptionActive: Bool
    let consentVersion: String?
    var canReadCloud: Bool { enabled && subscriptionActive }
}

protocol ProjectFilesServing: Sendable {
    func backupConsent() async throws -> BackupConsent
    func setBackupConsent(enabled: Bool) async throws -> BackupConsent
    func projects() async throws -> [RelayProject]
    func files(in project: RelayProject) async throws -> ProjectFileListing
    func quote(for file: RemoteProjectFile, in project: RelayProject) async throws -> ProjectFileQuote
    /// Persists an account-isolated UUID before a charged request can be sent.
    func preparePull(project: RelayProject, file: RemoteProjectFile) async throws -> ProjectFilePull
    /// Call only after the user accepts the quote. Repeat the same pull to retry.
    func download(_ pull: ProjectFilePull) async throws -> URL
    func cancel(_ pull: ProjectFilePull) async throws
    func removePreview(_ url: URL) async
    func close() async
}

/// Directory navigation uses metadata only; entering a folder never pulls bytes.
struct ProjectFileDirectory {
    struct Folder: Identifiable, Equatable {
        let path: String
        var id: String { path }
        var name: String { String(path.split(separator: "/").last ?? "") }
    }
    let files: [RemoteProjectFile]

    static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .filter { $0 != "." }.joined(separator: "/")
    }

    func folders(in directory: String) -> [Folder] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        let paths = files.compactMap { file -> String? in
            let path = Self.normalized(file.path)
            guard path.hasPrefix(prefix) else { return nil }
            let remainder = path.dropFirst(prefix.count).split(separator: "/")
            guard remainder.count > 1 || (remainder.count == 1 && file.isFolder == true) else { return nil }
            return prefix + remainder[0]
        }
        return Set(paths).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(Folder.init)
    }

    func files(in directory: String, matching query: String) -> [RemoteProjectFile] {
        files.filter { file in
            guard file.isFolder != true else { return false }
            if !query.isEmpty {
                return file.name.localizedCaseInsensitiveContains(query) || file.path.localizedCaseInsensitiveContains(query)
            }
            let components = Self.normalized(file.path).split(separator: "/")
            return components.dropLast().joined(separator: "/") == directory
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
