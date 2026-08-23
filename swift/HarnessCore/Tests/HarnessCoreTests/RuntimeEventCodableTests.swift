import XCTest
@testable import HarnessCore

final class RuntimeEventCodableTests: XCTestCase {
    // MARK: - discriminator + round trip across all 12 kinds

    /// Every kind must encode a "type" string exactly matching upstream's
    /// discriminated union in server/contracts.ts, and survive a full
    /// encode → decode → re-encode round trip unchanged.
    func testAllKindsRoundTripWithExactTypeDiscriminators() throws {
        for (name, kind) in EventFixtures.allKinds() {
            let event = RuntimeEvent(base: EventFixtures.base(), kind: kind)

            let dict = try encodeToDict(event)
            XCTAssertEqual(dict["type"] as? String, kind.typeKey, "wrong type discriminator for \(name)")

            let decoded = try decodeFromJSON(RuntimeEvent.self, String(data: JSONEncoder().encode(event), encoding: .utf8)!)
            XCTAssertEqual(decoded, event, "round trip mismatch for \(name)")
            XCTAssertEqual(decoded.kind.typeKey, kind.typeKey)
        }
    }

    func testTypeKeyTableMatchesUpstreamStringsExactly() {
        let expected: [String] = [
            "session.started",
            "session.exited",
            "turn.started",
            "turn.completed",
            "item.started",
            "item.updated",
            "item.completed", // two Swift kinds share this upstream type
            "item.completed",
            "content.delta",
            "request.opened",
            "request.resolved",
            "thread.token-usage.updated",
        ]
        let actual = EventFixtures.allKinds().map { $0.kind.typeKey }
        XCTAssertEqual(actual, expected)
        // The 12th member of the union is runtime.error; covered by its own test below.
        XCTAssertEqual(RuntimeEventKind.runtimeError(message: "", setup: false).typeKey, "runtime.error")
    }

    // MARK: - nil omission

    /// Optional fields must be absent from the encoded object when nil —
    /// the wire contract with TypeScript's `?:` optional keys.
    func testOptionalFieldsOmitWhenNil() throws {
        var base = EventFixtures.base()
        base.providerInstanceId = nil
        base.turnId = nil
        base.itemId = nil
        base.requestId = nil
        base.raw = nil
        let event = RuntimeEvent(
            base: base,
            kind: .turnCompleted(ok: false, stopReason: nil, cost: nil, denials: [], usage: nil)
        )

        let dict = try encodeToDict(event)
        for absent in ["providerInstanceId", "turnId", "itemId", "requestId", "raw", "stopReason", "cost", "denials", "usage"] {
            XCTAssertFalse(dict.keys.contains(absent), "\(absent) should be omitted when nil")
        }
        XCTAssertTrue(dict.keys.contains("ok"), "required fields still present")
        XCTAssertEqual(dict["ok"] as? Bool, false)
    }

    func testPresentOptionalsEncodeUnderUpstreamNames() throws {
        var base = EventFixtures.base()
        base.turnId = "turn-7"
        base.itemId = "item-3"
        base.requestId = "req-2"
        base.raw = RawProtocolMessage(source: "claude", payload: ["seq": 1])
        let event = RuntimeEvent(base: base, kind: .itemStarted(itemKind: .tool, title: "Read"))

        let dict = try encodeToDict(event)
        XCTAssertEqual(dict["turnId"] as? String, "turn-7")
        XCTAssertEqual(dict["itemId"] as? String, "item-3")
        XCTAssertEqual(dict["requestId"] as? String, "req-2")
        let raw = try XCTUnwrap(dict["raw"] as? [String: Any])
        XCTAssertEqual(raw["source"] as? String, "claude")
        XCTAssertEqual((raw["payload"] as? [String: Any])?["seq"] as? Int, 1)
        XCTAssertEqual(dict["itemType"] as? String, "tool")
    }

