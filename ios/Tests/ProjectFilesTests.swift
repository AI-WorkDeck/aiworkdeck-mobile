import XCTest
@testable import Workdeck

/// Transport simulations only: no production account, billing, or desktop is contacted.
final class ProjectFilesTests: XCTestCase {
    private let project = RelayProject(deviceId: "desktop-a", deviceName: "Mac", key: "7", name: "Matter")
    private let file = RemoteProjectFile(id: "23", name: "../../document.pdf", path: "folder/document.pdf", size: 3)
    private var session: URLSession!
    private var root: URL!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectFilesURLProtocol.self]
        session = URLSession(configuration: configuration)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
        ProjectFilesURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(sessionID: String = "test-account-a") -> ProjectFilesService {
        ProjectFilesService(context: ProjectFilesContext(baseURL: URL(string: "https://files.invalid")!,
                                                        sessionID: sessionID, language: "en-US"),
                            session: session, pollingInterval: 1, pollingAttempts: 3, recoveryRoot: root)
    }

    func testQuoteIsReadOnlyAndUsesFixedLoginSnapshot() async throws {
        var requests: [URLRequest] = []
        ProjectFilesURLProtocol.handler = { request in
            requests.append(request)
            return .json(#"{"code":0,"credits":2,"balanceCents":null}"#)
        }
        let service = client()
        let quote = try await service.quote(for: file)
        XCTAssertEqual(quote.credits, 2)
        XCTAssertNil(quote.balanceCents)
        let pull = try await service.preparePull(project: project, file: file)
        XCTAssertEqual(pull.project.deviceId, "desktop-a")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/mobile/transfer/quote")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Session-Id"), "test-account-a")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-App-Language"), "en-US")
        XCTAssertEqual(requests[0].url?.host, "files.invalid")
        await service.close()
    }

    func testBusinessErrorCannotMasqueradeAsSuccessfulQuoteOrProjectList() async {
        ProjectFilesURLProtocol.handler = { _ in
            .json(#"{"code":4010,"message":"Session expired","credits":0,"balanceCents":9999}"#)
        }
        let service = client()
        do { _ = try await service.quote(for: file); XCTFail("Expected rejected envelope") }
        catch { XCTAssertEqual(error.localizedDescription, "Session expired") }
        do { _ = try await service.projects(); XCTFail("Expected rejected envelope") }
        catch { XCTAssertEqual(error.localizedDescription, "Session expired") }
        await service.close()
    }

    func testListPollsUntilDoneAndPreservesTruncationMetadata() async throws {
        var polls = 0
        ProjectFilesURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/list") == true {
                return .json(#"{"code":0,"id":10}"#)
            }
            polls += 1
            if polls == 1 { return .json(#"{"code":0,"transfer":{"id":10,"kind":"LIST","status":"PENDING"}}"#) }
            return .json(#"{"code":0,"transfer":{"id":10,"kind":"LIST","status":"DONE","files":[{"id":"23","name":"a.pdf","path":"a.pdf","size":3}],"count":1,"totalCount":2001,"truncated":true}}"#)
        }
        let service = client()
        let listing = try await service.files(in: project)
        XCTAssertEqual(polls, 2)
        XCTAssertEqual(listing.files.count, 1)
        XCTAssertEqual(listing.count, 1)
        XCTAssertEqual(listing.totalCount, 2001)
        XCTAssertTrue(listing.truncated)
        XCTAssertTrue(ProjectFileListing(files: Array(repeating: file, count: 2000)).truncated)
        await service.close()
    }

    func testBadContentIsNeverAcknowledgedAndRetryUsesSamePull() async throws {
        var pulls = 0
        var contents = 0
        var acknowledgements = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": pulls += 1; return .json(#"{"code":0,"id":20,"credits":1}"#)
            case "20": return .json(#"{"code":0,"transfer":{"id":20,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content":
                contents += 1
                return contents == 1 ? .json(#"{"code":1,"message":"Not ready"}"#) : .binary(Data([1, 2, 3]))
            case "ack": acknowledgements += 1; return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let service = client()
        let pull = try await service.preparePull(project: project, file: file)
        do { _ = try await service.download(pull); XCTFail("JSON must not become a preview") } catch {}
        XCTAssertEqual(acknowledgements, 0)
        let url = try await service.download(pull)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertFalse(url.path.contains("document"))
        XCTAssertEqual(pulls, 1)
        XCTAssertEqual(contents, 2)
        XCTAssertEqual(acknowledgements, 1)
        await service.removePreview(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await service.close()
    }

    func testLengthMismatchCannotAcknowledgeOrLeavePreview() async throws {
        var acknowledgements = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": return .json(#"{"code":0,"id":21}"#)
            case "21": return .json(#"{"code":0,"transfer":{"id":21,"kind":"PULL","status":"STAGED","fileSize":4}}"#)
            case "content": return .binary(Data([1, 2, 3]))
            case "ack": acknowledgements += 1; return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let service = client()
        let pull = try await service.preparePull(project: project, file: file)
        do { _ = try await service.download(pull); XCTFail("Expected size rejection") } catch {}
        XCTAssertEqual(acknowledgements, 0)
        await service.close()
    }

    func testLostAckSurvivesRecreationWithoutSecondPullOrDownload() async throws {
        var pulls = 0
        var contents = 0
        var acknowledgements = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": pulls += 1; return .json(#"{"code":0,"id":22}"#)
            case "22": return .json(#"{"code":0,"transfer":{"id":22,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content": contents += 1; return .binary(Data([1, 2, 3]))
            case "ack":
                acknowledgements += 1
                if acknowledgements == 1 { throw URLError(.networkConnectionLost) }
                return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let first = client()
        let original = try await first.preparePull(project: project, file: file)
        do { _ = try await first.download(original); XCTFail("Expected lost ACK response") } catch {}
        await first.close()
        let second = client()
        let restored = try await second.preparePull(project: project, file: file)
        XCTAssertEqual(restored.requestID, original.requestID)
        let url = try await second.download(restored)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(pulls, 1)
        XCTAssertEqual(contents, 1)
        XCTAssertEqual(acknowledgements, 2)
        await second.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPendingUUIDIsPersistedAndIsolatedByLogin() async throws {
        let first = client()
        let pull = try await first.preparePull(project: project, file: file)
        await first.close()
        let second = client()
        let restored = try await second.preparePull(project: project, file: file)
        XCTAssertEqual(pull.requestID, restored.requestID)
        let other = client(sessionID: "test-account-b")
        let otherPull = try await other.preparePull(project: project, file: file)
        XCTAssertNotEqual(pull.requestID, otherPull.requestID)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertFalse(files.contains { $0.path.contains("test-account") })
        for url in files where url.pathExtension == "json" {
            XCTAssertFalse(try String(contentsOf: url).contains("test-account"))
        }
        await second.close()
        await other.close()
    }

    func testOversizedFileIsRejectedBeforeAnyBillableRequest() async throws {
        ProjectFilesURLProtocol.handler = { _ in XCTFail("No network expected"); throw URLError(.badURL) }
        let service = client()
        let oversized = RemoteProjectFile(id: "large", name: "large.pdf", path: "large.pdf",
                                          size: ProjectFilesService.maximumPreviewBytes + 1)
        do { _ = try await service.quote(for: oversized); XCTFail("Expected limit") } catch {}
        do { _ = try await service.download(ProjectFilePull(project: project, file: oversized)); XCTFail("Expected limit") } catch {}
        await service.close()
    }

    func testStagedCancelFailureKeepsOriginalRequestForRetry() async throws {
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": return .json(#"{"code":0,"id":23}"#)
            case "23": return .json(#"{"code":0,"transfer":{"id":23,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content": throw URLError(.notConnectedToInternet)
            case "cancel": return .json(#"{"code":1,"message":"Cannot cancel staged transfer"}"#)
            default: throw URLError(.badURL)
            }
        }
        let service = client()
        let pull = try await service.preparePull(project: project, file: file)
        do { _ = try await service.download(pull); XCTFail("Expected offline content") } catch {}
        do { try await service.cancel(pull); XCTFail("STAGED cancellation must fail") }
        catch { XCTAssertEqual(error.localizedDescription, "Cannot cancel staged transfer") }
        let retry = try await service.preparePull(project: project, file: file)
        XCTAssertEqual(pull.requestID, retry.requestID)
        await service.close()
    }

    func testLostCreationResponseRetriesPersistedUUIDAfterRecreation() async throws {
        var requestIDs: [String] = []
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull":
                let body = try Self.body(of: request)
                requestIDs.append(body["requestId"] as! String)
                XCTAssertEqual(body["deviceId"] as? String, "desktop-a")
                XCTAssertEqual(body["projectKey"] as? String, "7")
                if requestIDs.count == 1 { throw URLError(.networkConnectionLost) }
                return .json(#"{"code":0,"id":24}"#)
            case "24": return .json(#"{"code":0,"transfer":{"id":24,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content": return .binary(Data([1, 2, 3]))
            case "ack": return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let first = client()
        let pull = try await first.preparePull(project: project, file: file)
        do { _ = try await first.download(pull); XCTFail("Expected lost create response") } catch {}
        await first.close()
        let second = client()
        let restored = try await second.preparePull(project: project, file: file)
        _ = try await second.download(restored)
        XCTAssertEqual(requestIDs, [pull.requestID.uuidString, pull.requestID.uuidString])
        await second.close()
    }

    func testClosedWorkspaceCannotSendOrReuseCredentials() async throws {
        ProjectFilesURLProtocol.handler = { _ in XCTFail("Closed workspaces cannot send"); throw URLError(.badURL) }
        let service = client()
        let pull = try await service.preparePull(project: project, file: file)
        await service.close()
        do { _ = try await service.projects(); XCTFail("Expected closed") } catch {}
        do { _ = try await service.download(pull); XCTFail("Expected closed") } catch {}
        do { _ = try await service.quote(for: file); XCTFail("Expected closed") } catch {}
    }

    func testCompletedPreviewReusesPullUntilRemovedAndKeepsProjectIdentity() async throws {
        var pulls = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": pulls += 1; return .json(#"{"code":0,"id":26}"#)
            case "26": return .json(#"{"code":0,"transfer":{"id":26,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content": return .binary(Data([1, 2, 3]))
            case "ack": return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let service = client()
        let first = try await service.preparePull(project: project, file: file)
        let url = try await service.download(first)
        let reused = try await service.preparePull(project: project, file: file)
        let reusedURL = try await service.download(reused)
        XCTAssertEqual(first.requestID, reused.requestID)
        XCTAssertEqual(reusedURL, url)
        XCTAssertEqual(pulls, 1)
        let differentDevice = RelayProject(deviceId: "desktop-b", deviceName: "Other", key: "7", name: "Other")
        let other = try await service.preparePull(project: differentDevice, file: file)
        XCTAssertNotEqual(first.requestID, other.requestID)
        await service.removePreview(url)
        let fresh = try await service.preparePull(project: project, file: file)
        XCTAssertNotEqual(first.requestID, fresh.requestID)
        await service.close()
    }

    func testPendingPollHasBoundedTimeoutWithoutAcknowledgement() async throws {
        var polls = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": return .json(#"{"code":0,"id":25}"#)
            case "25":
                polls += 1
                return .json(#"{"code":0,"transfer":{"id":25,"kind":"PULL","status":"PENDING"}}"#)
            default: XCTFail("Pending transfer cannot download or ACK"); throw URLError(.badURL)
            }
        }
        let service = client()
        let pull = try await service.preparePull(project: project, file: file)
        do { _ = try await service.download(pull); XCTFail("Expected timeout") } catch {}
        XCTAssertEqual(polls, 3)
        let retry = try await service.preparePull(project: project, file: file)
        XCTAssertEqual(pull.requestID, retry.requestID)
        await service.close()
    }

    func testConfirmedTerminalFailureRequiresNewPullWhileUnknownStatusKeepsUUID() async throws {
        var status = "UNRECOGNIZED"
        ProjectFilesURLProtocol.handler = { request in
            if request.url!.lastPathComponent == "pull" { return .json(#"{"code":0,"id":27}"#) }
            return .json("{\"code\":0,\"transfer\":{\"id\":27,\"kind\":\"PULL\",\"status\":\"\(status)\",\"error\":\"Expired transfer\"}}")
        }
        let service = client()
        let original = try await service.preparePull(project: project, file: file)
        do { _ = try await service.download(original); XCTFail("Expected unknown-status rejection") }
        catch { XCTAssertFalse(error is ProjectFileTerminalError) }
        let retained = try await service.preparePull(project: project, file: file)
        XCTAssertEqual(retained.requestID, original.requestID)
        status = "EXPIRED"
        do { _ = try await service.download(original); XCTFail("Expected terminal error") }
        catch {
            XCTAssertTrue(error is ProjectFileTerminalError)
            XCTAssertEqual(error.localizedDescription, "Expired transfer")
        }
        let next = try await service.preparePull(project: project, file: file)
        XCTAssertNotEqual(next.requestID, original.requestID)
        await service.close()
    }

    func testCloseDuringAckRejectsLateResponseAndPreservesRecovery() async throws {
        let ackStarted = expectation(description: "ACK in flight")
        let gate = DispatchSemaphore(value: 0)
        var acknowledgements = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": return .json(#"{"code":0,"id":28}"#)
            case "28": return .json(#"{"code":0,"transfer":{"id":28,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content": return .binary(Data([1, 2, 3]))
            case "ack":
                acknowledgements += 1
                if acknowledgements == 1 {
                    ackStarted.fulfill()
                    _ = gate.wait(timeout: .now() + 5)
                }
                return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let first = client()
        let pull = try await first.preparePull(project: project, file: file)
        let download = Task { try await first.download(pull) }
        await fulfillment(of: [ackStarted], timeout: 5)
        await first.close()
        gate.signal()
        do { _ = try await download.value; XCTFail("Closed service cannot publish a late preview") } catch {}
        let second = client()
        let restored = try await second.preparePull(project: project, file: file)
        XCTAssertEqual(restored.requestID, pull.requestID)
        let url = try await second.download(restored)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(acknowledgements, 2)
        await second.close()
    }

    func testActualBytesMustMatchHeaderBeforeAck() async throws {
        var acknowledgements = 0
        ProjectFilesURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "pull": return .json(#"{"code":0,"id":29}"#)
            case "29": return .json(#"{"code":0,"transfer":{"id":29,"kind":"PULL","status":"STAGED","fileSize":3}}"#)
            case "content": return .init(headers: ["Content-Type": "application/octet-stream", "Content-Length": "3"], data: Data([1, 2]))
            case "ack": acknowledgements += 1; return .json(#"{"code":0}"#)
            default: throw URLError(.badURL)
            }
        }
        let service = client()
        let pull = try await service.preparePull(project: project, file: file)
        do { _ = try await service.download(pull); XCTFail("Short body cannot be acknowledged") } catch {}
        XCTAssertEqual(acknowledgements, 0)
        await service.close()
    }

    func testCatalogAndCloudOnlyFileReadNeverChargesOrAcknowledgesRelay() async throws {
        var paths: [String] = []
        ProjectFilesURLProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session-Id"), "test-account-a")
            if path == "/api/mobile/catalog" {
                return .json(#"[{"projectUid":"cloud-uid","name":"Cloud","locations":[{"kind":"cloud","deviceId":"cloud","key":"3","online":true}]}]"#)
            }
            if path.hasSuffix("/files") {
                return .json(#"{"files":[{"id":"23","uid":"file-uid","source":"cloud","name":"a.pdf","path":"a.pdf","size":3},{"id":"24","uid":"desktop-file","source":"desktop","name":"desktop.pdf","path":"desktop.pdf","size":3}],"count":2,"truncated":false}"#)
            }
            XCTAssertEqual(path, "/api/mobile/catalog/cloud-uid/files/file-uid/content")
            return .binary(Data([1, 2, 3]))
        }
        let service = client()
        let projects = try await service.projects()
        let listing = try await service.files(in: projects[0])
        XCTAssertEqual(listing.files.count, 1, "Cloud location must not route desktop bytes to cloud content")
        let pull = try await service.preparePull(project: projects[0], file: listing.files[0])
        let url = try await service.download(pull)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(paths.count, 3)
        XCTAssertFalse(paths.contains { $0.contains("/transfer/") })
        await service.close()
    }

    func testLegacyPendingPullKeepsUUIDAndRouteAfterCatalogUpgrade() async throws {
        let upgraded = RelayProject(deviceId: "desktop-a", deviceName: "Mac", key: "7", name: "Matter",
                                    projectUid: "uid", locations: [ProjectLocation(kind: "desktop", deviceId: "desktop-a", deviceName: nil, key: "7", online: true)])
        let service = client()
        let old = try await service.preparePull(project: project, file: file)
        let retry = try await service.preparePull(project: upgraded, file: file)
        XCTAssertEqual(old.requestID, retry.requestID)
        XCTAssertEqual(retry.project.deviceId, "desktop-a")
        let anotherDevice = RelayProject(deviceId: "desktop-b", deviceName: nil, key: "8", name: "Matter", projectUid: "uid")
        let other = try await service.preparePull(project: anotherDevice, file: file)
        XCTAssertNotEqual(old.requestID, other.requestID, "Legacy numeric file IDs on different devices are unrelated")
        await service.close()
    }

    private static func body(of request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class ProjectFilesURLProtocol: URLProtocol {
    struct Reply {
        let headers: [String: String]
        let data: Data
        static func json(_ text: String) -> Reply {
            Reply(headers: ["Content-Type": "application/json"], data: Data(text.utf8))
        }
        static func binary(_ data: Data) -> Reply {
            Reply(headers: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count)], data: data)
        }
    }

    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badURL) }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
