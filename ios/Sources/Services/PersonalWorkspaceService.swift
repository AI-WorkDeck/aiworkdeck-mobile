// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct AssistantStatus: Decodable {
    let enabled: Bool
    let subscriptionActive: Bool
    let backupEnabled: Bool
    let summaryCount: Int
    let reason: String?
    let consentEnabled: Bool?
    let notice: String?
}
struct AssistantSource: Codable, Hashable {
    let deviceId: String
    let projectKey: String
    let projectName: String
    let sourceUpdatedAt: String?
    var project: RelayProject { RelayProject(deviceId: deviceId, deviceName: nil, key: projectKey, name: projectName) }
}
struct AssistantReply: Decodable {
    let status: String?
    let conversationId: String
    let requestId: String
    let answer: String
    let sources: [AssistantSource]
}
struct PersonalMessage: Codable, Identifiable {
    let role: String
    let content: String
    let createdAt: String?
    var id: String { role + ":" + (createdAt ?? "") + ":" + content }
}
struct PersonalConversation: Decodable {
    let conversationId: String
    let messages: [PersonalMessage]
}
struct CalendarFile: Codable, Hashable {
    let fileId: String
    let fileName: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(String.self, forKey: .fileId) { fileId = value } else { fileId = String(try c.decode(Int.self, forKey: .fileId)) }
        fileName = try c.decode(String.self, forKey: .fileName)
    }
    enum CodingKeys: String, CodingKey { case fileId, fileName }
}
struct PersonalCalendarEvent: Codable, Identifiable {
    let id: String
    let deviceId: String
    let projectKey: String
    let projectUid: String?
    let projectName: String
    let title: String
    let dueDate: String
    let dueTime: String?
    let timeZone: String
    let remindAt: String?
    let status: String
    let updatedAt: String?
    let files: [CalendarFile]
    var project: RelayProject { RelayProject(deviceId: deviceId, deviceName: nil, key: projectKey, name: projectName, projectUid: projectUid) }
    var projectIdentity: String { projectUid ?? (deviceId + ":" + projectKey) }
    var reminderDate: Date? { PersonalDates.instant(remindAt) }
    func isWithin(days: Int, now: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dueDate), let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return false }
        return status == "OPEN" && date >= calendar.startOfDay(for: now) && date < end
    }
}
enum PersonalDates {
    static func instant(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    static func display(_ value: String?) -> String? {
        instant(value)?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.formatLocale))
    }
}
struct PersonalCalendar: Decodable {
    let enabled: Bool
    let subscriptionActive: Bool
    let events: [PersonalCalendarEvent]
    let syncedAt: String?
}
struct PersonalSettings: Decodable { let enabled: Bool; let subscriptionActive: Bool }
struct PendingPersonalQuestion: Codable, Equatable {
    let conversationId: String?
    let message: String
    let requestId: String
    init(conversationId: String?, message: String, requestId: String = UUID().uuidString.lowercased()) {
        self.conversationId = conversationId; self.message = message; self.requestId = requestId
    }
}

/// All responses are scoped to the session and host captured before the request.
struct PersonalWorkspaceService {
    var session: URLSession = .shared
    var baseURL: () -> URL = { Backend.baseURL }
    var sessionID: () -> String? = { SessionStore.current }
    private struct Response<T: Decodable>: Decodable { let code: Int; let message: String?; let data: T? }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let host = baseURL()
        guard let account = sessionID() else { throw APIError(message: tr("error.signInRequired")) }
        var req = API.request(host.appendingPathComponent(path))
        req.setValue(account, forHTTPHeaderField: "X-Session-Id")
        req.httpMethod = method; req.httpBody = body
        req.timeoutInterval = 240
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard sessionID() == account, baseURL() == host else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw APIError(message: tr("error.network")) }
        let envelope = try JSONDecoder().decode(Response<T>.self, from: data)
        guard envelope.code == 0, let value = envelope.data else { throw APIError(message: envelope.message ?? tr("error.badResponse")) }
        return value
    }
    func status() async throws -> AssistantStatus { try await request("/api/mobile/assistant/status") }
    func calendar() async throws -> PersonalCalendar { try await request("/api/mobile/calendar/events") }
    func configure(_ feature: String, enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled, "consentVersion": ContractCapabilities.personalConsentVersion])
        let _: PersonalSettings = try await request("/api/mobile/\(feature)/settings", method: "PUT", body: body)
    }
    func history(_ id: String) async throws -> PersonalConversation { try await request("/api/mobile/assistant/conversations/" + id) }
    func ask(_ question: PendingPersonalQuestion) async throws -> AssistantReply {
        let account = sessionID(); let host = baseURL()
        let reply: AssistantReply = try await request("/api/mobile/assistant/chat", method: "POST", body: JSONEncoder().encode(question))
        return try await completed(reply, question: question, account: account, host: host)
    }
    func recover(_ question: PendingPersonalQuestion) async throws -> AssistantReply {
        let account = sessionID(); let host = baseURL()
        let reply: AssistantReply = try await request("/api/mobile/assistant/requests/" + question.requestId)
        return try await completed(reply, question: question, account: account, host: host)
    }
    private func completed(_ initial: AssistantReply, question: PendingPersonalQuestion, account: String?, host: URL) async throws -> AssistantReply {
        var reply = initial
        for _ in 0..<120 {
            if reply.status != "running" { break }
            try await Task.sleep(for: .seconds(2))
            guard sessionID() == account, baseURL() == host else { throw CancellationError() }
            reply = try await request("/api/mobile/assistant/requests/" + question.requestId)
        }
        guard reply.status == "completed", reply.requestId == question.requestId else { throw APIError(message: tr("error.network")) }
        return reply
    }
}