    func testSessionStartedOmitsNullSessionAndModelKeys() throws {
        let event = RuntimeEvent(base: EventFixtures.base(), kind: .sessionStarted(sessionId: nil, model: nil))
        let dict = try encodeToDict(event)
        XCTAssertFalse(dict.keys.contains("sessionId"))
        XCTAssertFalse(dict.keys.contains("model"))

        // And a payload that carries explicit JSON nulls (upstream allows
        // sessionId: string | null) decodes to the same shape.
        let fixture = #"{"eventId":"e1","provider":"codex","threadId":"t1","createdAt":"2026-08-22T04:00:00.000Z","type":"session.started","sessionId":null,"model":null}"#
        let decoded = try decodeFromJSON(RuntimeEvent.self, fixture)
        XCTAssertEqual(decoded.kind.typeKey, "session.started")
        if case .sessionStarted(let sessionId, let model) = decoded.kind {
            XCTAssertNil(sessionId)
            XCTAssertNil(model)
        } else {
            XCTFail("wrong kind")
        }
    }

    func testRuntimeErrorSetupFlagOmitsWhenFalse() throws {
        let plainError = RuntimeEvent(base: EventFixtures.base(), kind: .runtimeError(message: "boom", setup: false))
        var dict = try encodeToDict(plainError)
        XCTAssertFalse(dict.keys.contains("setup"))

        let setupError = RuntimeEvent(base: EventFixtures.base(), kind: .runtimeError(message: "install claude", setup: true))
        dict = try encodeToDict(setupError)
        XCTAssertEqual(dict["setup"] as? Bool, true)
    }

    // MARK: - decoding hand-written upstream-shaped fixtures

