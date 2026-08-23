import Foundation

// The driver SPI — the Swift port of upstream's ProviderAdapter /
// ProviderDriver records. The conversation runtime every provider is
// flattened into: sessions start implicitly on the first turn (the
// per-turn-process model), resumeCursor carries the provider-native
// continuation, and events fan out through listeners.
//
// The config parameter is erased to JSONValue on purpose: upstream erases
// too (`AnyProviderDriver = ProviderDriver<any>`), because the registry
// holds heterogeneous drivers. Concrete drivers decode into their own typed
// config structs inside `create`.

public typealias RuntimeEventListener = @Sendable (RuntimeEvent) -> Void
/// Calling the returned closure detaches the listener.
public typealias Unsubscribe = @Sendable () -> Void

// ── turn input ────────────────────────────────────────────────────────────

public struct TranscriptEntry: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ComposioIntegration: Sendable, Codable, Equatable {
    /// A local stdio bridge owns the remote Composio transport. Keeping the
    /// bridge harness-controlled lets it turn connection requests into
    /// trusted chat cards consistently across provider CLIs.
    public var command: String
    public var args: [String]
    public var env: [String: String]

    public init(command: String, args: [String], env: [String: String]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

public struct ComputerIntegration: Sendable, Codable, Equatable {
    public var kind: String?
    public var boxId: String
    public var token: String
    /// The harness's loopback who-is-driving endpoint: the adapter consults
    /// it so a person who takes the wheel pauses the bot's hands mid-turn
    /// instead of typing over them.
    public var control: ControlEndpoint?

    public struct ControlEndpoint: Sendable, Codable, Equatable {
        public var url: String
        public var token: String

        public init(url: String, token: String) {
            self.url = url
            self.token = token
        }
    }

    public init(kind: String? = nil, boxId: String, token: String, control: ControlEndpoint? = nil) {
        self.kind = kind
        self.boxId = boxId
        self.token = token
        self.control = control
    }
}

public struct StdioIntegration: Sendable, Codable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]

    public init(command: String, args: [String], env: [String: String]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

/// Direct stdio connection to a Cua Driver MCP server. `scope` is set only
/// for the user's host desktop; isolated and remote computers intentionally
/// omit it so host-only approval rules cannot change their semantics.
public struct LocalComputerIntegration: Sendable, Codable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var platform: String?
    public var generation: String?
    public var scope: ApprovalScope?

    public init(
        command: String,
        args: [String],
        env: [String: String],
        platform: String? = nil,
        generation: String? = nil,
        scope: ApprovalScope? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.platform = platform
        self.generation = generation
        self.scope = scope
    }
}

/// Per-bot integrations the driver may hand to the agent as tools. A bot
/// must never be told it has an integration its driver cannot mount — it
/// burns turns hunting for tools that aren't there (hence capabilities).
public struct TurnIntegrations: Sendable, Codable, Equatable {
    public var composio: ComposioIntegration?
    public var computer: ComputerIntegration?
    public var localComputer: LocalComputerIntegration?
    /// Peer-agent comms proxy (list_bots / ask_bot); the harness owns turns,
    /// permissions, and recursion limits, the proxy only forwards.
    public var agents: StdioIntegration?
    /// Physical Android phone tools over authorized USB debugging.
    public var phone: StdioIntegration?
    /// dweb network daemon: status, repo, and opencode model access as tools.
    public var dweb: DwebIntegration?

    public struct DwebIntegration: Sendable, Codable, Equatable {
        public var url: String

        public init(url: String) {
            self.url = url
        }
    }

    public init(
        composio: ComposioIntegration? = nil,
        computer: ComputerIntegration? = nil,
        localComputer: LocalComputerIntegration? = nil,
        agents: StdioIntegration? = nil,
        phone: StdioIntegration? = nil,
        dweb: DwebIntegration? = nil
    ) {
        self.composio = composio
        self.computer = computer
        self.localComputer = localComputer
        self.agents = agents
        self.phone = phone
        self.dweb = dweb
    }

