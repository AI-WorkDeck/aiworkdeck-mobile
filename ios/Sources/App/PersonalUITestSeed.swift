// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
#if DEBUG
import Foundation

/// Explicit UI-test transport. Synthetic requests cannot reach a real account or host.
enum PersonalUITestSeed {
    static let isOn = ["-AWDPersonalUITest", "-AWDWorkspaceUITest", "-AWDRecordingUITest"].contains { ProcessInfo.processInfo.arguments.contains($0) }
    @MainActor private static var captureSeeded = false
    @MainActor static func startCaptureFixture() {
        guard !captureSeeded else { return }; captureSeeded = true
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-AWDSilenceReminderUITest") { AudioRecorderService.shared.beginFakeRecording(seconds: 300) }
        if args.contains("-AWDPauseRecordingUITest") { AudioRecorderService.shared.beginFakeRecording(seconds: 35, paused: true) }
        if args.contains("-AWDPausedVideoUITest") { CameraService.shared.beginFakePausedVideo() }
    }
    static func service() -> PersonalWorkspaceService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PersonalUITestProtocol.self]
        return PersonalWorkspaceService(session: URLSession(configuration: config), baseURL: { URL(string: "https://personal.invalid")! }, sessionID: { "synthetic-personal-account" })
    }
}
private final class PersonalUITestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var value: [String: Any] = [:]
        if path.hasSuffix("assistant/status") {
            value = ["enabled": true, "subscriptionActive": true, "backupEnabled": true, "summaryCount": 2]
        } else if path.hasSuffix("calendar/events") {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            value = ["enabled": true, "subscriptionActive": true, "events": [
                ["id": "synthetic-event", "deviceId": "synthetic-desktop", "projectKey": "alpha", "projectName": "Alpha project", "title": "Review evidence checklist", "dueDate": formatter.string(from: Date()), "dueTime": "14:30", "timeZone": "Asia/Shanghai", "remindAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), "status": "OPEN", "files": [["fileId": 7, "fileName": "evidence.pdf"]]]]]
        } else if path.hasSuffix("assistant/chat") {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(bytes, count: n) } }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            value = ["status": "completed", "conversationId": "synthetic-conversation", "requestId": body["requestId"] ?? "", "answer": "Review the evidence checklist today. The source is Alpha project.", "sources": [["deviceId": "synthetic-desktop", "projectKey": "alpha", "projectName": "Alpha project", "sourceUpdatedAt": "2026-10-27T00:00:00Z"]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": value])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
