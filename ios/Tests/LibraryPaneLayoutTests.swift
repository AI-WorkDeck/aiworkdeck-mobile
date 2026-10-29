import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class LibraryPaneLayoutTests: XCTestCase {
    func testQueueRestoresBothColumnsAfterCompactWindowWithoutReplacingSplit() async throws {
        let content = AnyView(QueueView(onClose: {}))
        let state = LibraryWindowState()
        let host = UIHostingController(rootView: SecondaryWindowHarness(state: state, content: content))
        let window = UIWindow(frame: CGRect(origin: .zero, size: state.size))
        window.rootViewController = host
        host.traitOverrides.horizontalSizeClass = .regular
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let original = try XCTUnwrap(split(in: host))
        XCTAssertEqual(original.displayMode, .oneBesideSecondary)

        for size in [CGSize(width: 470, height: 669), CGSize(width: 951, height: 669),
                     CGSize(width: 669, height: 951), CGSize(width: 951, height: 669)] {
            state.size = size
            window.frame.size = size
            host.view.frame = window.bounds
            try await settle(host)
            let current = try XCTUnwrap(split(in: host))
            XCTAssertTrue(current === original, "Window changes must preserve the navigation container")
            if size.width > size.height {
                XCTAssertFalse(current.isCollapsed)
                XCTAssertEqual(current.displayMode, .oneBesideSecondary, "Both columns must return with the wide window")
            } else {
                XCTAssertTrue(current.isCollapsed, "The compact window must show one full-width column")
            }
        }
    }

    func testSettingsPreservesSingleNavigationStackAcrossPhoneAndWideWindows() async throws {
        let state = LibraryWindowState()
        state.size = CGSize(width: 393, height: 852)
        state.sizeClass = .compact
        let host = UIHostingController(rootView: SecondaryWindowHarness(state: state, content: AnyView(SettingsView(onClose: {}))))
        let window = UIWindow(frame: CGRect(origin: .zero, size: state.size))
        window.rootViewController = host
        host.traitOverrides.horizontalSizeClass = .compact
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let original = try XCTUnwrap(navigation(in: host))
        let originalScreen = try XCTUnwrap(original.topViewController)
        XCTAssertNil(split(in: host), "Settings must open as a complete form, without a category sidebar")
        XCTAssertEqual(original.viewControllers.count, 1)

        for (size, sizeClass, textSize) in [
            (CGSize(width: 320, height: 568), UserInterfaceSizeClass.compact, DynamicTypeSize.large),
            (CGSize(width: 440, height: 956), .compact, .large),
            (CGSize(width: 852, height: 393), .compact, .large),
            (CGSize(width: 951, height: 669), .regular, .large),
            (CGSize(width: 669, height: 951), .regular, .large),
            (CGSize(width: 393, height: 852), .compact, .accessibility3),
            (CGSize(width: 393, height: 852), .compact, .large)
        ] {
            state.size = size
            state.sizeClass = sizeClass
            state.textSize = textSize
            host.traitOverrides.horizontalSizeClass = sizeClass == .compact ? .compact : .regular
            window.frame.size = size
            host.view.frame = window.bounds
            try await settle(host)
            let current = try XCTUnwrap(navigation(in: host))
            XCTAssertTrue(current === original, "Resize must preserve the settings navigation container")
            XCTAssertTrue(current.topViewController === originalScreen, "Resize must preserve the same settings form")
            XCTAssertEqual(current.viewControllers.count, 1)
            XCTAssertNil(split(in: host), "A wide window must not introduce an empty category/detail column")
            XCTAssertEqual(current.view.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(current.view.bounds.height, size.height, accuracy: 1)
        }
    }

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

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
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
    var sizeClass = UserInterfaceSizeClass.regular
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

private struct SecondaryWindowHarness: View {
    let state: LibraryWindowState
    let content: AnyView
    @State private var model = AppModel()

    var body: some View {
        content
            .environment(model)
            .environment(\.horizontalSizeClass, state.sizeClass)
            .environment(\.dynamicTypeSize, state.textSize)
            .frame(width: state.size.width, height: state.size.height)
    }
}
