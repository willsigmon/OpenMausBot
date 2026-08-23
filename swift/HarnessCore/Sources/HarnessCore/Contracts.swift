import Foundation

// Canonical harness contracts — the Swift port of server/contracts.ts.
// Names and shapes are kept deliberately close to the TypeScript original
// so the two codebases stay mutually readable while openwsigbot migrates.
//
// Deliberate divergence: the driver SPI takes `JSONValue` instead of a
// generic Config parameter. Semantics are identical (decode throws on
// invalid → the registry downgrades to an unavailable shadow), without
// existential gymnastics over heterogeneous associated types.

// ── identifiers ──────────────────────────────────────────────────────────
// Kept as aliases, exactly like upstream, so JSON keys and log lines read
// identically on both sides. Strongly-typed IDs are a deliberate upgrade
// saved for after the port stabilizes.

public typealias DriverKind = String
public typealias InstanceId = String
public typealias ThreadId = String
public typealias TurnId = String

public enum CloudBackend: String, Sendable, Codable {
    case box
    case vps
}

// ── errors ────────────────────────────────────────────────────────────────

public enum ProviderErrorCode: String, Sendable, Codable {
    case missingCLI = "missing_cli"
    case invalidCredentials = "invalid_credentials"
    case inactiveSubscription = "inactive_subscription"
    case quotaOrRegionRestriction = "quota_or_region_restriction"
    case upstreamOutage = "upstream_outage"
    case modelCatalogOutage = "model_catalog_outage"
}

/// Thrown/rejected for provider failures a user could act on. The code is
/// the API; prose is presentation only.
public struct ProviderError: Error, Sendable, CustomStringConvertible {
    public let code: ProviderErrorCode
    public let message: String

    public init(code: ProviderErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "ProviderError(\(code.rawValue)): \(message)" }
}

// ── reasoning effort ──────────────────────────────────────────────────────

/// Reasoning-effort levels, ascending. A union of everything any engine
/// accepts; each driver declares the subset its CLI will take.
public enum EffortLevel: String, Sendable, Codable, CaseIterable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max

    /// Upstream order, ascending — the picker renders in this sequence.
    public static let effortLevels: [EffortLevel] = allCases

    /// Narrow untrusted API/config input before it becomes a selection.
    public static func parse(_ raw: String?) -> EffortLevel? {
        raw.flatMap(EffortLevel.init(rawValue:))
    }
}

// ── engine access ─────────────────────────────────────────────────────────

/// How an engine is presented in the picker rail.
public enum EngineAccess: String, Sendable, Codable {
    /// First-party cloud catalog; Custom is extra.
    case subscription
    /// No subscription catalog; Custom is the product.
    case custom
}

// ── model catalog ─────────────────────────────────────────────────────────

public struct ModelOption: Sendable, Codable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var custom: Bool?
    public var loaded: Bool?
    /// Total context window in tokens, when the driver knows it.
    public var contextWindow: Int?

    public init(
        id: String,
        label: String,
        custom: Bool? = nil,
        loaded: Bool? = nil,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.custom = custom
        self.loaded = loaded
        self.contextWindow = contextWindow
    }
}

public struct ModelCatalog: Sendable, Codable, Equatable, Hashable {
    public var `default`: String
    public var options: [ModelOption]

    public init(default defaultValue: String, options: [ModelOption]) {
        self.default = defaultValue
        self.options = options
    }
}

// ── engine install descriptor ─────────────────────────────────────────────

/// Conforms to CodingKey so EngineInstall can serialize its per-platform
/// command map as a nested JSON object.
public enum InstallPlatform: String, Sendable, Codable, CaseIterable, CodingKey {
    case darwin
    case win32
    case linux
}

/// How a user gets an engine onto their machine. Declared by the driver so
/// adding a provider stays "one file plus a registration": onboarding, the
/// model picker, and settings render from this instead of hardcoded copy.
public struct EngineInstall: Sendable, Codable, Equatable {
    /// One-liner per platform. Omit a platform that has no such command.
    public var command: [InstallPlatform: String]?
    /// Docs or download page — the only route for GUI-installed engines.
    public var docsURL: URL?
    /// Interactive sign-in run after installing, when install isn't enough.
    public var signInCommand: String?
    /// `command` needs npm on PATH, so the UI can say so when Node is absent.
    public var needsNode: Bool?

    public init(
        command: [InstallPlatform: String]? = nil,
        docsURL: URL? = nil,
        signInCommand: String? = nil,
        needsNode: Bool? = nil
    ) {
        self.command = command
        self.docsURL = docsURL
        self.signInCommand = signInCommand
        self.needsNode = needsNode
    }

    enum CodingKeys: String, CodingKey {
        case command
        case docsURL = "docsUrl"
        case signInCommand
        case needsNode
    }

    // Custom Codable: current Foundation toolchains serialize enum-keyed
    // dictionaries as flat alternating key/value ARRAYS, which upstream's
    // Partial<Record<Platform, string>> would never read back. Encode the
    // platform map as a plain JSON object instead. Wire keys are upstream
    // names; the public property shape is unchanged.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.command) {
            let nested = try container.nestedContainer(keyedBy: InstallPlatform.self, forKey: .command)
            var map: [InstallPlatform: String] = [:]
            for platform in InstallPlatform.allCases {
                if let value = try? nested.decode(String.self, forKey: platform) {
                    map[platform] = value
                }
            }
            command = map.isEmpty ? nil : map
        } else {
            command = nil
        }
        docsURL = try container.decodeIfPresent(URL.self, forKey: .docsURL)
        signInCommand = try container.decodeIfPresent(String.self, forKey: .signInCommand)
        needsNode = try container.decodeIfPresent(Bool.self, forKey: .needsNode)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let command, !command.isEmpty {
            var nested = container.nestedContainer(keyedBy: InstallPlatform.self, forKey: .command)
            for (platform, value) in command.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                try nested.encode(value, forKey: platform)
            }
        }
        try container.encodeIfPresent(docsURL, forKey: .docsURL)
        try container.encodeIfPresent(signInCommand, forKey: .signInCommand)
        try container.encodeIfPresent(needsNode, forKey: .needsNode)
    }
}

// ── provider snapshot ─────────────────────────────────────────────────────

public enum SnapshotState: String, Sendable, Codable {
    case available
    case unavailable
}

public enum SnapshotBilling: String, Sendable, Codable {
    case metered
    case subscription
}

public struct ProviderSnapshot: Sendable, Codable, Equatable {
    public var state: SnapshotState
    public var reason: String?
    public var authenticated: Bool?
    public var version: String?
    /// How this instance is paid for, when the driver can tell. A reported
    /// cost on a subscription is notional; the UI labels it as such.
    public var billing: SnapshotBilling?

    public init(
        state: SnapshotState,
        reason: String? = nil,
        authenticated: Bool? = nil,
        version: String? = nil,
        billing: SnapshotBilling? = nil
    ) {
        self.state = state
        self.reason = reason
        self.authenticated = authenticated
        self.version = version
        self.billing = billing
    }
}

// ── request outcomes ──────────────────────────────────────────────────────

/// What became of an answer to an ask. `allowedOnce` grants only the
/// asked-about action — broadening ("always allow") stays a separate,
/// explicit step. `unavailable` is the fail-closed default: no answerer,
/// no action.
public enum RequestOutcome: String, Sendable, Codable {
    case allowedOnce = "allowed-once"
    case rejected
    case answered
    case unavailable
}
