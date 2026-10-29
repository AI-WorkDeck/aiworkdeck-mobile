@preconcurrency import AVFoundation
import Foundation
import UIKit

private let audioSessionQueue = DispatchQueue(label: "com.aiworkdeck.mobile.audiosession")

/// All session changes use one queue so stopping cannot deactivate a newer recording.
func configureAudioSession(active: Bool, playback: Bool = false) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        audioSessionQueue.async {
            do {
                let session = AVAudioSession.sharedInstance()
                if active {
                    try session.setCategory(playback ? .playback : .record, mode: .default)
                    // A rejected preference must not prevent recording. Playback keeps normal alerts.
                    try? session.setPrefersNoInterruptionsFromSystemAlerts(!playback)
                }
                try session.setActive(active)
                cont.resume(returning: true)
            } catch {
                cont.resume(returning: false)
            }
        }
    }
}

@MainActor
@Observable
final class AudioRecorderService: NSObject {
    static let shared = AudioRecorderService()
    private(set) var isRecording = false
    private(set) var isInterrupted = false
    private(set) var isPaused = false
    private(set) var isBusy = false
    private(set) var permissionDenied = false
    private(set) var recordingSeconds = 0
    private(set) var lastError: String?
    private(set) var lastSavedID: UUID?
    private(set) var notice: String?
    private(set) var canRetrySave = false

    private(set) var silence = RecordingSilence()
    private var voiceMonitor: VoiceActivityMonitor?
    private var voiceGeneration = UUID()
    private var lastVoiceResultAt: TimeInterval?
    private let reminderNotification = RecordingReminderNotification()

    private var recorder: AVAudioRecorder?
    private var draft: RecordingDraft?
    /// The destination captured at start, including an explicitly unassigned recording.
    var activeDraft: RecordingDraft? { draft }
    private var clock = RecordingClock()
    private var timer: Timer?
    private let activity = RecordingActivityController()
    private var attemptedDrafts = Set<UUID>()
    private let store: EvidenceStore
    private let pendingDrafts: () throws -> [RecordingDraft]
    var onStored: (() async -> Void)?

