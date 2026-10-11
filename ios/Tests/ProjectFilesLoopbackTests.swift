import CryptoKit
import XCTest
@testable import Workdeck

/// Opt-in integration with the real Java relay on loopback, synthetic files and test billing.
/// Start MobileTransferLoopbackIntegrationTest with -Dawd.loopback.fixture=<path>, then
/// provide AWD_LOOPBACK_FIXTURE to this test host via xctestrun EnvironmentVariables.
final class ProjectFilesLoopbackTests: XCTestCase {
    private struct Fixture: Decodable {
        let baseURL: URL
        let sessionID: String
        let deviceId: String
        let projectKey: String
        let fileID: String
        let fileName: String
        let size: Int64
        let sha256: String
    }

    func testSwiftClientThroughRealCloudAndDesktopHTTP() async throws {
        guard let path = ProcessInfo.processInfo.environment["AWD_LOOPBACK_FIXTURE"] else {
            throw XCTSkip("Requires the isolated Java loopback fixture; never use a production account")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.baseURL.scheme == "http", fixture.baseURL.host == "127.0.0.1" else {
            XCTFail("Integration fixture must be loopback only"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = ProjectFilesService(context: ProjectFilesContext(baseURL: fixture.baseURL,
            sessionID: fixture.sessionID, language: "en-US"), session: session,
            pollingInterval: 100_000_000, pollingAttempts: 100, recoveryRoot: root)
        do {
            let projects = try await client.projects()
            let project = try XCTUnwrap(projects.first { $0.deviceId == fixture.deviceId && $0.key == fixture.projectKey })
            let listing = try await client.files(in: project)
            XCTAssertFalse(listing.truncated)
            let file = try XCTUnwrap(listing.files.first { $0.id == fixture.fileID })
            XCTAssertEqual(file.name, fixture.fileName)
            XCTAssertEqual(file.size, fixture.size)
            let quote = try await client.quote(for: file, in: project)
            XCTAssertGreaterThanOrEqual(quote.credits, 0)
            // Explicit test consent. All billing is replaced by the Java fixture's in-memory mock.
            let pull = try await client.preparePull(project: project, file: file)
            let url = try await client.download(pull)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Int64(data.count), fixture.size)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fixture.sha256)
            let retry = try await client.preparePull(project: project, file: file)
            XCTAssertEqual(retry.requestID, pull.requestID)
            let reusedURL = try await client.download(retry)
            XCTAssertEqual(reusedURL, url)
            await client.removePreview(url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            await client.close()
            try Data("passed".utf8).write(to: URL(fileURLWithPath: path + ".done"), options: .atomic)
        } catch {
            await client.close()
            throw error
        }
    }
}
