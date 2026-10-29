import CryptoKit
import UIKit
import WatchConnectivity

enum WatchAccountScope {
    static func binding(session: String?, baseURL: URL) -> String? {
        guard let session, !session.isEmpty else { return nil }
        let fingerprint = hash("\(baseURL.absoluteString)|\(session)")
        if let account = stableBinding(session: session, baseURL: baseURL) { return account }
        // Existing sessions predate this feature. Without a verified user ID,
        // stay conservative; a changed login requires manual reassignment.
        return fingerprint
    }
    static var current: String? { binding(session: SessionStore.current, baseURL: Backend.baseURL) }

    /// Long-lived transactions cannot use the legacy per-session fallback.
    static func stableBinding(session: String?, baseURL: URL, defaults: UserDefaults = .standard) -> String? {
        guard let session, !session.isEmpty else { return nil }
        let saved = defaults.dictionary(forKey: "watchAccountScope")
        guard saved?["sessionFingerprint"] as? String == hash("\(baseURL.absoluteString)|\(session)") else { return nil }
        return saved?["account"] as? String
    }

    static func didLogin(userID: Int) {
        guard let session = SessionStore.current else { return }
        rememberVerifiedUser(userID, session: session, baseURL: Backend.baseURL)
    }

    static func rememberVerifiedUser(_ userID: Int, session: String, baseURL: URL,
                                     defaults: UserDefaults = .standard) {
        guard userID > 0, !session.isEmpty else { return }
        let region = baseURL.absoluteString
        defaults.set([
            "sessionFingerprint": hash("\(region)|\(session)"),
            "account": hash("\(region)|user:\(userID)")
        ], forKey: "watchAccountScope")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    static let shared = WatchPhoneBridge()
    nonisolated let inbox = WatchRecordingStore(root: WatchRecordingStore.directory("WatchInbox"))
    var lastError: String?
    var onImport: (@MainActor () async -> Void)?
    private var importing = false
    private var needsImportPass = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publishContext() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let project = UserDefaults.standard.data(forKey: "selectedRelayProject")
            .flatMap { try? JSONDecoder().decode(RelayProject.self, from: $0) }
        let destination: WatchDestination?
        if let project, let binding = WatchAccountScope.current {
            destination = WatchDestination(binding: binding, deviceId: project.deviceId,
                deviceName: project.deviceName, key: project.key, name: project.name,
                projectUid: project.projectUid)
        } else { destination = nil }
        do {
            let context = WatchContext(destination: destination, locale: L10n.locale)
            try WCSession.default.updateApplicationContext(["watchContext": try JSONEncoder().encode(context)])
        } catch { lastError = tr("watch.phoneError") }
    }

    func importPending() async {
        guard !importing else { needsImportPass = true; return }
        importing = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "Watch recording import")
        defer {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        do {
            var failed = false
            repeat {
                needsImportPass = false
                for recording in try inbox.pending() {
                    do {
                        if !inbox.hasReceipt(recording.id) {
                            _ = try await EvidenceStore.shared.saveWatchRecording(recording,
                                audioURL: inbox.audioURL(recording.id), currentBinding: WatchAccountScope.current)
                            try inbox.markReceived(recording.id)
                        }
                        // A lost receipt causes re-delivery of the same UUID.
                        if WCSession.default.activationState == .activated {
                            WCSession.default.transferUserInfo(["watchRecordingAck": recording.id.uuidString])
                            try inbox.acknowledge(recording.id)
                        }
                        await onImport?()
                    } catch { failed = true }
                }
            } while needsImportPass
            lastError = failed ? tr("watch.phoneError") : nil
        } catch { lastError = tr("watch.phoneError") }
        // A slow cloud upload must not hold the inbox lock or swallow new files.
        importing = false
        if SessionStore.current != nil { await UploadQueue.shared.autoKick() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            guard let data = file.metadata?["watchRecording"] as? Data else { return }
            let recording = try JSONDecoder().decode(WatchRecording.self, from: data)
            guard recording.complete else { return }
            try inbox.stage(recording, from: file.fileURL)
            Task { @MainActor in await importPending() }
        } catch { Task { @MainActor in lastError = tr("watch.phoneError") } }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                            error: Error?) {
        Task { @MainActor in
            publishContext()
            await importPending()
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in publishContext() }
    }
}
