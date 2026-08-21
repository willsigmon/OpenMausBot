import Foundation
import XCTest
@testable import CompanionCore

private final class ProfileRequestStub: URLProtocol {
    static var responseBody = Data()
    static var capturedRequest: URLRequest?
    static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = Self.readBody(from: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class ProfileClientTests: XCTestCase {
    private var session: URLSession!
    private var client: CompanionClient!

    override func setUp() {
        super.setUp()
        ProfileRequestStub.capturedRequest = nil
        ProfileRequestStub.capturedBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileRequestStub.self]
        session = URLSession(configuration: configuration)
        client = CompanionClient(
            connection: Connection(name: "Mac", host: "127.0.0.1", port: 8810),
            token: "paired-token",
            session: session
        )
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        client = nil
        super.tearDown()
    }

    func testProfilePatchPreservesServerLimitsWithoutClientTruncation() throws {
        let name = String(repeating: "n", count: 100)
        let title = String(repeating: "t", count: 200)
        let description = String(repeating: "d", count: 4_000)
        let data = try JSONEncoder().encode(BotProfilePatch(
            name: name, title: title, description: description, voice: ""
        ))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["name"] as? String, name)
        XCTAssertEqual(body["title"] as? String, title)
        XCTAssertEqual(body["description"] as? String, description)
        XCTAssertEqual(body["voice"] as? String, "", "empty explicitly selects the workspace default")
    }

    func testProfileClientSendsOnlyFieldsOwnedByTheAction() async throws {
        ProfileRequestStub.responseBody = Self.botResponse

        _ = try await client.updateProfile(
            botId: "avatar-bot",
            patch: BotProfilePatch(avatarCrop: .rounded)
        )

        _ = try XCTUnwrap(ProfileRequestStub.capturedRequest)
        let data = try XCTUnwrap(ProfileRequestStub.capturedBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body.keys.sorted(), ["avatarCrop"])
        XCTAssertEqual(body["avatarCrop"] as? String, "rounded")
    }

    func testProfileClientEncodesAnExplicitAvatarClearAsNull() async throws {
        ProfileRequestStub.responseBody = Self.botResponse

        _ = try await client.updateProfile(
            botId: "avatar-bot",
            patch: BotProfilePatch(avatarUrl: .clear, avatarCrop: .mascot)
        )

        _ = try XCTUnwrap(ProfileRequestStub.capturedRequest)
        let data = try XCTUnwrap(ProfileRequestStub.capturedBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body.keys.sorted(), ["avatarCrop", "avatarUrl"])
        XCTAssertTrue(body["avatarUrl"] is NSNull)
        XCTAssertEqual(body["avatarCrop"] as? String, "mascot")
    }

    func testAvatarGenerationRequestOutlivesTheServersImageTimeout() async throws {
        ProfileRequestStub.responseBody = Self.generatedAvatarResponse

        _ = try await client.generateAvatar(botId: "avatar-bot", prompt: "Friendly researcher")

        let request = try XCTUnwrap(ProfileRequestStub.capturedRequest)
        XCTAssertGreaterThan(request.timeoutInterval, 120)
    }

    func testAvatarFetchAcceptsOnlySharedRasterAttachmentPaths() async throws {
        ProfileRequestStub.responseBody = Data([0x89, 0x50, 0x4e, 0x47])

        let bytes = try await client.avatar(path: "/api/attachments/avatar-123.webp")
        XCTAssertEqual(bytes, ProfileRequestStub.responseBody)
        XCTAssertEqual(ProfileRequestStub.capturedRequest?.url?.path, "/api/attachments/avatar-123.webp")

        for invalid in [
            "/api/attachments/.",
            "/api/attachments/..",
            "/api/attachments/../config.json",
            "/api/attachments/%2e%2e",
            "/api/attachments/avatar.jpeg",
            "/api/attachments/avatar.svg",
            "/api/attachments/avatar_name.png",
        ] {
            await assertBadURL { _ = try await self.client.avatar(path: invalid) }
        }
    }

    func testScopedConnectorStatusRejectsEmptyAndInvalidSlugs() async {
        await assertBadURL { _ = try await self.client.connectorStatuses(slugs: []) }
        await assertBadURL { _ = try await self.client.connectorStatuses(slugs: ["café"]) }
        await assertBadURL { _ = try await self.client.connectorStatuses(slugs: ["gmail", "bad/slash"]) }
    }

    func testConnectorComponentsMatchTheCompanionASCIIContracts() async throws {
        ProfileRequestStub.responseBody = Data(#"{"url":"https://auth.example/connect"}"#.utf8)

        _ = try await client.authorizeConnector(slug: "_internal-tool", alias: nil)
        XCTAssertEqual(ProfileRequestStub.capturedRequest?.url?.path, "/api/connectors/_internal-tool/authorize")

        await assertBadURL { _ = try await self.client.authorizeConnector(slug: "café", alias: nil) }
        await assertBadURL { try await self.client.disconnectConnector(slug: "slack", accountId: "_account") }
        await assertBadURL { try await self.client.disconnectConnector(slug: "slack", accountId: String(repeating: "a", count: 129)) }
    }

    func testUnknownRoutineScheduleCannotBeWrittenBack() async {
        let input = RoutineInput(
            name: "Future routine",
            prompt: "Keep its schedule intact",
            botId: "avatar-bot",
            schedule: .init(type: .unknown),
            durationMinutes: 30
        )

        do {
            _ = try await client.updateRoutine(id: "routine-1", input: input)
            XCTFail("expected an unsupported schedule error")
        } catch let APIError.transport(message) {
            XCTAssertEqual(message, "Choose a supported schedule before saving this routine.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(ProfileRequestStub.capturedRequest)
    }

    private func assertBadURL(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected badURL", file: file, line: line)
        } catch APIError.badURL {
            // Expected: reject locally before sending paired credentials.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private static let botJSON = """
    {
      "id":"avatar-bot","threadId":"avatar-thread","name":"Scout","title":"Researcher",
      "description":"Finds evidence.","notifications":true,"color":"blue",
      "avatarUrl":"/api/attachments/123e4567-e89b-12d3-a456-426614174000.webp",
      "avatarCrop":"rounded","unread":false,
      "modelSelection":{"instanceId":"local","model":"default"},"createdAt":1786742441013
    }
    """

    private static let botResponse = Data("{\"bot\":\(botJSON)}".utf8)
    private static let generatedAvatarResponse = Data(
        "{\"avatarUrl\":\"/api/attachments/123e4567-e89b-12d3-a456-426614174000.webp\",\"bot\":\(botJSON)}".utf8
    )
}
