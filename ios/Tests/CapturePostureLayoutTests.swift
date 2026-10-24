import AVFoundation
import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class CapturePostureLayoutTests: XCTestCase {
    @Observable
    final class Posture {
        var size = CGSize(width: 890, height: 626)
        var reserved: [CGRect] = []
        var audio = false
    }

    private struct ControlProbe: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.accessibilityIdentifier = "controls"
            return view
        }
        func updateUIView(_ view: UIView, context: Context) {}
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 300, height: proposal.height ?? 280)
        }
    }

    private struct Host: View {
        let posture: Posture
        let session: AVCaptureSession
        var body: some View {
            CaptureLayout(viewport: posture.size, audio: posture.audio, reservedAreas: posture.reserved) {
                CameraPreview(session: session)
                ControlProbe()
            }
            .frame(width: posture.size.width, height: posture.size.height)
            .ignoresSafeArea()
        }
    }

    func testBookAndTabletopAvoidReservedAreasWithoutReplacingPreview() async throws {
        let posture = Posture()
        let host = UIHostingController(rootView: Host(posture: posture, session: AVCaptureSession()))
        let window = UIWindow(frame: CGRect(origin: .zero, size: posture.size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let original = try XCTUnwrap(preview(in: host.view))
        let control = try XCTUnwrap(findControl(in: host.view))

        for audio in [false, true] {
            posture.audio = audio
            for (size, gap) in [
                (CGSize(width: 890, height: 626), CGRect(x: 430, y: 0, width: 30, height: 626)),
                (CGSize(width: 626, height: 890), CGRect(x: 0, y: 420, width: 626, height: 50))
            ] {
                posture.size = size
                posture.reserved = [gap]
                window.frame.size = size
                host.view.frame = window.bounds
                try await settle(host)
                let current = try XCTUnwrap(preview(in: host.view))
                XCTAssertTrue(current === original)
                XCTAssertNotNil(current.window)
                let contentFrame = current.convert(current.bounds, to: host.view)
                let controlFrame = control.convert(control.bounds, to: host.view)
                XCTAssertFalse(contentFrame.intersects(gap), "Content must clear the active fold")
                XCTAssertFalse(controlFrame.intersects(gap), "Controls must clear the active fold")
                if gap.width > gap.height {
                    XCTAssertLessThanOrEqual(contentFrame.maxY, gap.minY)
                    XCTAssertGreaterThanOrEqual(controlFrame.minY, gap.maxY)
                } else if audio {
                    XCTAssertLessThanOrEqual(controlFrame.maxX, gap.minX)
                    XCTAssertGreaterThanOrEqual(contentFrame.minX, gap.maxX)
                } else {
                    XCTAssertLessThanOrEqual(contentFrame.maxX, gap.minX)
                    XCTAssertGreaterThanOrEqual(controlFrame.minX, gap.maxX)
                }
            }
        }
    }

    func testNarrowWindowUsesOneColumnAndKeepsMaterialSpace() {
        for audio in [false, true] {
            let layout = CaptureLayout(viewport: CGSize(width: 500, height: 390), audio: audio)
            let regions = layout.regions(controlHeight: 600)
            XCTAssertEqual(regions.content.width, 500)
            XCTAssertEqual(regions.controls.width, 500)
            XCTAssertGreaterThan(regions.content.height, 150)
            XCTAssertFalse(regions.content.intersects(regions.controls))
            XCTAssertEqual(audio ? regions.controls.minY : regions.content.minY, 0)
        }
    }

    func testSystemBarOcclusionsOutsideTheViewportDoNotBecomeFolds() {
        // Actual Duo outer-screen regions: the app's safe width ends at x=382.
        let layout = CaptureLayout(viewport: CGSize(width: 382, height: 616), reservedAreas: [
            CGRect(x: 399.67, y: 1, width: 37, height: 37),
            CGRect(x: 382, y: -28.33, width: 84, height: 170)
        ])
        let regions = layout.regions(controlHeight: 378)
        XCTAssertEqual(regions.content.height, 240)
        XCTAssertEqual(regions.controls.minY, 240)
    }

    private func settle(_ host: UIViewController) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
    }

    private func preview(in view: UIView) -> CameraPreview.PreviewView? {
        if let preview = view as? CameraPreview.PreviewView { return preview }
        return view.subviews.lazy.compactMap { self.preview(in: $0) }.first
    }

    private func findControl(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "controls" { return view }
        return view.subviews.lazy.compactMap { self.findControl(in: $0) }.first
    }
}
