import AVFoundation
import SwiftUI
import WatchConnectivity
import WatchKit

@MainActor
@Observable
final class WatchRecorder: NSObject, AVAudioRecorderDelegate, WCSessionDelegate {
    static let shared = WatchRecorder()
    nonisolated private let store = WatchRecordingStore(root: WatchRecordingStore.directory("WatchRecordings"))
    private var recorder: AVAudioRecorder?
    private var draft: WatchRecording?
    private var lastSent: [UUID: Date] = [:]
    private var recovering = false
    private var finishing = false
    private var interruptionObserver: NSObjectProtocol?
    var recording = false
    var busy = false
    var startedAt: Date?
    var pendingCount = 0
    var notice: String?
    var context: WatchContext?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "watchContext") {
            context = try? JSONDecoder().decode(WatchContext.self, from: data)
            L10n.locale = context?.locale ?? "zh-Hans"
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in self?.interrupt() } }
        }
        refreshCount()
    }

    func start() async {
        guard !recording, !busy else { return }
        busy = true; defer { busy = false }
        notice = nil
        let session = AVAudioSession.sharedInstance()
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { notice = tr("watch.permission"); return }
        do {
            try session.setCategory(.record, mode: .default)
            // Best effort: alerts may yield, but accepted calls can still interrupt.
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
            let value = WatchRecording(id: UUID(), startedAt: Date(), destination: context?.destination,
                deviceModel: WKInterfaceDevice.current().model,
                osVersion: WKInterfaceDevice.current().systemVersion,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                complete: false)
            try store.save(value)
            draft = value
            let audio = try AVAudioRecorder(url: store.audioURL(value.id), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000
            ])
            audio.delegate = self
            guard audio.prepareToRecord(), audio.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = audio
            startedAt = value.startedAt
            recording = true
        } catch {
            try? session.setActive(false)
            notice = tr("watch.failed", ["reason": error.localizedDescription])
            recorder = nil; draft = nil; startedAt = nil
            refreshCount()
        }
    }

    func stop(interrupted: Bool = false) {
        guard recording, !busy, let audio = recorder else { return }
        busy = true
        recording = false
        audio.delegate = nil
        audio.stop()
        // Interruptions do not deliver didFinishRecording. Close synchronously
        // and invoke the same idempotent finalizer ourselves.
        audioRecorderDidFinishRecording(audio, successfully: !interrupted)
    }

    private func interrupt() {
        guard recording else { return }
        notice = tr("watch.interrupted")
        stop(interrupted: true)
    }

    func resume() async {
        if recording, recorder?.isRecording != true { interrupt() }
        await recover()
        sync()
    }

    func recover() async {
        guard !recovering else { return }
        recovering = true; defer { recovering = false }
        do {
            for var value in try store.pending() where !value.complete && value.id != draft?.id {
                if await validAudio(store.audioURL(value.id)) {
                    value.complete = true
                    try store.save(value)
                    notice = tr("watch.recovered")
                } else { notice = tr("watch.recoveryFailed") }
            }
        } catch { notice = tr("watch.recoveryFailed") }
        refreshCount()
    }

    private func validAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite,
              duration.seconds > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return false }
        return true
    }

    func sync(force: Bool = false) {
        refreshCount()
        guard WCSession.default.activationState == .activated else { return }
        do {
            let outstanding = Set(WCSession.default.outstandingFileTransfers.compactMap {
                $0.file.metadata?["recordingID"] as? String
            })
            for value in try store.pending() where value.complete {
                guard !outstanding.contains(value.id.uuidString),
                      force || Date().timeIntervalSince(lastSent[value.id] ?? .distantPast) >= 120 else { continue }
                let metadata: [String: Any] = ["watchRecording": try JSONEncoder().encode(value),
                                              "recordingID": value.id.uuidString]
                WCSession.default.transferFile(store.audioURL(value.id), metadata: metadata)
                lastSent[value.id] = Date()
            }
        } catch { notice = tr("watch.syncFailed") }
    }

    private func refreshCount() {
        do { pendingCount = try store.pending().filter { $0.id != draft?.id }.count }
        catch { notice = tr("watch.recoveryFailed") }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in
            guard var value = draft, store.audioURL(value.id) == url else { return }
            if !flag { notice = tr("watch.interrupted") }
            guard !finishing else { return }
            finishing = true
            defer { finishing = false }
            recording = false
            if !busy || !flag { notice = tr("watch.interrupted") }
            busy = true
            self.recorder?.stop()
            if await validAudio(url) {
                do { value.complete = true; try store.save(value) }
                catch { notice = tr("watch.recoveryFailed") }
            } else { notice = tr("watch.recoveryFailed") }
            self.recorder = nil; draft = nil; startedAt = nil; busy = false
            try? AVAudioSession.sharedInstance().setActive(false)
            sync()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                            error: Error?) {
        let data = session.receivedApplicationContext["watchContext"] as? Data
        Task { @MainActor in
            applyContext(data)
            await recover()
            sync()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["watchContext"] as? Data
        Task { @MainActor in applyContext(data) }
    }

    private func applyContext(_ data: Data?) {
        guard let data, let context = try? JSONDecoder().decode(WatchContext.self, from: data) else { return }
        self.context = context
        L10n.locale = context.locale
        UserDefaults.standard.set(data, forKey: "watchContext")
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let raw = userInfo["watchRecordingAck"] as? String, let id = UUID(uuidString: raw) else { return }
        do {
            if try store.pending().contains(where: { $0.id == id && $0.complete }) {
                try store.acknowledge(id)
            }
            Task { @MainActor in
                lastSent[id] = nil
                // Keep an interruption/recovery warning until explicitly dismissed.
                if notice == nil { notice = tr("watch.received") }
                refreshCount()
            }
        } catch { Task { @MainActor in notice = tr("watch.recoveryFailed") } }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in sync() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error != nil { Task { @MainActor in notice = tr("watch.syncFailed") } }
        // WC transport success is not an application-level durable save receipt.
    }
}
