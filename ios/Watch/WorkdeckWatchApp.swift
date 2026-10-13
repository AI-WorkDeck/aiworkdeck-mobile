import SwiftUI
import WatchKit
import WatchConnectivity

@main
struct WorkdeckWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = WatchRecorder.shared

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: T.Sp.s3) {
                    Text(tr(recorder.recording ? "watch.recording" : "watch.ready"))
                        .font(T.F.heading()).foregroundStyle(T.D.fgMuted)
                    if let start = recorder.startedAt {
                        Text(start, style: .timer).font(T.F.hero()).monospacedDigit()
                            .accessibilityIdentifier("watch.timer")
                    } else {
                        Image(systemName: "mic.fill").font(T.F.display())
                            .foregroundStyle(T.S.arrivedOnDark)
                    }
                    Button {
                        if recorder.recording { recorder.stop() }
                        else { Task { await recorder.start() } }
                    } label: {
                        Label(tr(recorder.recording ? "watch.stop" : "watch.start"),
                              systemImage: recorder.recording ? "stop.fill" : "mic.fill")
                            .frame(maxWidth: .infinity, minHeight: T.touchMin)
                    }
                    .tint(recorder.recording ? T.S.failed : T.L.accent)
                    .disabled(recorder.busy)
                    .accessibilityIdentifier("watch.record")

                    if let name = recorder.context?.destination?.name {
                        Text(tr("watch.target", ["name": name])).font(T.F.micro())
                    } else { Text(tr("watch.setup")).font(T.F.micro()) }

                    if recorder.pendingCount > 0 {
                        Text(tr("watch.pending", ["n": "\(recorder.pendingCount)"]))
                            .font(T.F.micro()).foregroundStyle(T.S.waitingOnDark)
                        Button(tr("watch.retry")) {
                            Task { await recorder.recover(); recorder.sync(force: true) }
                        }.font(T.F.small()).disabled(recorder.busy)
                    }
                    if let notice = recorder.notice {
                        Text(notice).font(T.F.small()).accessibilityIdentifier("watch.notice")
                        Button(tr("common.close")) { recorder.notice = nil }.font(T.F.micro())
                    }
                }
                .padding(.horizontal, T.Sp.s2)
            }
            .background(T.D.bg).foregroundStyle(T.D.fg)
            .task {
                await recorder.resume()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    recorder.sync()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await recorder.resume() } }
            }
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            // File/receipt callbacks perform their own durable work; the system
            // must not be told the connectivity task is done while delivery remains.
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                Task { @MainActor in
                    while WCSession.default.activationState != .activated || WCSession.default.hasContentPending {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    connectivity.setTaskCompletedWithSnapshot(false)
                }
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
    }
}
