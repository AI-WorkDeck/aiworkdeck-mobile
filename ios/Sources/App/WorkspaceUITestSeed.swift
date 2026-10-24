#if DEBUG
import Foundation
import UIKit

/// Synthetic UI fixture, separate from screenshot mode and the real evidence store.
actor WorkspaceUITestSeed: ProjectFilesServing {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-AWDWorkspaceUITest")
    private var preview: URL?
    private var consent = BackupConsent(enabled: false, decided: !ProcessInfo.processInfo.arguments.contains("-AWDConsentUITest"), subscriptionActive: true, consentVersion: nil)
    func backupConsent() async throws -> BackupConsent { consent }
    func setBackupConsent(enabled: Bool) async throws -> BackupConsent {
        if ProcessInfo.processInfo.arguments.contains("-AWDConsentFailureUITest") { throw URLError(.notConnectedToInternet) }
        consent = BackupConsent(enabled: enabled, decided: true, subscriptionActive: true, consentVersion: "2026-10-11")
        return consent
    }
    func projects() async throws -> [RelayProject] {
        if ProcessInfo.processInfo.arguments.contains("-AWDCloudCatalogUITest") {
            return [RelayProject(deviceId: "cloud", deviceName: nil, key: "cloud-only", name: "Cloud project", projectUid: "cloud-uid"),
                    RelayProject(deviceId: "test-desktop", deviceName: "Test desktop", key: "mixed", name: "Mixed project", projectUid: "mixed-uid",
                                 locations: [ProjectLocation(kind: "desktop", deviceId: "test-desktop", deviceName: "Test desktop", key: "mixed", online: true),
                                             ProjectLocation(kind: "cloud", deviceId: "cloud", deviceName: nil, key: "cloud-archive", online: true, archiveOnly: true)])]
        }
        return [RelayProject(deviceId: "test-desktop", deviceName: "Test desktop", key: "alpha", name: "Alpha project"),
         RelayProject(deviceId: "test-desktop", deviceName: "Test desktop", key: "beta", name: "Beta project")]
    }
    func files(in project: RelayProject) async throws -> ProjectFileListing {
        if ProcessInfo.processInfo.arguments.contains("-AWDWorkspaceOffline") {
            throw APIError(message: "Test desktop is offline")
        }
        // A delayed first response exercises switching projects while LIST is pending.
        if ProcessInfo.processInfo.arguments.contains("-AWDWorkspaceDelayed"), project.key == "alpha" {
            // Deliberately ignore caller cancellation to simulate a late transport response.
            await Task.detached { try? await Task.sleep(for: .seconds(8)) }.value
        } else {
            try await Task.sleep(for: .milliseconds(project.key == "alpha" ? 300 : 20))
        }
        var files = (1...35).map { n in
            RemoteProjectFile(id: "\(n)", name: "\(project.key)-document-\(n).pdf",
                              path: "Documents/\(project.key)-document-\(n).pdf", size: 1024)
        }
        if ProcessInfo.processInfo.arguments.contains("-AWDFolderUITest") {
            files.append(RemoteProjectFile(id: "unsupported", name: "notes.txt", path: "Documents/Nested/notes.txt", size: 12))
            files.append(RemoteProjectFile(id: "empty", name: "Empty", path: "Empty", size: 0, isFolder: true))
        }
        return ProjectFileListing(files: files)
    }
    func quote(for file: RemoteProjectFile, in project: RelayProject) async throws -> ProjectFileQuote {
        ProjectFileQuote(credits: 1, balanceCents: 1000)
    }
    func preparePull(project: RelayProject, file: RemoteProjectFile) async throws -> ProjectFilePull {
        ProjectFilePull(project: project, file: file)
    }
    func download(_ pull: ProjectFilePull) async throws -> URL {
        if ProcessInfo.processInfo.arguments.contains("-AWDWorkspaceSlowDownload") {
            try await Task.sleep(for: .seconds(2))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.pdf")
        let data = await Self.pdf(pull.file.name)
        try data.write(to: url, options: .atomic)
        preview = url
        return url
    }
    @MainActor private static func pdf(_ title: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 550)).pdfData { context in
            context.beginPage()
            (title as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }
    func cancel(_ pull: ProjectFilePull) async throws {}
    func removePreview(_ url: URL) async { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func close() async { if let preview { await removePreview(preview) } }
}
#endif
