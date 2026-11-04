// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class CloudAccessTests: XCTestCase {
    func testCapabilityOverridesSubscriptionWithoutChangingIdentity() throws {
        let raw = #"{"enabled":true,"decided":true,"subscriptionActive":false,"cloudAccess":{"canUse":true,"canWrite":true,"canRead":true,"reason":"ready","epoch":1,"includedStorageBytes":0,"cleanupEligible":false,"notificationStatus":"none","frozen":false,"cleanupState":"none"}}"#
        let value = try JSONDecoder().decode(BackupConsent.self, from: Data(raw.utf8))
        XCTAssertFalse(value.subscriptionActive)
        XCTAssertTrue(value.canReadCloud)
        XCTAssertTrue(value.canWriteCloud)
        let blocked = raw.replacingOccurrences(of: "\"subscriptionActive\":false", with: "\"subscriptionActive\":true").replacingOccurrences(of: "\"canWrite\":true", with: "\"canWrite\":false").replacingOccurrences(of: "\"canRead\":true", with: "\"canRead\":false")
        let denied = try JSONDecoder().decode(BackupConsent.self, from: Data(blocked.utf8))
        XCTAssertFalse(denied.canWriteCloud)
        XCTAssertFalse(denied.canReadCloud)
    }
    func testUnavailableBillingDeniesWithoutInventingEpoch() throws {
        let raw = #"{"enabled":true,"decided":true,"subscriptionActive":true,"cloudAccess":{"canUse":false,"canWrite":false,"canRead":false,"reason":"billing_unavailable"}}"#
        let value = try JSONDecoder().decode(BackupConsent.self, from: Data(raw.utf8))
        XCTAssertFalse(value.canWriteCloud)
        XCTAssertFalse(value.canReadCloud)
        XCTAssertNil(value.cloudAccess?.epoch)
    }
    func testLegacyResponsePreservesConsentGate() throws {
        let raw = #"{"enabled":false,"decided":true,"subscriptionActive":true}"#
        let value = try JSONDecoder().decode(BackupConsent.self, from: Data(raw.utf8))
        XCTAssertFalse(value.canReadCloud)
        XCTAssertTrue(value.canWriteCloud)
    }
}

private final class EpochTestProtocol: URLProtocol {
    nonisolated(unsafe) static var epoch = 3
    nonisolated(unsafe) static var probes = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.hasSuffix("cloud-state") { Self.probes += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = request.url!.path.hasSuffix("/auth/me") ? #"{"code":0,"data":{"id":41,"username":"test","displayName":"test","avatarUrl":"","role":"USER"}}"# : "{\"cloudAccess\":{\"epoch\":\(Self.epoch)}}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class CloudEpochTests: XCTestCase {
    func testOfflineDeviceReloadKeepsBindingAndOriginalsUntilExplicitReconnect() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EpochTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let suite = "epoch-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvidenceStore(root: root)
        let gate = CloudEpoch(defaults: defaults, store: store)
        var request = URLRequest(url: URL(string: "https://addin.aiworkdeck.com/api/mobile/media")!)
        request.httpMethod = "POST"; request.setValue("synthetic-a", forHTTPHeaderField: "X-Session-Id")
        EpochTestProtocol.probes = 0; EpochTestProtocol.epoch = 3
        let first = try await gate.authorize(request, session: session)
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Cloud-Epoch"), "3")
        let item = try await store.save(data: Data([1,2,3]), kind: .audio, capturedAt: Date(timeIntervalSince1970: 100), location: nil,
            device: DeviceFacts(model: "fixture", osVersion: "fixture", appVersion: "fixture"), project: nil)
        try await store.updateState(item.id, to: .waiting)
        EpochTestProtocol.epoch = 7
        request.setValue("rotated-same-user", forHTTPHeaderField: "X-Session-Id")
        let reloadedStore = EvidenceStore(root: root)
        let restarted = CloudEpoch(defaults: UserDefaults(suiteName: suite)!, store: reloadedStore)
        do { _ = try await restarted.authorize(request, session: session); XCTFail("restart must not adopt new generation") } catch {}
        let rows = try await reloadedStore.loadAll()
        XCTAssertTrue(rows.first!.cloudResumeRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.localURL.path))
        XCTAssertEqual(defaults.string(forKey: "cloudEpoch.v1.https://addin.aiworkdeck.com:41"), "3")
        let oldPreparation = await restarted.revision()
        try await restarted.reconnect(base: URL(string: "https://addin.aiworkdeck.com")!, token: "rotated-same-user", session: session)
        do { _ = try await restarted.authorize(request, session: session, expectedGeneration: oldPreparation); XCTFail("old prepared upload cannot acquire reconnected epoch") } catch {}
        let connected = try await restarted.authorize(request, session: session)
        XCTAssertEqual(connected.value(forHTTPHeaderField: "X-Cloud-Epoch"), "7")
        let after = try await reloadedStore.loadAll()
        XCTAssertTrue(after.first!.cloudResumeRequired)
        try await restarted.reconnect(base: URL(string: "https://addin.aiworkdeck.com")!, token: "rotated-same-user", session: session)
        let repeated = try await reloadedStore.loadAll()
        XCTAssertTrue(repeated.first!.cloudResumeRequired)
    }
}
