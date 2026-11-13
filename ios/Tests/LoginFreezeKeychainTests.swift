// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreLocation
import XCTest
@testable import Workdeck

// QA 2026-11-13（QM-mobile）B1 / B3 / B5 的回归。

// MARK: - B1 定位不得卡主线程

/// 模拟卡住的 locationd：读授权状态要等 `gate`，并记下是在哪个线程上被调的。
private final class StalledLocationManager: LocationManaging, @unchecked Sendable {
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = 0
    let gate: DispatchSemaphore
    let status: CLAuthorizationStatus
    let started: XCTestExpectation
    private let lock = NSLock()
    private var _touchedMain = false
    var touchedMain: Bool { lock.withLock { _touchedMain } }

    init(gate: DispatchSemaphore, status: CLAuthorizationStatus, started: XCTestExpectation) {
        self.gate = gate; self.status = status; self.started = started
    }
    private func record() { if Thread.isMainThread { lock.withLock { _touchedMain = true } } }

    var authorizationStatus: CLAuthorizationStatus {
        record()
        _ = gate.wait(timeout: .now() + 2)
        return status
    }
    func requestWhenInUseAuthorization() { record() }
    func startUpdatingLocation() { record(); started.fulfill() }
    func stopUpdatingLocation() { record() }
}

@MainActor
final class LocationStamperTests: XCTestCase {
    func testBeginReturnsImmediatelyAndNeverCallsCoreLocationOnMainThread() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "startUpdatingLocation")
        let fake = StalledLocationManager(gate: gate, status: .authorizedWhenInUse, started: started)
        let stamper = LocationStamper(makeManager: { fake })
        let t0 = Date()
        stamper.begin()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 0.5, "begin() must not wait for a stalled location daemon")
        gate.signal()
        await fulfillment(of: [started], timeout: 5)
        XCTAssertFalse(fake.touchedMain, "CLLocationManager must only be used off the main thread")
        XCTAssertNil(stamper.last, "No fix yet: capture proceeds without a location")
    }

    func testDeniedLocationMarksUnavailableWithoutStarting() async throws {
        let gate = DispatchSemaphore(value: 0)
        gate.signal() // daemon healthy (a semaphore must not be disposed below its initial value)
        let started = expectation(description: "startUpdatingLocation")
        started.isInverted = true
        let fake = StalledLocationManager(gate: gate, status: .denied, started: started)
        let stamper = LocationStamper(makeManager: { fake })
        stamper.begin()
        let deadline = Date().addingTimeInterval(5)
        while !stamper.unavailable && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(stamper.unavailable)
        await fulfillment(of: [started], timeout: 0.2)
        XCTAssertFalse(fake.touchedMain)
    }
}

// MARK: - B3 Keychain 写失败不能算登录成功

private final class LoginStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = #"{"code":0,"data":{"sessionId":"synthetic-login","user":{"id":7,"username":"qa","displayName":"QA","avatarUrl":"","role":"USER"}}}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SessionStoreTests: XCTestCase {
    override func tearDown() {
        SessionStore.addItem = { SecItemAdd($0, nil) }
        SessionStore.clear()
        super.tearDown()
    }

    func testKeychainWriteFailureThrowsLocalizedErrorAndStoresNothing() {
        SessionStore.clear()
        SessionStore.addItem = { _ in errSecInteractionNotAllowed }
        XCTAssertThrowsError(try SessionStore.save("synthetic")) { error in
            XCTAssertEqual((error as? SessionSaveError)?.status, errSecInteractionNotAllowed)
            XCTAssertEqual(error.localizedDescription, tr("error.sessionSaveFailed"))
        }
        XCTAssertNil(SessionStore.current)
    }

    func testLoginFailsWhenSessionCannotBeSaved() async {
        SessionStore.clear()
        SessionStore.addItem = { _ in errSecInteractionNotAllowed }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoginStubProtocol.self]
        let api = API(session: URLSession(configuration: config))
        do {
            _ = try await api.accountLogin(account: "qa", password: "pw")
            XCTFail("Login must not succeed when the session was not persisted")
        } catch {
            XCTAssertEqual(error.localizedDescription, tr("error.sessionSaveFailed"))
        }
        XCTAssertNil(SessionStore.current)
    }

    func testSuccessfulSaveIsReadable() throws {
        // On the unsigned Debug simulator host this exercises the DEBUG-only fallback;
        // on a signed build it is the real Keychain. Either way login must persist.
        try SessionStore.save("synthetic-ok")
        XCTAssertEqual(SessionStore.current, "synthetic-ok")
        SessionStore.clear()
        XCTAssertNil(SessionStore.current)
    }
}

// MARK: - B5 队列行不显示系统网络错误原文

final class NetworkErrorMessageTests: XCTestCase {
    func testSystemNetworkErrorsMapToDictionaryMessages() {
        XCTAssertEqual(userFacingMessage(for: URLError(.secureConnectionFailed)), tr("error.unreachable"))
        XCTAssertEqual(userFacingMessage(for: URLError(.cannotConnectToHost)), tr("error.unreachable"))
        XCTAssertEqual(userFacingMessage(for: URLError(.notConnectedToInternet)), tr("error.network"))
        XCTAssertEqual(userFacingMessage(for: URLError(.timedOut)), tr("error.network"))
        XCTAssertEqual(userFacingMessage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)), tr("error.unreachable"))
        XCTAssertEqual(userFacingMessage(for: APIError(message: "server says")), "server says")
    }
}
