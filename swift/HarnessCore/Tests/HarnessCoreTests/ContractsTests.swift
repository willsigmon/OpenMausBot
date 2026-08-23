import XCTest
@testable import HarnessCore

final class ContractsTests: XCTestCase {
    // MARK: - EffortLevel

    /// The picker renders in upstream's EFFORT_LEVELS order; the Swift
    /// enum's declaration order must match it exactly.
    func testEffortLevelOrderingMatchesUpstream() {
        XCTAssertEqual(
            EffortLevel.effortLevels,
            [.none, .low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(EffortLevel.allCases.map(\.rawValue), ["none", "low", "medium", "high", "xhigh", "max"])
    }

    func testParseNarrowsValidStrings() {
        for level in EffortLevel.allCases {
            XCTAssertEqual(EffortLevel.parse(level.rawValue), level)
        }
    }

    func testParseRejectsInvalidAndNilInput() {
        XCTAssertNil(EffortLevel.parse("ultra"))
        XCTAssertNil(EffortLevel.parse(""))
        XCTAssertNil(EffortLevel.parse("HIGH")) // case-sensitive, like upstream isEffortLevel
        XCTAssertNil(EffortLevel.parse(nil))
        XCTAssertNil(EffortLevel.parse("none ")) // no trimming of untrusted input
    }

    func testEffortLevelCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(EffortLevel.xhigh)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"xhigh\"")
        let decoded = try JSONDecoder().decode(EffortLevel.self, from: encoded)
        XCTAssertEqual(decoded, .xhigh)
        XCTAssertThrowsError(try JSONDecoder().decode(EffortLevel.self, from: Data("\"nope\"".utf8)))
    }

    // MARK: - EngineInstall

    /// Swift property `docsURL` must map to the upstream wire key `docsUrl`.
    func testEngineInstallEncodesDocsURLUnderDocsUrlKey() throws {
        let install = EngineInstall(
            command: [.darwin: "npm i -g @openai/codex", .linux: "npm i -g @openai/codex"],
            docsURL: URL(string: "https://developers.openai.com/codex/cli")!,
            signInCommand: "codex login",
            needsNode: true
        )

        let dict = try encodeToDict(install)
        XCTAssertTrue(dict.keys.contains("docsUrl"), "wire key must be docsUrl, got keys: \(dict.keys.sorted())")
        XCTAssertFalse(dict.keys.contains("docsURL"))
        XCTAssertEqual(dict["docsUrl"] as? String, "https://developers.openai.com/codex/cli")
        XCTAssertEqual(dict["signInCommand"] as? String, "codex login")
        XCTAssertEqual(dict["needsNode"] as? Bool, true)

        let command = try XCTUnwrap(dict["command"] as? [String: Any])
        XCTAssertEqual(command["darwin"] as? String, "npm i -g @openai/codex")
        XCTAssertFalse(command.keys.contains("win32"), "platforms without commands stay omitted")

        let decoded = try decodeFromJSON(EngineInstall.self, String(data: JSONEncoder().encode(install), encoding: .utf8)!)
        XCTAssertEqual(decoded, install)
    }

    func testEngineInstallDecodesUpstreamDocsUrlKey() throws {
        let json = """
        {"docsUrl": "https://claude.ai/download", "needsNode": false}
        """
        let install = try decodeFromJSON(EngineInstall.self, json)
        XCTAssertEqual(install.docsURL?.absoluteString, "https://claude.ai/download")
        XCTAssertEqual(install.needsNode, false)
        XCTAssertNil(install.command)
        XCTAssertNil(install.signInCommand)

        var dict = try encodeToDict(install)
        XCTAssertTrue(dict.keys.contains("docsUrl"))

        // Optional-everything encodes to an empty object with no nulls.
        dict = try encodeToDict(EngineInstall())
        XCTAssertTrue(dict.isEmpty)
    }

    // MARK: - ProviderSnapshot / ModelCatalog / misc contracts