    init(store: EvidenceStore = .shared, pendingDrafts: @escaping () throws -> [RecordingDraft] = RecordingDraft.pending) {
        self.store = store
        self.pendingDrafts = pendingDrafts
        super.init()
        reminderNotification.clear()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if type == .began { await self.stop(interrupted: true) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.stop(interrupted: true) }
        }
    }

    func toggle(project: RelayProject?, location: (lat: Double, lon: Double, accuracy: Double)?) async {
        guard !isBusy else { return }
        if isRecording { await stop() }
        else { await start(project: project, location: location) }
    }

    /// stop() closes the file synchronously; saving must not depend on a delegate arriving
    /// after an interruption. Both delegate and intent use this idempotent path.
    func stop(interrupted: Bool = false) async {
        guard !isBusy, let r = recorder, let draft else { return }
        isBusy = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save recording")
        defer {
            isBusy = false
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        stopVoiceMonitoring()
        r.delegate = nil
        r.stop()
        recorder = nil
        self.draft = nil
        timer?.invalidate()
        timer = nil
        activity.end()
        isRecording = false
        isPaused = false
        isInterrupted = false
        recordingSeconds = 0
        lastSavedID = nil
        _ = await configureAudioSession(active: false)
        let result = await save(draft)
        switch result {
        case .saved:
            lastError = nil
            if interrupted { notice = tr("rec.interruption.saved") }
        case .noAudio, .failed:
            lastError = failureMessage(result, count: 1)
            notice = lastError
            canRetrySave = true
        }
    }

    private enum SaveResult { case saved, noAudio, failed }

    private func failureMessage(_ result: SaveResult, count: Int) -> String {
        tr(result == .noAudio ? "rec.recovery.noAudio" : "rec.recovery.saveFailed", ["count": String(count)])
    }

    private func save(_ draft: RecordingDraft) async -> SaveResult {
        attemptedDrafts.insert(draft.id)
        do {
            let duration = try await AVURLAsset(url: draft.audioURL).load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else {
                return .noAudio
            }
        } catch { return .noAudio }
        do {
            let item = try await store.saveRecording(draft)
            draft.remove() // Only remove the source after the manifest has committed.
            lastSavedID = item.id
            await onStored?()
            return .saved
        } catch {
            // Metadata and audio survive for the next foreground/launch retry.
            return .failed
        }
    }

    func dismissNotice() { notice = nil }

    func recoverPending(retry: Bool = false) async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        if retry { attemptedDrafts.removeAll() }
        do {
            let pending = try pendingDrafts().filter { !attemptedDrafts.contains($0.id) }
            guard !pending.isEmpty else { return }
            lastSavedID = nil
            var saved = 0, invalid = 0, failed = 0
            for draft in pending {
                switch await save(draft) {
                case .saved: saved += 1
                case .noAudio: invalid += 1
                case .failed: failed += 1
                }
            }
            var messages: [String] = []
            if saved > 0 { messages.append(tr("rec.recovery.saved", ["count": String(saved)])) }
            var errors: [String] = []
            if invalid > 0 { errors.append(failureMessage(.noAudio, count: invalid)) }
            if failed > 0 { errors.append(failureMessage(.failed, count: failed)) }
            canRetrySave = invalid + failed > 0
            lastError = errors.isEmpty ? nil : errors.joined(separator: "\n\n")
            notice = (messages + errors).joined(separator: "\n\n")
        } catch {
            lastError = tr("rec.saveFailed")
            notice = lastError
            canRetrySave = true
        }
    }

    func start(project: RelayProject?, location: (lat: Double, lon: Double, accuracy: Double)?) async {
        guard !isBusy, recorder == nil else { return }
        isBusy = true
        defer { isBusy = false }
        guard await ensureAuthorized() else { permissionDenied = true; return }
        permissionDenied = false
        lastError = nil
        lastSavedID = nil
        await reminderNotification.requestPermission()
        await CameraService.shared.prepareForAudioRecording()
        guard await configureAudioSession(active: true) else {
            lastError = tr("rec.startFailed")
            return
        }
        let draft = RecordingDraft(id: UUID(), startedAt: Date(), project: project,
                                   latitude: location?.lat, longitude: location?.lon,
                                   accuracy: location?.accuracy, device: Device.facts)
        do {
            try draft.persist()
            let r = try AVAudioRecorder(url: draft.audioURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            r.delegate = self
            guard r.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: draft.audioURL.path)
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
            self.draft = draft
            clock.start(at: Date())
            isRecording = true
            isPaused = false
            startVoiceMonitoring()
            isInterrupted = false
            recordingSeconds = 0
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkRecordingStatus() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            activity.start(projectName: project?.name ?? "", state: activityState)
        } catch {
            draft.remove() // Recording never started.
            _ = await configureAudioSession(active: false)
            lastError = tr("rec.startFailed")
        }
    }

    /// Use recorded duration, not wall time: a suspended timer is not evidence of audio.
    private func synchronize() {
        guard let r = recorder, isRecording else { return }
        let interrupted = !r.isRecording && !isPaused
        let changed = isInterrupted != interrupted
        clock.synchronize(seconds: max(clock.elapsedBase, r.currentTime), running: r.isRecording, at: Date())
        recordingSeconds = Int(clock.elapsed(at: Date()))
        isInterrupted = interrupted
        if changed { activity.update(state: activityState) }
    }

    /// Foreground/timer verification never reopens the microphone after an interruption.
    func checkRecordingStatus() async {
        guard !isBusy, let r = recorder else { return }
        synchronize()
        if let lastVoiceResultAt, ProcessInfo.processInfo.systemUptime - lastVoiceResultAt > 5 {
            // A stalled classifier cannot justify a reminder, including after suspension.
            clearSilenceReminder()
            self.lastVoiceResultAt = nil
        }
        if !r.isRecording && !isPaused { await stop(interrupted: true) }
        else { activity.update(state: activityState) }
    }

    func togglePause() async {
        guard isRecording, !isBusy else { return }
#if DEBUG
        if recorder == nil && ProcessInfo.processInfo.arguments.contains("-AWDPauseRecordingUITest") {
            isPaused.toggle()
            return
        }
#endif
        guard let r = recorder else { return }
        if isPaused {
            isBusy = true
            defer { isBusy = false }
            guard await configureAudioSession(active: true), r.record() else {
                notice = tr("rec.resume.failed")
                return
            }
            isPaused = false
            lastError = nil
            startVoiceMonitoring()
        } else {
            r.pause()
            guard !r.isRecording else { return }
            isPaused = true
            stopVoiceMonitoring()
        }
        synchronize()
        activity.update(state: activityState)
    }

    func recordingSceneChanged(active: Bool) {
        if active { reminderNotification.clear() }
        else if silence.needsConfirmation { reminderNotification.show() }
    }

    func continueAfterSilence() {
        silence.keepRecording()
        reminderNotification.clear()
    }

    private func clearSilenceReminder() {
        silence = RecordingSilence()
        reminderNotification.clear()
    }

    private func startVoiceMonitoring() {
        clearSilenceReminder()
        let generation = UUID()
        voiceGeneration = generation
        lastVoiceResultAt = nil
        let monitor = VoiceActivityMonitor(onResult: { [weak self] start, end, voice in
            Task { @MainActor in
                guard let self, self.isRecording, !self.isPaused, self.voiceGeneration == generation else { return }
                self.lastVoiceResultAt = ProcessInfo.processInfo.systemUptime
                let wasPending = self.silence.needsConfirmation
                self.silence.observe(start: start, end: end, voice: voice)
                if self.silence.needsConfirmation && !wasPending {
                    if UIApplication.shared.applicationState != .active { self.reminderNotification.show() }
                } else if !self.silence.needsConfirmation && wasPending {
                    self.reminderNotification.clear()
                }
            }
        }, onFailure: { [weak self] in
            Task { @MainActor in
                guard let self, self.voiceGeneration == generation else { return }
                self.stopVoiceMonitoring()
                self.notice = tr("rec.silence.unavailable")
            }
        })
        do {
            try monitor.start()
            voiceMonitor = monitor
        } catch {
            monitor.stop()
            // Failure of optional analysis must never stop the primary recording.
            stopVoiceMonitoring()
            notice = tr("rec.silence.unavailable")
        }
    }

    private func stopVoiceMonitoring() {
        voiceGeneration = UUID()
        voiceMonitor?.stop()
        voiceMonitor = nil
        lastVoiceResultAt = nil
        clearSilenceReminder()
    }

    private var activityState: RecordingActivityAttributes.ContentState {
        .init(elapsedBase: clock.elapsedBase, resumedAt: clock.resumedAt, paused: clock.paused)
    }

    private func ensureAuthorized() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        default: false
        }
    }

#if DEBUG
    func beginFakeRecording(seconds: Int, paused: Bool = false) {
        guard Shot.isOn || ProcessInfo.processInfo.arguments.contains("-AWDSilenceReminderUITest") || ProcessInfo.processInfo.arguments.contains("-AWDPauseRecordingUITest") else { return }
        isRecording = true
        recordingSeconds = seconds
        isPaused = paused
        if ProcessInfo.processInfo.arguments.contains("-AWDSilenceReminderUITest") {
            silence.observe(start: 0, end: 300, voice: false)
        }
    }
#endif
}

extension AudioRecorderService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            await self.stop(interrupted: true)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            await self.stop(interrupted: true)
        }
    }
}