    func testDecodeSessionStartedFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.sessionStartedFixture)
        guard case .sessionStarted(let sessionId, let model) = event.kind else {
            return XCTFail("expected sessionStarted, got \(event.kind)")
        }
        XCTAssertEqual(sessionId, "sess_abc123")
        XCTAssertEqual(model, "claude-sonnet-4-5")
        XCTAssertEqual(event.base.provider, "claude")
        XCTAssertEqual(event.base.threadId, "th_001")
        XCTAssertEqual(event.base.eventId, "ev-m9x2k1-0")
    }

    func testDecodeSessionExitedFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.sessionExitedFixture)
        guard case .sessionExited(let reason) = event.kind else {
            return XCTFail("expected sessionExited")
        }
        XCTAssertEqual(reason, "process exited with code 1")
    }

    func testDecodeTurnStartedFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.turnStartedFixture)
        guard case .turnStarted = event.kind else {
            return XCTFail("expected turnStarted")
        }
        XCTAssertEqual(event.base.turnId, "turn_0042")
    }

    func testDecodeTurnCompletedFullFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.turnCompletedFixture)
        guard case .turnCompleted(let ok, let stopReason, let cost, let denials, let usage) = event.kind else {
            return XCTFail("expected turnCompleted")
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(stopReason, "end_turn")
        XCTAssertEqual(cost ?? 0, 0.0315, accuracy: 1e-9)
        XCTAssertEqual(denials, ["bash"])
        XCTAssertEqual(usage?.input, 15432)
        XCTAssertEqual(usage?.output, 891)
    }

    func testDecodeTurnCompletedMinimalFixtureDefaultsDenialsToEmpty() throws {
        // Upstream types denials?: string[] — absence means none.
        let json = """
        {"eventId":"ev-x","provider":"codex","threadId":"t","createdAt":"2026-08-22T04:00:00.000Z",
         "type":"turn.completed","ok":false,"stopReason":"error"}
        """
        let event = try decodeFromJSON(RuntimeEvent.self, json)
        guard case .turnCompleted(let ok, _, _, let denials, let usage) = event.kind else {
            return XCTFail("expected turnCompleted")
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(denials, [])
        XCTAssertNil(usage)
    }

    func testDecodeItemLifecycleFixtures() throws {
        let started = try decodeFromJSON(RuntimeEvent.self, Self.itemStartedFixture)
        guard case .itemStarted(let itemKind, let title) = started.kind else {
            return XCTFail("expected itemStarted")
        }
        XCTAssertEqual(itemKind, .tool)
        XCTAssertEqual(title, "Bash")

        let updated = try decodeFromJSON(RuntimeEvent.self, Self.itemUpdatedFixture)
        guard case .itemUpdated(.reasoning, let tokens) = updated.kind else {
            return XCTFail("expected itemUpdated")
        }
        XCTAssertEqual(tokens, 512)

        let completedTool = try decodeFromJSON(RuntimeEvent.self, Self.itemCompletedToolFixture)
        guard case .itemCompletedTool(let ok) = completedTool.kind else {
            return XCTFail("expected itemCompletedTool")
        }
        XCTAssertFalse(ok)

        let completedText = try decodeFromJSON(RuntimeEvent.self, Self.itemCompletedAssistantTextFixture)
        guard case .itemCompletedAssistantText(let text) = completedText.kind else {
            return XCTFail("expected itemCompletedAssistantText")
        }
        XCTAssertEqual(text, "All set.")
        XCTAssertEqual(completedText.base.itemId, "item_77")
    }

    func testDecodeContentDeltaFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.contentDeltaFixture)
        guard case .contentDelta(let streamKind, let delta) = event.kind else {
            return XCTFail("expected contentDelta")
        }
        XCTAssertEqual(streamKind, .assistantText)
        XCTAssertEqual(delta, "Hel")
    }

    func testDecodeRequestOpenedAndResolvedFixtures() throws {
        let opened = try decodeFromJSON(RuntimeEvent.self, Self.requestOpenedFixture)
        guard case .requestOpened(let requestType, let tool, let summary, let choices, let scope) = opened.kind else {
            return XCTFail("expected requestOpened")
        }
        XCTAssertEqual(requestType, .permission)
        XCTAssertEqual(tool, "computer.click")
        XCTAssertEqual(summary, "click the submit button on staging")
        XCTAssertEqual(choices, ["allow", "deny"])
        XCTAssertEqual(scope, .localComputer)
        XCTAssertEqual(opened.base.requestId, "req_555")

        let resolved = try decodeFromJSON(RuntimeEvent.self, Self.requestResolvedFixture)
        guard case .requestResolved(let behavior, let source, let scope) = resolved.kind else {
            return XCTFail("expected requestResolved")
        }
        XCTAssertEqual(behavior, .answer)
        XCTAssertEqual(source, .user)
        XCTAssertNil(scope)
    }

    func testDecodeThreadTokenUsageUpdatedFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.threadTokenUsageFixture)
        guard case .threadTokenUsageUpdated(let usage) = event.kind else {
            return XCTFail("expected threadTokenUsageUpdated")
        }
        XCTAssertEqual(usage.input, 48111)
        XCTAssertEqual(usage.output, 1204)
    }

    func testDecodeRuntimeErrorFixture() throws {
        let event = try decodeFromJSON(RuntimeEvent.self, Self.runtimeErrorFixture)
        guard case .runtimeError(let message, let setup) = event.kind else {
            return XCTFail("expected runtimeError")
        }
        XCTAssertEqual(message, "claude CLI not found on PATH")
        XCTAssertTrue(setup)
    }

    func testUnknownTypeFailsDecoding() throws {
        let json = """
        {"eventId":"e","provider":"x","threadId":"t","createdAt":"2026-01-01T00:00:00.000Z","type":"future.thing"}
        """
        XCTAssertThrowsError(try decodeFromJSON(RuntimeEvent.self, json)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    func testMissingRequiredBaseFieldFailsDecoding() throws {
        // No threadId — decode must throw rather than fabricate one.
        let json = """
        {"eventId":"e","provider":"x","createdAt":"2026-01-01T00:00:00.000Z","type":"turn.started"}
        """
        XCTAssertThrowsError(try decodeFromJSON(RuntimeEvent.self, json))
    }

    // MARK: - inline upstream-shaped fixtures

    static let sessionStartedFixture = """
    {
      "type": "session.started",
      "eventId": "ev-m9x2k1-0",
      "provider": "claude",
      "providerInstanceId": "inst_claude_main",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:00:00.123Z",
      "sessionId": "sess_abc123",
      "model": "claude-sonnet-4-5"
    }
    """

    static let sessionExitedFixture = """
    {
      "type": "session.exited",
      "eventId": "ev-m9x2k1-1",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:05:00.000Z",
      "reason": "process exited with code 1"
    }
    """

    static let turnStartedFixture = """
    {
      "type": "turn.started",
      "eventId": "ev-m9x2k1-2",
      "provider": "codex",
      "threadId": "th_002",
      "createdAt": "2026-08-22T04:06:00.000Z",
      "turnId": "turn_0042"
    }
    """

    static let turnCompletedFixture = """
    {
      "type": "turn.completed",
      "eventId": "ev-m9x2k1-3",
      "provider": "codex",
      "threadId": "th_002",
      "createdAt": "2026-08-22T04:07:31.500Z",
      "turnId": "turn_0042",
      "ok": true,
      "stopReason": "end_turn",
      "cost": 0.0315,
      "denials": ["bash"],
      "usage": {"input": 15432, "output": 891}
    }
    """

    static let itemStartedFixture = """
    {
      "type": "item.started",
      "eventId": "ev-m9x2k1-4",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:06:10.000Z",
      "turnId": "turn_0043",
      "itemId": "item_71",
      "itemType": "tool",
      "title": "Bash"
    }
    """

    static let itemUpdatedFixture = """
    {
      "type": "item.updated",
      "eventId": "ev-m9x2k1-5",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:06:12.000Z",
      "turnId": "turn_0043",
      "itemId": "item_72",
      "itemType": "reasoning",
      "tokens": 512
    }
    """

    static let itemCompletedToolFixture = """
    {
      "type": "item.completed",
      "eventId": "ev-m9x2k1-6",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:06:15.000Z",
      "turnId": "turn_0043",
      "itemId": "item_71",
      "itemType": "tool",
      "ok": false
    }
    """

    static let itemCompletedAssistantTextFixture = """
    {
      "type": "item.completed",
      "eventId": "ev-m9x2k1-7",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:06:30.000Z",
      "turnId": "turn_0043",
      "itemId": "item_77",
      "itemType": "assistant_text",
      "text": "All set."
    }
    """

    static let contentDeltaFixture = """
    {
      "type": "content.delta",
      "eventId": "ev-m9x2k1-8",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:06:20.000Z",
      "turnId": "turn_0043",
      "itemId": "item_75",
      "streamKind": "assistant_text",
      "delta": "Hel"
    }
    """

    static let requestOpenedFixture = """
    {
      "type": "request.opened",
      "eventId": "ev-m9x2k1-9",
      "provider": "codex",
      "threadId": "th_002",
      "createdAt": "2026-08-22T04:06:40.000Z",
      "turnId": "turn_0042",
      "requestId": "req_555",
      "requestType": "permission",
      "tool": "computer.click",
      "summary": "click the submit button on staging",
      "choices": ["allow", "deny"],
      "approvalScope": "local-computer"
    }
    """

    static let requestResolvedFixture = """
    {
      "type": "request.resolved",
      "eventId": "ev-m9x2k1-a",
      "provider": "codex",
      "threadId": "th_002",
      "createdAt": "2026-08-22T04:06:41.000Z",
      "requestId": "req_555",
      "behavior": "answer",
      "source": "user"
    }
    """

    static let threadTokenUsageFixture = """
    {
      "type": "thread.token-usage.updated",
      "eventId": "ev-m9x2k1-b",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:07:00.000Z",
      "input": 48111,
      "output": 1204
    }
    """

    static let runtimeErrorFixture = """
    {
      "type": "runtime.error",
      "eventId": "ev-m9x2k1-c",
      "provider": "claude",
      "threadId": "th_001",
      "createdAt": "2026-08-22T04:07:10.000Z",
      "message": "claude CLI not found on PATH",
      "setup": true
    }
    """
}
