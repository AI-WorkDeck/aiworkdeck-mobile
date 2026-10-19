import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class CaptureLayoutTests: XCTestCase {
    func testRotationKeepsTheAttachedPreviewAndRestoresPortraitBounds() async throws {
        let view = HomeView(paused: false, onOpenLibrary: {}, onOpenQueue: {}, onOpenSettings: {},
                            cameraStartForTesting: {})
            .environment(AppModel()).environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let original = try XCTUnwrap(preview(in: host.view))
        let portraitBounds = original.bounds
        for size in [CGSize(width: 956, height: 440), CGSize(width: 440, height: 956),
                     CGSize(width: 956, height: 440), CGSize(width: 440, height: 956)] {
            window.frame.size = size
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let current = try XCTUnwrap(preview(in: host.view))
            XCTAssertTrue(current === original, "Rotating must not detach and replace the live camera preview")
            XCTAssertNotNil(current.window)
            XCTAssertGreaterThan(current.bounds.width, 0)
            XCTAssertGreaterThan(current.bounds.height, 0)
            if size.height > size.width {
                XCTAssertEqual(current.bounds.width, portraitBounds.width, accuracy: 1)
                XCTAssertEqual(current.bounds.height, portraitBounds.height, accuracy: 1)
            }
        }
    }

    private func preview(in view: UIView) -> CameraPreview.PreviewView? {
        if let preview = view as? CameraPreview.PreviewView { return preview }
        return view.subviews.lazy.compactMap { self.preview(in: $0) }.first
    }
}
