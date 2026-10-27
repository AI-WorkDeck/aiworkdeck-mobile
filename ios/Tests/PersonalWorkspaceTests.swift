// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import Workdeck

final class PersonalWorkspaceTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PersonalTestProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() { session.invalidateAndCancel(); PersonalTestProtocol.handler = nil }
    private func service(_ account: @escaping () -> String? = { "synthetic" }) -> PersonalWorkspaceService {
        PersonalWorkspaceService(session: session, baseURL: { URL(string: "https://synthetic.invalid")! }, sessionID: account)
    }
    private func event(_ id: String = "event", date: String = "2026-10-28", status: String = "OPEN", remind: String = "2026-10-28T00:00:00Z") throws -> PersonalCalendarEvent {
        try JSONDecoder().decode(PersonalCalendarEvent.self, from: Data("""
        {"id":"\(id)","deviceId":"desktop","projectKey":"alpha","projectName":"Synthetic","title":"Event","dueDate":"\(date)","timeZone":"Asia/Shanghai","status":"\(status)","remindAt":"\(remind)","files":[{"fileId":7,"fileName":"synthetic.pdf"}]}
        """.utf8))
    }
    @MainActor func testLocalReminderPlanFiltersStatusDateAndNext50AndCalendarUsesEventTimezone() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T20:00:00Z")!
        let item = try event()
        XCTAssertTrue(item.isWithin(days: 1, now: now))
        XCTAssertEqual(item.files[0].fileId, "7")
        let entries = try (0..<60).map { try event(String($0), remind: ISO8601DateFormatter().string(from: now.addingTimeInterval(Double($0 + 1)))) }
        let plan = CalendarReminders.upcoming(entries.reversed() + [try event(status: "DONE"), try event(remind: "invalid")], now: now)
        XCTAssertEqual(plan.count, 50); XCTAssertEqual(plan.first?.id, "0"); XCTAssertEqual(plan.last?.id, "49")
    }
    func testFailureRetainsQuestionAndRetryPollsSameIdUntilCompleted() async throws {
        let question = PendingPersonalQuestion(conversationId: nil, message: "Synthetic question")
        var calls: [URLRequest] = []; var failFirst = true
        PersonalTestProtocol.handler = { request in
            calls.append(request)
            if failFirst { failFirst = false; throw URLError(.networkConnectionLost) }
            let running = request.httpMethod == "POST"
            return Data("""
            {"code":0,"data":{"status":"\(running ? "running" : "completed")","conversationId":"conversation","requestId":"\(question.requestId)","answer":"\(running ? "" : "Answer")","sources":[]}}
            """.utf8)
        }
        do { _ = try await service().ask(question); XCTFail("Expected transport failure") } catch {}
        let reply = try await service().ask(question)
        XCTAssertEqual(reply.answer, "Answer")
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[2].url?.path, "/api/mobile/assistant/requests/" + question.requestId)
        XCTAssertEqual(calls[2].value(forHTTPHeaderField: "X-Session-Id"), "synthetic")
    }
    @MainActor func testRestoredQuestionQueriesOriginalRequestAndHistoryWithoutPostingAgain() async throws {
        let question = PendingPersonalQuestion(conversationId: nil, message: "Pending question", requestId: "original-id")
        let saved = try JSONDecoder().decode(SavedPersonalConversation.self, from: JSONEncoder().encode(SavedPersonalConversation(conversationId: nil, pending: question)))
        let model = PersonalWorkspaceModel(); model.service = service(); model.pending = saved.pending; model.draft = saved.pending!.message
        var paths: [String] = []
        PersonalTestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let path = request.url!.path; paths.append(path)
            if path.hasSuffix("status") { return Data(#"{"code":0,"data":{"enabled":true,"subscriptionActive":true,"backupEnabled":true,"summaryCount":1}}"#.utf8) }
            if path.hasSuffix("events") { return Data(#"{"code":0,"data":{"enabled":false,"subscriptionActive":true,"events":[]}}"#.utf8) }
            if path.contains("requests/") { return Data(#"{"code":0,"data":{"status":"completed","conversationId":"conversation","requestId":"original-id","answer":"Recovered","sources":[]}}"#.utf8) }
            return Data(#"{"code":0,"data":{"conversationId":"conversation","messages":[{"role":"user","content":"Pending question"},{"role":"assistant","content":"Recovered"}]}}"#.utf8)
        }
        await model.load()
        XCTAssertTrue(paths.contains("/api/mobile/assistant/requests/original-id"))
        XCTAssertTrue(paths.contains("/api/mobile/assistant/conversations/conversation"))
        XCTAssertEqual(model.messages.last?.content, "Recovered"); XCTAssertNil(model.pending); XCTAssertEqual(model.draft, "")
    }
    @MainActor func testRemoteConsentRevocationClearsPendingWithoutResubmitting() async throws {
        let model = PersonalWorkspaceModel(); model.service = service()
        model.pending = PendingPersonalQuestion(conversationId: nil, message: "Private pending")
        model.draft = "Private pending"; model.messages = [PersonalMessage(role: "assistant", content: "Previous answer", createdAt: nil)]
        PersonalTestProtocol.handler = { request in
            if request.url!.path.hasSuffix("status") { return Data(#"{"code":0,"data":{"enabled":false,"subscriptionActive":true,"backupEnabled":true,"summaryCount":0,"consentEnabled":false}}"#.utf8) }
            XCTAssertTrue(request.url!.path.hasSuffix("events"))
            return Data(#"{"code":0,"data":{"enabled":false,"subscriptionActive":true,"events":[]}}"#.utf8)
        }
        await model.load()
        XCTAssertNil(model.pending); XCTAssertTrue(model.messages.isEmpty); XCTAssertEqual(model.draft, "")
    }
    func testChangedAccountDiscardsLateResponse() async throws {
        var account: String? = "first"
        PersonalTestProtocol.handler = { _ in
            account = "second"
            return Data(#"{"code":0,"data":{"enabled":true,"subscriptionActive":true,"backupEnabled":true,"summaryCount":1}}"#.utf8)
        }
        do { _ = try await service({ account }).status(); XCTFail("Old response must be discarded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    @MainActor func testDisabledAssistantCannotSendAndSuccessfulRevocationClearsConversation() async throws {
        let model = PersonalWorkspaceModel(); model.service = service()
        model.draft = "Private draft"
        PersonalTestProtocol.handler = { request in
            if request.url!.path.hasSuffix("settings") { return Data(#"{"code":0,"data":{"enabled":false,"subscriptionActive":true}}"#.utf8) }
            if request.url!.path.hasSuffix("status") { return Data(#"{"code":0,"data":{"enabled":false,"subscriptionActive":true,"backupEnabled":true,"summaryCount":0}}"#.utf8) }
            if request.url!.path.hasSuffix("events") { return Data(#"{"code":0,"data":{"enabled":false,"subscriptionActive":true,"events":[]}}"#.utf8) }
            XCTFail("Disabled assistant must not send chat"); throw URLError(.badURL)
        }
        await model.send(); XCTAssertEqual(model.draft, "Private draft")
        model.messages = [PersonalMessage(role: "user", content: "Private", createdAt: nil)]
        model.pending = PendingPersonalQuestion(conversationId: nil, message: "Private draft")
        await model.configure("assistant", enabled: false)
        XCTAssertTrue(model.messages.isEmpty); XCTAssertNil(model.pending); XCTAssertEqual(model.draft, "")
    }
}
private final class PersonalTestProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