    func testProviderSnapshotRoundTripAndNilOmission() throws {
        let available = ProviderSnapshot(state: .available, version: "1.2.3", billing: .subscription)
        let dict = try encodeToDict(available)
        XCTAssertEqual(dict["state"] as? String, "available")
        XCTAssertFalse(dict.keys.contains("reason"), "nil reason omitted")
        XCTAssertFalse(dict.keys.contains("authenticated"))

        let decoded = try decodeFromJSON(ProviderSnapshot.self, String(data: JSONEncoder().encode(available), encoding: .utf8)!)
        XCTAssertEqual(decoded, available)

        let unavailable = try decodeFromJSON(
            ProviderSnapshot.self,
            #"{"state": "unavailable", "reason": "missing_cli"}"#
        )
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.reason, "missing_cli")
        XCTAssertNil(unavailable.billing)
    }

    func testModelCatalogRoundTrip() throws {
        let catalog = ModelCatalog(
            default: "gpt-5.2",
            options: [
                ModelOption(id: "gpt-5.2", label: "GPT-5.2", contextWindow: 400_000),
                ModelOption(id: "custom-1", label: "Custom", custom: true),
            ]
        )

        let decoded = try decodeFromJSON(ModelCatalog.self, String(data: JSONEncoder().encode(catalog), encoding: .utf8)!)
        XCTAssertEqual(decoded, catalog)

        let fixture = """
        {"default": "sonnet", "options": [{"id": "sonnet", "label": "Sonnet", "loaded": true}]}
        """
        let fromFixture = try decodeFromJSON(ModelCatalog.self, fixture)
        XCTAssertEqual(fromFixture.default, "sonnet")
        XCTAssertEqual(fromFixture.options.first?.loaded, true)
        XCTAssertNil(fromFixture.options.first?.contextWindow)
    }

    func testRequestOutcomeRawValuesMatchUpstream() {
        XCTAssertEqual(RequestOutcome.allowedOnce.rawValue, "allowed-once")
        XCTAssertEqual(RequestOutcome.rejected.rawValue, "rejected")
        XCTAssertEqual(RequestOutcome.answered.rawValue, "answered")
        XCTAssertEqual(RequestOutcome.unavailable.rawValue, "unavailable")
    }

    func testSendTurnInputRoundTripWithIntegrations() throws {
        let input = SendTurnInput(
            threadId: "th_9",
            text: "check staging",
            model: "sonnet",
            effort: .medium,
            resumeCursor: ["session_id": "abc"],
            transcript: [TranscriptEntry(role: .user, text: "hi"), TranscriptEntry(role: .assistant, text: "hello")],
            system: "You are helpful.",
            integrations: TurnIntegrations(
                computer: ComputerIntegration(
                    boxId: "box-1",
                    token: "tok",
                    control: ComputerIntegration.ControlEndpoint(url: "http://127.0.0.1:7781", token: "t2")
                ),
                localComputer: LocalComputerIntegration(
                    command: "cua-driver",
                    args: ["--stdio"],
                    env: [:],
                    platform: "darwin",
                    scope: .localComputer
                ),
                dweb: TurnIntegrations.DwebIntegration(url: "http://127.0.0.1:8090")
            ),
            cwd: "/tmp"
        )

        let decoded = try decodeFromJSON(SendTurnInput.self, String(data: JSONEncoder().encode(input), encoding: .utf8)!)
        XCTAssertEqual(decoded, input)
        XCTAssertEqual(decoded.effort, .medium)
        XCTAssertEqual(decoded.transcript?.count, 2)
        XCTAssertEqual(decoded.integrations?.localComputer?.scope, .localComputer)

        // Empty integrations encode to {} — optional keys all omitted.
        let empty = try encodeToDict(TurnIntegrations())
        XCTAssertTrue(empty.isEmpty)
    }

    func testProviderErrorDescriptionCarriesCodeAndMessage() {
        let error = ProviderError(code: .missingCLI, message: "install the CLI first")
        XCTAssertEqual(error.description, "ProviderError(missing_cli): install the CLI first")
        XCTAssertEqual(error.code.rawValue, "missing_cli")
    }
}
