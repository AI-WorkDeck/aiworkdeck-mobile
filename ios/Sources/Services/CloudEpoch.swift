// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Persistent permission fence: account identity is stable across session rotation.
actor CloudEpoch {
    static let shared = CloudEpoch()
    nonisolated static let launchAt = Date()
    private let defaults: UserDefaults
    private let store: EvidenceStore
    private var generation = 0
    private var snapshots: [String: String] = [:]
    init(defaults: UserDefaults = .standard, store: EvidenceStore = .shared) { self.defaults = defaults; self.store = store }
    func revision() -> Int { generation }
    func accountChanged() async throws { invalidate(); try await pause() }
    func invalidate() { generation += 1; snapshots.removeAll() }
    private func pause() async throws {
        for item in try await store.loadAll() where [.waiting,.uploading,.failed].contains(item.state) {
            try await store.updateState(item.id, to: .failed, cloudResumeRequired: true)
        }
    }
    func reconnect(base: URL, token: String, session: URLSession = .shared) async throws {
        invalidate()
        try await pause()
        var request = URLRequest(url: base.appendingPathComponent("/api/mobile/media"))
        request.httpMethod = "POST"; request.setValue(token, forHTTPHeaderField: "X-Session-Id")
        _ = try await authorize(request, session: session, explicit: true)
    }
    func authorize(_ request: URLRequest, session: URLSession, explicit: Bool = false, expectedGeneration: Int? = nil) async throws -> URLRequest {
        guard let url = request.url, url.scheme == "https", ["addin.aiworkdeck.com", "addin.workdeck.ai"].contains(url.host ?? ""),
              let token = request.value(forHTTPHeaderField: "X-Session-Id"), !token.isEmpty,
              request.httpMethod != nil, request.httpMethod != "GET",
              !["/api/auth/", "/api/account/", "/api/feedback", "/api/mobile/billing/"].contains(where: url.path.hasPrefix) else { return request }
        let revision = expectedGeneration ?? generation
        guard revision == generation else { throw APIError(message: tr("postpaid.refresh")) }
        let origin = "https://\(url.host!)\(url.port.map { ":\($0)" } ?? "")"
        let key = origin + "\n" + token
        var epoch = snapshots[key]
        if epoch == nil || explicit {
            func read(_ path: String) async throws -> (Data, Int) {
                var probe = request; probe.url = URL(string: origin + path)!
                probe.httpMethod = "GET"; probe.httpBody = nil; probe.setValue(nil, forHTTPHeaderField: "Content-Type")
                let (data, response) = try await session.data(for: probe)
                guard let http = response as? HTTPURLResponse else { throw APIError(message: tr("postpaid.refresh")) }
                return (data, http.statusCode)
            }
            struct Identity: Decodable { struct User: Decodable { let id: Int64 }; let code: Int; let data: User? }
            let (identity, identityCode) = try await read("/api/auth/me")
            guard identityCode == 200, let user = try? JSONDecoder().decode(Identity.self, from: identity),
                  user.code == 0, let id = user.data?.id, id > 0 else { throw APIError(message: tr("error.unauthorized")) }
            let binding = "cloudEpoch.v1." + origin + ":" + String(id)
            let (data, code) = try await read("/api/mobile/billing/cloud-state")
            struct State: Decodable { struct Access: Decodable { let epoch: Int64 }; let cloudAccess: Access }
            if code == 404 { epoch = "legacy" }
            else {
                guard code == 200, let state = try? JSONDecoder().decode(State.self, from: data), state.cloudAccess.epoch >= 0 else { throw APIError(message: tr("postpaid.refresh")) }
                epoch = String(state.cloudAccess.epoch)
            }
            guard revision == generation else { throw APIError(message: tr("postpaid.refresh")) }
            let legacyQueue = try await store.loadAll().contains { [.waiting,.uploading,.failed].contains($0.state) && $0.capturedAt < Self.launchAt }
            guard revision == generation else { throw APIError(message: tr("postpaid.refresh")) }
            let old = defaults.string(forKey: binding)
            if !explicit && ((old != nil && old != epoch) || (old == nil && legacyQueue)) {
                try await pause()
                throw APIError(message: tr("postpaid.refresh"))
            }
            defaults.set(epoch, forKey: binding)
            snapshots[key] = epoch
        }
        guard revision == generation else { throw APIError(message: tr("postpaid.refresh")) }
        try Task.checkCancellation()
        var authorized = request
        if let epoch, epoch != "legacy" { authorized.setValue(epoch, forHTTPHeaderField: "X-Cloud-Epoch") }
        return authorized
    }
}