    enum CodingKeys: String, CodingKey {
        case composio
        case computer
        case localComputer
        case agents
        case phone
        case dweb
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        composio = try container.decodeIfPresent(ComposioIntegration.self, forKey: .composio)
        computer = try container.decodeIfPresent(ComputerIntegration.self, forKey: .computer)
        localComputer = try container.decodeIfPresent(LocalComputerIntegration.self, forKey: .localComputer)
        agents = try container.decodeIfPresent(StdioIntegration.self, forKey: .agents)
        phone = try container.decodeIfPresent(StdioIntegration.self, forKey: .phone)
        dweb = try container.decodeIfPresent(DwebIntegration.self, forKey: .dweb)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(composio, forKey: .composio)
        try container.encodeIfPresent(computer, forKey: .computer)
        try container.encodeIfPresent(localComputer, forKey: .localComputer)
        try container.encodeIfPresent(agents, forKey: .agents)
        try container.encodeIfPresent(phone, forKey: .phone)
        try container.encodeIfPresent(dweb, forKey: .dweb)
    }
}

/// One turn of conversation handed to a provider.
public struct SendTurnInput: Sendable, Codable, Equatable {
    public var threadId: ThreadId
    public var text: String
    public var model: String?
    public var effort: EffortLevel?
    /// Provider-native continuation (e.g. a claude session id).
    public var resumeCursor: JSONValue?
    /// Prior turns for transcript-replay providers (API-backed drivers).
    public var transcript: [TranscriptEntry]?
    /// Bot persona (name/title/description) as a system prompt.
    public var system: String?
    public var integrations: TurnIntegrations?
    public var cwd: String?

    public init(
        threadId: ThreadId,
        text: String,
        model: String? = nil,
        effort: EffortLevel? = nil,
        resumeCursor: JSONValue? = nil,
        transcript: [TranscriptEntry]? = nil,
        system: String? = nil,
        integrations: TurnIntegrations? = nil,
        cwd: String? = nil
    ) {
        self.threadId = threadId
        self.text = text
        self.model = model
        self.effort = effort
        self.resumeCursor = resumeCursor
        self.transcript = transcript
        self.system = system
        self.integrations = integrations
        self.cwd = cwd
    }
}

public struct TurnStartResult: Sendable, Equatable {
    public var turnId: TurnId

    public init(turnId: TurnId) {
        self.turnId = turnId
    }
}

/// A pending ask answered by a person or policy.
public struct RequestDecision: Sendable, Equatable {
    public enum Behavior: String, Sendable, Codable {
        case allow
        case deny
        case answer
    }

    public var behavior: Behavior
    public var message: String?

    public init(behavior: Behavior, message: String? = nil) {
        self.behavior = behavior
        self.message = message
    }
}

// ── adapter capabilities ──────────────────────────────────────────────────

public struct AdapterCapabilities: Sendable, Equatable {
    public enum SessionModelSwitch: String, Sendable {
        case inSession
        case unsupported
    }

    public var sessionModelSwitch: SessionModelSwitch
    /// True when the driver mounts turn.integrations.agents as MCP tools —
    /// the harness only offers agents tooling (and prompts about it) to
    /// drivers that can actually hand it to the agent.
    public var agentsMcp: Bool
    /// True when the driver mounts the cloud computer tools.
    public var computerMcp: Bool
    /// True when the driver mounts the user's connected apps.
    public var composioMcp: Bool
    /// True when the driver can mount the first-party physical-phone MCP.
    public var phoneMcp: Bool
    /// True when this engine accepts images in the prompt — gates image
    /// paste in the composer. Never offer an attachment an engine cannot open.
    public var images: Bool
    /// Effort levels this driver can pass to its CLI, ascending. Empty =
    /// the driver cannot set effort, so the app never offers the control.
    public var effortLevels: [EffortLevel]
    /// True when the driver keeps a live session across turns and can take
    /// a user message MID-TURN ("steer"). The composer stays open during a
    /// turn on such an engine; others queue one and wait.
    public var queueing: Bool
    /// True only when local MCP calls can reach the human approval channel.
    /// Full-auto/bypass provider instances must leave this false.
    public var localComputerMcp: Bool

