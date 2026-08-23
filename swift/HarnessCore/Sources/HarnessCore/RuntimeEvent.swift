import Foundation

// Canonical runtime events — the Swift rendering of upstream's ~12-member
// discriminated union. One shared envelope (`RuntimeEventBase`) plus a
// `Kind` enum whose cases carry the per-type payloads. Codable output is
// wire-compatible with the TypeScript shapes: a flat JSON object
// discriminated by the `"type"` key.

public struct RawProtocolMessage: Sendable, Codable, Equatable {
    /// Which native protocol the payload came from (e.g. "claude", "codex").
    public var source: String
    public var payload: JSONValue

    public init(source: String, payload: JSONValue) {
        self.source = source
        self.payload = payload
    }
}

public struct RuntimeEventBase: Sendable, Codable, Equatable {
    public var eventId: String
    public var provider: DriverKind
    public var providerInstanceId: InstanceId?
    public var threadId: ThreadId
    /// RFC 3339 timestamp, matching upstream's serialized form.
    public var createdAt: String
    public var turnId: TurnId?
    public var itemId: String?
    public var requestId: String?
    /// The native protocol message behind this event, when a consumer needs
    /// to see past the normalization.
    public var raw: RawProtocolMessage?

    public init(
        eventId: String,
        provider: DriverKind,
        providerInstanceId: InstanceId? = nil,
        threadId: ThreadId,
        createdAt: String = RuntimeEventBase.now(),
        turnId: TurnId? = nil,
        itemId: String? = nil,
        requestId: String? = nil,
        raw: RawProtocolMessage? = nil
    ) {
        self.eventId = eventId
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.threadId = threadId
        self.createdAt = createdAt
        self.turnId = turnId
        self.itemId = itemId
        self.requestId = requestId
        self.raw = raw
    }

    /// RFC 3339 timestamp with fractional seconds, matching upstream's
    /// serialized form. Public because it backs a public default argument.
    public static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

public struct TokenUsage: Sendable, Codable, Equatable {
    public var input: Int
    public var output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(Int.self, forKey: .input)
        output = try container.decode(Int.self, forKey: .output)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
    }

    enum CodingKeys: String, CodingKey {
        case input
        case output
    }
}

/// The item flavors shared by started/updated/completed events.
public enum ItemKind: String, Sendable, Codable {
    case tool
    case reasoning
    case assistantText = "assistant_text"
}

public enum StreamKind: String, Sendable, Codable {
    case assistantText = "assistant_text"
    case reasoningText = "reasoning_text"
}

public enum RequestType: String, Sendable, Codable {
    case permission
    case question
}

/// Who decided a request: a person, auto mode, the ask's own timeout, the
/// harness (turn ended / settings changed), or nobody — the answerer was
/// already gone and the action never ran.
public enum RequestSource: String, Sendable, Codable {
    case user
    case auto
    case timeout
    case system
    case unavailable
    case peer
}

/// The local computer scope carried by some asks and answers.
public enum ApprovalScope: String, Sendable, Codable {
    case localComputer = "local-computer"
}

public enum RuntimeEventKind: Sendable, Equatable {
    case sessionStarted(sessionId: String?, model: String?)
    case sessionExited(reason: String?)
    case turnStarted
    /// THIS turn's token total as the provider reports it at the end — the
    /// one figure the harness accumulates. `thread.token-usage.updated` is a
    /// live indicator whose meaning differs per driver and must never be summed.
    case turnCompleted(ok: Bool, stopReason: String?, cost: Double?, denials: [String], usage: TokenUsage?)
    case itemStarted(itemKind: ItemKind, title: String?)
    case itemUpdated(itemKind: ItemKind, tokens: Int?)
    case itemCompletedTool(ok: Bool)
    case itemCompletedAssistantText(text: String)
    case contentDelta(streamKind: StreamKind, delta: String)
    case requestOpened(requestType: RequestType, tool: String, summary: String, choices: [String], approvalScope: ApprovalScope?)
    case requestResolved(behavior: DecisionBehavior, source: RequestSource, approvalScope: ApprovalScope?)
    case threadTokenUsageUpdated(usage: TokenUsage)
    /// `setup: true` marks a failure the user fixes by installing or
    /// configuring something, not by retrying — the UI offers setup instead.
    case runtimeError(message: String, setup: Bool)

    public enum DecisionBehavior: String, Sendable, Codable {
        case allow
        case deny
        case answer
    }

