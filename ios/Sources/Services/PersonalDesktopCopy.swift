// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct PersonalCopyDestination: Identifiable {
    let project: RelayProject
    let desktop: ProjectLocation?
    var id: String { desktop.map { "desktop:\($0.deviceId):\($0.key)" } ?? "cloud:\(ConversationCopyTarget.projectID(project) ?? 0)" }
    var locationName: String { desktop.map { $0.deviceName ?? $0.deviceId } ?? tr("personal.copy.cloud") }
    static func targets(_ projects: [RelayProject]) -> [Self] {
        projects.flatMap { project in
            var result: [Self] = ConversationCopyTarget.projectID(project) != nil ? [Self(project: project, desktop: nil)] : []
            if project.isDefault != true {
                for location in project.locations ?? [] where eligible(location) { result.append(Self(project: project, desktop: location)) }
            }
            return result
        }
    }
    static func eligible(_ location: ProjectLocation) -> Bool {
        location.kind == "desktop" && location.archiveOnly != true && location.owned == true &&
        !(location.projectUid ?? "").isEmpty && !(location.projectType ?? "").isEmpty &&
        location.projectType != "SCRATCH" && location.projectType != "LOOSE_FILES"
    }
    static func needsUpgrade(_ projects: [RelayProject]) -> Bool {
        projects.contains { project in (project.locations ?? []).contains { $0.kind == "desktop" && ($0.owned == nil || ($0.projectType ?? "").isEmpty || ($0.projectUid ?? "").isEmpty) } }
    }
}

struct DesktopCopyRequest: Codable, Equatable {
    var requestId: String = UUID().uuidString.lowercased()
    let sourceConversationId: String
    let targetProjectUid: String
    let targetDeviceId: String
    let targetProjectKey: String
}
struct DesktopCopyReceipt: Codable {
    let requestId: String
    let status: String
    let sourcePreserved: Bool
    let filesCopied: Bool
    let sourceConversationId: String
    let conversationId: String
    let targetProjectUid: String
    let targetDeviceId: String
    let targetProjectKey: String
    let messageCount: Int
    let expiresAt: String
    let error: String?
    var terminal: Bool { ["DELIVERED", "EXPIRED", "FAILED"].contains(status) }
    var request: DesktopCopyRequest {
        DesktopCopyRequest(requestId: requestId, sourceConversationId: sourceConversationId, targetProjectUid: targetProjectUid, targetDeviceId: targetDeviceId, targetProjectKey: targetProjectKey)
    }
    func validate(_ expected: DesktopCopyRequest) throws {
        guard requestId.lowercased() == expected.requestId.lowercased(), sourceConversationId == expected.sourceConversationId,
              targetProjectUid.lowercased() == expected.targetProjectUid.lowercased(), targetDeviceId == expected.targetDeviceId,
              targetProjectKey == expected.targetProjectKey, sourcePreserved, !filesCopied, !conversationId.isEmpty,
              ["QUEUED", "DELIVERED", "EXPIRED", "FAILED"].contains(status) else { throw APIError(message: tr("error.badResponse")) }
    }
}
struct PersonalDesktopCopy: Codable {
    var request: DesktopCopyRequest
    var receipt: DesktopCopyReceipt?
    var statusKey: String {
        switch receipt?.status {
        case "QUEUED": return "personal.copy.queued"
        case "DELIVERED": return "personal.copy.delivered"
        case "EXPIRED": return "personal.copy.expired"
        case "FAILED": return "personal.copy.failed"
        default: return "personal.copy.unknown"
        }
    }
    var canRetry: Bool { receipt == nil || receipt?.status == "FAILED" || receipt?.status == "EXPIRED" }
}

extension PersonalWorkspaceService {
    func copyToDesktop(_ value: DesktopCopyRequest) async throws -> DesktopCopyReceipt {
        guard let id = value.sourceConversationId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw APIError(message: tr("error.badResponse")) }
        let body = try JSONSerialization.data(withJSONObject: ["requestId": value.requestId, "targetProjectUid": value.targetProjectUid, "targetDeviceId": value.targetDeviceId, "targetProjectKey": value.targetProjectKey])
        let result: DesktopCopyReceipt = try await request("/api/mobile/assistant/conversations/\(id)/copy-to-desktop", method: "POST", body: body)
        try result.validate(value)
        return result
    }
    func desktopCopyStatus(_ value: DesktopCopyRequest) async throws -> DesktopCopyReceipt {
        guard UUID(uuidString: value.requestId) != nil else { throw APIError(message: tr("error.badResponse")) }
        let result: DesktopCopyReceipt = try await request("/api/mobile/assistant/desktop-copies/\(value.requestId)")
        try result.validate(value)
        return result
    }
    func desktopCopies(_ conversation: String) async throws -> [DesktopCopyReceipt] {
        guard let id = conversation.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw APIError(message: tr("error.badResponse")) }
        let values: [DesktopCopyReceipt] = try await request("/api/mobile/assistant/conversations/\(id)/desktop-copies")
        for value in values { guard value.sourceConversationId == conversation else { throw APIError(message: tr("error.badResponse")) }; try value.validate(value.request) }
        return values
    }
}