    public init(
        sessionModelSwitch: SessionModelSwitch = .unsupported,
        agentsMcp: Bool = false,
        computerMcp: Bool = false,
        composioMcp: Bool = false,
        phoneMcp: Bool = false,
        images: Bool = false,
        effortLevels: [EffortLevel] = [],
        queueing: Bool = false,
        localComputerMcp: Bool = false
    ) {
        self.sessionModelSwitch = sessionModelSwitch
        self.agentsMcp = agentsMcp
        self.computerMcp = computerMcp
        self.composioMcp = composioMcp
        self.phoneMcp = phoneMcp
        self.images = images
        self.effortLevels = effortLevels
        self.queueing = queueing
        self.localComputerMcp = localComputerMcp
    }
}

// ── adapter contract ──────────────────────────────────────────────────────

/// The conversation runtime every provider is flattened into. Failures are
/// thrown; an ask that is no longer there is NOT a failure — `respondToRequest`
/// resolves `.unavailable` and the caller treats it as a deny. Callers branch
/// on outcomes, not on prose.
public protocol ProviderAdapter: AnyObject, Sendable {
    var provider: DriverKind { get }
    var capabilities: AdapterCapabilities { get }

    func sendTurn(_ input: SendTurnInput) async throws -> TurnStartResult
    func interruptTurn(_ threadId: ThreadId, turnId: TurnId?) async throws
    func respondToRequest(
        _ threadId: ThreadId,
        requestId: String,
        decision: RequestDecision
    ) async -> RequestOutcome
    /// Deliver a user message into the RUNNING turn on this thread. Returns
    /// false when there is no live turn to steer (the caller then sends it
    /// as a normal turn). Only drivers whose capabilities declare `queueing`
    /// will meaningfully implement it.
    func steer(_ threadId: ThreadId, text: String) async -> Bool
    func hasSession(_ threadId: ThreadId) -> Bool
    func stopAll() async
    func onEvent(_ listener: @escaping RuntimeEventListener) -> Unsubscribe
}

extension ProviderAdapter {
    public func steer(_ threadId: ThreadId, text: String) async -> Bool { false }
}

// ── instance + driver ─────────────────────────────────────────────────────

public struct DriverMetadata: Sendable, Equatable {
    public var displayName: String
    public var supportsMultipleInstances: Bool
    public var access: EngineAccess?

    public init(
        displayName: String,
        supportsMultipleInstances: Bool = false,
        access: EngineAccess? = nil
    ) {
        self.displayName = displayName
        self.supportsMultipleInstances = supportsMultipleInstances
        self.access = access
    }
}

/// A live provider instance. All per-instance state belongs to the adapter;
/// two instances created from the same driver share nothing.
public protocol ProviderInstance: AnyObject, Sendable {
    var instanceId: InstanceId { get }
    var driverKind: DriverKind { get }
    var displayName: String? { get }
    var enabled: Bool { get }
    var models: ModelCatalog { get }
    var adapter: any ProviderAdapter { get }

    /// Refresh a live catalog without recreating the provider instance.
    func refreshModels() async
    func snapshot() async -> ProviderSnapshot
    /// Cheap one-shot text call — titles, summaries. Nil when unsupported.
    func generateText(_ prompt: String) async throws -> String?
    func dispose() async
}

extension ProviderInstance {
    public func refreshModels() async {}
}

public struct DriverCreateInput: Sendable {
    public var instanceId: InstanceId
    public var displayName: String?
    public var environment: [String: String]
    public var enabled: Bool
    /// The opaque config envelope. Decode inside `create`; invalid config
    /// must throw so the registry downgrades to an unavailable shadow
    /// instead of crashing the fleet.
    public var config: JSONValue

    public init(
        instanceId: InstanceId,
        displayName: String?,
        environment: [String: String],
        enabled: Bool,
        config: JSONValue
    ) {
        self.instanceId = instanceId
        self.displayName = displayName
        self.environment = environment
        self.enabled = enabled
        self.config = config
    }
}

/// The driver SPI: a plain value describing how to build instances.
/// `decodeConfig` throws on invalid; `create` rejects (never throws
/// synchronously) on failure — both downgrade to a shadow snapshot in the
/// registry, which is what makes configs forward/backward compatible.
public protocol ProviderDriver: Sendable {
    var driverKind: DriverKind { get }
    var metadata: DriverMetadata { get }
    /// How to get this engine installed. Omit for engines that need no
    /// local binary (API-key drivers).
    var install: EngineInstall? { get }
    /// Validate the opaque envelope; throw on invalid (leads to a shadow).
    func decodeConfig(_ raw: JSONValue) throws
    func defaultConfig() -> JSONValue
    var models: ModelCatalog { get }
    func create(_ input: DriverCreateInput) async throws -> any ProviderInstance
}