    /// The wire discriminator, matching upstream exactly.
    public var typeKey: String {
        switch self {
        case .sessionStarted: return "session.started"
        case .sessionExited: return "session.exited"
        case .turnStarted: return "turn.started"
        case .turnCompleted: return "turn.completed"
        case .itemStarted: return "item.started"
        case .itemUpdated: return "item.updated"
        case .itemCompletedTool, .itemCompletedAssistantText: return "item.completed"
        case .contentDelta: return "content.delta"
        case .requestOpened: return "request.opened"
        case .requestResolved: return "request.resolved"
        case .threadTokenUsageUpdated: return "thread.token-usage.updated"
        case .runtimeError: return "runtime.error"
        }
    }
}

public struct RuntimeEvent: Sendable, Equatable {
    public var base: RuntimeEventBase
    public var kind: RuntimeEventKind

    public init(base: RuntimeEventBase, kind: RuntimeEventKind) {
        self.base = base
        self.kind = kind
    }

    public init(
        provider: DriverKind,
        threadId: ThreadId,
        providerInstanceId: InstanceId? = nil,
        turnId: TurnId? = nil,
        kind: RuntimeEventKind
    ) {
        self.init(
            base: RuntimeEventBase(
                eventId: Self.newEventId(),
                provider: provider,
                providerInstanceId: providerInstanceId,
                threadId: threadId,
                turnId: turnId
            ),
            kind: kind
        )
    }

    // ── id generation ─────────────────────────────────────────────────────

    private static let counter = Counter()

    /// Upstream shape: `ev-<base36 ms>-<base36 counter>`.
    public static func newEventId() -> String {
        let millis = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        return "ev-\(millis)-\(counter.next())"
    }

    public static func newId() -> String { UUID().uuidString.lowercased() }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return String(value, radix: 36)
        }
    }
}

// MARK: - Wire-compatible Codable

