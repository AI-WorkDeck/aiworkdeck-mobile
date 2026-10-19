import AVFoundation
import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class CameraPreviewLifecycleTests: XCTestCase {
    @Observable
    final class Probe {
        var presented = false
        var starts = 0
        var stops = 0
    }

    private struct PreviewHost: View {
        let probe: Probe
        let session: AVCaptureSession
        @State private var visiblePreviews: Set<UUID> = []
        @Environment(\.scenePhase) private var scenePhase
        private var shouldRun: Bool { !visiblePreviews.isEmpty && scenePhase == .active }

        var body: some View {
            CameraPreview(session: session, onVisibilityChanged: { id, visible in
                if visible { visiblePreviews.insert(id) }
                else { visiblePreviews.remove(id) }
            })
            .task(id: shouldRun) {
                if shouldRun { probe.starts += 1 }
                else { probe.stops += 1 }
            }
        }
    }

    private struct PresentationHost: View {
        @Bindable var probe: Probe
        let session: AVCaptureSession
        var body: some View {
            Text("Projects")
                .fullScreenCover(isPresented: $probe.presented) {
                    PreviewHost(probe: probe, session: session)
                }
        }
    }

    private func window<Content: View>(hosting content: Content) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        // This UIKit test host has no SwiftUI WindowGroup to supply scenePhase.
        // Inject it at the root so fullScreenCover still has to inherit it.
        window.rootViewController = UIHostingController(rootView: content.environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        return window
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSwiftUIStateStartsCameraOnInitialWindowAttachment() async {
        let probe = Probe()
        let window = window(hosting: PreviewHost(probe: probe, session: AVCaptureSession()))
        defer { window.isHidden = true; window.rootViewController = nil }
        await waitUntil { probe.starts > 0 }
        XCTAssertEqual(probe.starts, 1, "Initial window attachment must reach SwiftUI's camera startup task")
    }

    func testProjectFullScreenPresentationAndReopeningStartWithoutModeSwitch() async {
        let probe = Probe()
        let window = window(hosting: PresentationHost(probe: probe, session: AVCaptureSession()))
        defer { window.isHidden = true; window.rootViewController = nil }
        try? await Task.sleep(for: .milliseconds(300))
        probe.presented = true
        await waitUntil { probe.starts == 1 }
        XCTAssertEqual(probe.starts, 1, "Project camera must start on first full-screen presentation")
        probe.presented = false
        try? await Task.sleep(for: .milliseconds(600))
        probe.presented = true
        await waitUntil { probe.starts == 2 }
        XCTAssertEqual(probe.starts, 2, "Reopening project camera must start without toggling audio mode")
    }
}
