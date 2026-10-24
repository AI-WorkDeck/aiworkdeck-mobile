import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class LibraryPaneLayoutTests: XCTestCase {
    func testRegularHostCollapsesUnselectedPortraitAndLargeTextWithoutReplacingSplit() async throws {
        let windowState = LibraryWindowState()
        let host = UIHostingController(rootView: LibraryWindowHarness(state: windowState, model: AppModel()))
        let window = UIWindow(frame: CGRect(origin: .zero, size: windowState.size))
        window.rootViewController = host
        host.traitOverrides.horizontalSizeClass = .regular
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let original = try XCTUnwrap(split(in: host))
        XCTAssertFalse(original.isCollapsed)

        for (size, textSize, collapsed) in [
            (CGSize(width: 669, height: 951), DynamicTypeSize.large, true),
            (CGSize(width: 951, height: 669), DynamicTypeSize.large, false),
            (CGSize(width: 951, height: 669), DynamicTypeSize.accessibility3, true),
            (CGSize(width: 500, height: 390), DynamicTypeSize.large, true),
            (CGSize(width: 951, height: 669), DynamicTypeSize.large, false)
        ] {
            windowState.size = size
            windowState.textSize = textSize
            window.frame.size = size
            host.view.frame = window.bounds
            try await settle(host)
            let current = try XCTUnwrap(split(in: host))
            XCTAssertTrue(current === original, "Resize must preserve the navigation container")
            XCTAssertEqual(current.isCollapsed, collapsed, "Unselected portrait/large-text lists must not leave an empty detail column")
        }
    }

    private func settle(_ host: UIViewController) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
    }

    private func split(in controller: UIViewController) -> UISplitViewController? {
        if let split = controller as? UISplitViewController { return split }
        return controller.children.lazy.compactMap { self.split(in: $0) }.first
    }
}

@MainActor
@Observable
private final class LibraryWindowState {
    var size = CGSize(width: 951, height: 669)
    var textSize = DynamicTypeSize.large
}

private struct LibraryWindowHarness: View {
    let state: LibraryWindowState
    let model: AppModel
    var body: some View {
        LibraryView(onClose: {})
            .environment(model)
            .environment(\.horizontalSizeClass, .regular)
            .environment(\.dynamicTypeSize, state.textSize)
            .frame(width: state.size.width, height: state.size.height)
    }
}
