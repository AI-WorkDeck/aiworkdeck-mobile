// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import Observation
import CryptoKit

/// Registration is opt-in at build time as well as by the signed-in user.
/// The production Apple team must enable Push and issue a matching profile first.
@MainActor final class CalendarPushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await CalendarRemotePush.shared.register(token) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Keep a previously registered channel during transient APNs failures.
    }
}
@MainActor @Observable final class CalendarRemotePush {
    static let shared = CalendarRemotePush()
    struct Availability: Decodable { let available: Bool }
    struct Registration: Decodable { let available: Bool; let registered: Bool }
    struct Unregistration: Decodable { let registered: Bool }
    private var operations: Task<Void, Never>?
    private var accountScope: String? {
        guard let token = SessionStore.current else { return nil }
        return SHA256.hash(data: Data((Backend.baseURL.absoluteString + ":" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var registered: Bool {
        get { accountScope != nil && UserDefaults.standard.string(forKey: "personal.push.registered") == accountScope }
        set { if newValue { UserDefaults.standard.set(accountScope, forKey: "personal.push.registered") } else { UserDefaults.standard.removeObject(forKey: "personal.push.registered") } }
    }
    private var token: String?
    private var generation = UUID()
    private var registeringAccount: String?
    private var enabled = false
    private var installationID: String {
        if let value = UserDefaults.standard.string(forKey: "personal.push.installation"), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "personal.push.installation"); return value
    }
    private var buildEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "CalendarRemotePushEnabled") as? String == "YES" }
    func prepare() async {
        guard buildEnabled, SessionStore.current != nil else { return }
        enabled = true
        let version = generation
        do {
            let status: Availability = try await PersonalWorkspaceService().request("/api/mobile/calendar/push/status")
            guard version == generation, enabled else { return }
            guard status.available else { registered = false; return }
            registeringAccount = SessionStore.current
            if let token { await register(token) }
            else { UIApplication.shared.registerForRemoteNotifications() }
        } catch { /* A transient outage preserves an already registered channel. */ }
    }
    func register(_ token: String) async {
        self.token = token
        guard enabled, registeringAccount == SessionStore.current, SessionStore.current != nil else { return }
        let version = generation; let account = registeringAccount
        let environment = Bundle.main.object(forInfoDictionaryKey: "CalendarPushEnvironment") as? String ?? "sandbox"
        guard ["sandbox", "production"].contains(environment) else { return }
        let previous = operations
        let work = Task { @MainActor in
            await previous?.value
            guard version == self.generation, self.enabled, account == SessionStore.current else { return }
            do {
                let body = try JSONSerialization.data(withJSONObject: ["installationId": self.installationID, "token": token, "environment": environment])
                let response: Registration = try await PersonalWorkspaceService().request("/api/mobile/calendar/push/device", method: "PUT", body: body)
                guard version == self.generation, self.enabled else { return }
                self.registered = response.available && response.registered
                if self.registered { await CalendarReminders.shared.replace([]) }
            } catch { /* Retain a known channel; failed rebind is not proof it was removed. */ }
        }
        operations = work
        await work.value
    }
    func clear() {
        generation = UUID(); enabled = false; registeringAccount = nil
        // Do not let a late PUT overtake logout DELETE or the next account's PUT.
        // Failed unregistration retains the known channel so local fallback cannot duplicate it.
        guard buildEnabled, let account = SessionStore.current else { return }
        let host = Backend.baseURL; let id = installationID; let scope = accountScope
        let previous = operations
        operations = Task { @MainActor in
            await previous?.value
            let service = PersonalWorkspaceService(baseURL: { host }, sessionID: { account })
            let result: Unregistration? = try? await service.request("/api/mobile/calendar/push/device/" + id, method: "DELETE")
            if result?.registered == false, UserDefaults.standard.string(forKey: "personal.push.registered") == scope {
                UserDefaults.standard.removeObject(forKey: "personal.push.registered")
            }
        }
    }
}