extension RuntimeEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case eventId
        case provider
        case providerInstanceId
        case threadId
        case createdAt
        case turnId
        case itemId
        case requestId
        case raw
        case type
        // per-kind keys
        case sessionId
        case model
        case reason
        case ok
        case stopReason
        case cost
        case denials
        case usage
        case itemType
        case title
        case tokens
        case text
        case streamKind
        case delta
        case requestType
        case tool
        case summary
        case choices
        case approvalScope
        case behavior
        case source
        case input
        case output
        case message
        case setup
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = RuntimeEventBase(
            eventId: try container.decode(String.self, forKey: .eventId),
            provider: try container.decode(DriverKind.self, forKey: .provider),
            providerInstanceId: try container.decodeIfPresent(InstanceId.self, forKey: .providerInstanceId),
            threadId: try container.decode(ThreadId.self, forKey: .threadId),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            turnId: try container.decodeIfPresent(TurnId.self, forKey: .turnId),
            itemId: try container.decodeIfPresent(String.self, forKey: .itemId),
            requestId: try container.decodeIfPresent(String.self, forKey: .requestId),
            raw: try container.decodeIfPresent(RawProtocolMessage.self, forKey: .raw)
        )

        switch try container.decode(String.self, forKey: .type) {
        case "session.started":
            kind = .sessionStarted(
                sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
                model: try container.decodeIfPresent(String.self, forKey: .model)
            )
        case "session.exited":
            kind = .sessionExited(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        case "turn.started":
            kind = .turnStarted
        case "turn.completed":
            kind = .turnCompleted(
                ok: try container.decode(Bool.self, forKey: .ok),
                stopReason: try container.decodeIfPresent(String.self, forKey: .stopReason),
                cost: try container.decodeIfPresent(Double.self, forKey: .cost),
                denials: try container.decodeIfPresent([String].self, forKey: .denials) ?? [],
                usage: try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
            )
        case "item.started":
            kind = .itemStarted(
                itemKind: try container.decode(ItemKind.self, forKey: .itemType),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case "item.updated":
            kind = .itemUpdated(
                itemKind: try container.decode(ItemKind.self, forKey: .itemType),
                tokens: try container.decodeIfPresent(Int.self, forKey: .tokens)
            )
        case "item.completed":
            if let text = try container.decodeIfPresent(String.self, forKey: .text) {
                kind = .itemCompletedAssistantText(text: text)
            } else {
                kind = .itemCompletedTool(ok: try container.decode(Bool.self, forKey: .ok))
            }
        case "content.delta":
            kind = .contentDelta(
                streamKind: try container.decode(StreamKind.self, forKey: .streamKind),
                delta: try container.decode(String.self, forKey: .delta)
            )
        case "request.opened":
            kind = .requestOpened(
                requestType: try container.decode(RequestType.self, forKey: .requestType),
                tool: try container.decode(String.self, forKey: .tool),
                summary: try container.decode(String.self, forKey: .summary),
                choices: try container.decodeIfPresent([String].self, forKey: .choices) ?? [],
                approvalScope: try container.decodeIfPresent(ApprovalScope.self, forKey: .approvalScope)
            )
        case "request.resolved":
            kind = .requestResolved(
                behavior: try container.decode(RuntimeEventKind.DecisionBehavior.self, forKey: .behavior),
                source: try container.decode(RequestSource.self, forKey: .source),
                approvalScope: try container.decodeIfPresent(ApprovalScope.self, forKey: .approvalScope)
            )
        case "thread.token-usage.updated":
            // Upstream carries these flat on the event (contracts.ts:
            // `{ type: "thread.token-usage.updated"; input; output }`),
            // matching our own encoder below.
            kind = .threadTokenUsageUpdated(
                usage: TokenUsage(
                    input: try container.decode(Int.self, forKey: .input),
                    output: try container.decode(Int.self, forKey: .output)
                )
            )
        case "runtime.error":
            kind = .runtimeError(
                message: try container.decode(String.self, forKey: .message),
                setup: try container.decodeIfPresent(Bool.self, forKey: .setup) ?? false
            )
        case let unknown:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown runtime event type \(unknown)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base.eventId, forKey: .eventId)
        try container.encode(base.provider, forKey: .provider)
        try container.encodeIfPresent(base.providerInstanceId, forKey: .providerInstanceId)
        try container.encode(base.threadId, forKey: .threadId)
        try container.encode(base.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(base.turnId, forKey: .turnId)
        try container.encodeIfPresent(base.itemId, forKey: .itemId)
        try container.encodeIfPresent(base.requestId, forKey: .requestId)
        try container.encodeIfPresent(base.raw, forKey: .raw)

        try container.encode(kind.typeKey, forKey: .type)
        switch kind {
        case .sessionStarted(let sessionId, let model):
            try container.encodeIfPresent(sessionId, forKey: .sessionId)
            try container.encodeIfPresent(model, forKey: .model)
        case .sessionExited(let reason):
            try container.encodeIfPresent(reason, forKey: .reason)
        case .turnStarted:
            break
        case .turnCompleted(let ok, let stopReason, let cost, let denials, let usage):
            try container.encode(ok, forKey: .ok)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
            try container.encodeIfPresent(cost, forKey: .cost)
            if !denials.isEmpty { try container.encode(denials, forKey: .denials) }
            try container.encodeIfPresent(usage, forKey: .usage)
        case .itemStarted(let itemKind, let title):
            try container.encode(itemKind.rawValue, forKey: .itemType)
            try container.encodeIfPresent(title, forKey: .title)
        case .itemUpdated(let itemKind, let tokens):
            try container.encode(itemKind.rawValue, forKey: .itemType)
            try container.encodeIfPresent(tokens, forKey: .tokens)
        case .itemCompletedTool(let ok):
            try container.encode(ItemKind.tool.rawValue, forKey: .itemType)
            try container.encode(ok, forKey: .ok)
        case .itemCompletedAssistantText(let text):
            try container.encode(ItemKind.assistantText.rawValue, forKey: .itemType)
            try container.encode(text, forKey: .text)
        case .contentDelta(let streamKind, let delta):
            try container.encode(streamKind.rawValue, forKey: .streamKind)
            try container.encode(delta, forKey: .delta)
        case .requestOpened(let requestType, let tool, let summary, let choices, let approvalScope):
            try container.encode(requestType.rawValue, forKey: .requestType)
            try container.encode(tool, forKey: .tool)
            try container.encode(summary, forKey: .summary)
            if !choices.isEmpty { try container.encode(choices, forKey: .choices) }
            try container.encodeIfPresent(approvalScope, forKey: .approvalScope)
        case .requestResolved(let behavior, let source, let approvalScope):
            try container.encode(behavior.rawValue, forKey: .behavior)
            try container.encode(source.rawValue, forKey: .source)
            try container.encodeIfPresent(approvalScope, forKey: .approvalScope)
        case .threadTokenUsageUpdated(let usage):
            try container.encode(usage.input, forKey: .input)
            try container.encode(usage.output, forKey: .output)
        case .runtimeError(let message, let setup):
            try container.encode(message, forKey: .message)
            if setup { try container.encode(true, forKey: .setup) }
        }
    }
}
