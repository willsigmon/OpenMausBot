import Foundation

// Provider instance registry — the port of server/harness/registry.ts.
//
// Config map → live instances; unknown driver or config-decode failure
// becomes an UNAVAILABLE SHADOW SNAPSHOT instead of a startup failure. That
// behavior is what makes settings forward/backward compatible — do not
// remove it. dispose tears instances down without touching their siblings.

/// The unavailable stand-in recorded for an instance whose driver is
/// unknown here or whose config failed to decode/create.
public struct ShadowInstance: Sendable, Equatable {
    public var instanceId: InstanceId
    public var driverKind: String
    public var displayName: String?
    /// Raw `config.cli` from disk — an override exists only if this is set.
    public var cli: String?
    public var reason: String

    public init(
        instanceId: InstanceId,
        driverKind: String,
        displayName: String?,
        cli: String?,
        reason: String
    ) {
        self.instanceId = instanceId
        self.driverKind = driverKind
        self.displayName = displayName
        self.cli = cli
        self.reason = reason
    }
}

public enum RegistryEntry: Sendable {
    case live(any ProviderInstance)
    case shadow(ShadowInstance)

    public var instanceId: InstanceId {
        switch self {
        case .live(let instance): return instance.instanceId
        case .shadow(let shadow): return shadow.instanceId
        }
    }

    public var shadowInstance: ShadowInstance? {
        if case .shadow(let shadow) = self { return shadow }
        return nil
    }

    public var liveInstance: (any ProviderInstance)? {
        if case .live(let instance) = self { return instance }
        return nil
    }

    /// The driver kind of either flavor — describe() needs it for both.
    public var driverKind: DriverKind {
        switch self {
        case .live(let instance): return instance.driverKind
        case .shadow(let shadow): return shadow.driverKind
        }
    }
}

/// Row of registry.describe(): id, driver, models, health — the model
/// picker's data source, including the detected-CLI dropdown fields.
public struct InstanceDescription: Sendable {
    public var instanceId: InstanceId
    public var driverKind: DriverKind
    public var displayName: String
    public var snapshot: ProviderSnapshot
    public var models: ModelCatalog
    public var capabilities: DescribeCapabilities
    public var access: EngineAccess?
    public var install: EngineInstall?
    /// Raw `config.cli` override as configured, when one exists.
    public var cli: String?
    /// The `cli` default of the underlying driver, when it has one.
    public var cliDefault: String?
    /// Every copy of the driver's default binary found on the augmented
    /// PATH. Snapshotted per describe() so a newly installed CLI shows up
    /// on the next refresh.
    public var cliCandidates: [String]

    public struct DescribeCapabilities: Sendable, Equatable {
        public var computerMcp: Bool
        public var agentsMcp: Bool
        public var composioMcp: Bool
        public var phoneMcp: Bool
        public var images: Bool
        public var effortLevels: [EffortLevel]
        public var queueing: Bool
        public var localComputerMcp: Bool

        public init(from capabilities: AdapterCapabilities) {
            computerMcp = capabilities.computerMcp == true
            agentsMcp = capabilities.agentsMcp == true
            composioMcp = capabilities.composioMcp == true
            phoneMcp = capabilities.phoneMcp == true
            images = capabilities.images == true
            effortLevels = capabilities.effortLevels
            queueing = capabilities.queueing == true
            localComputerMcp = capabilities.localComputerMcp == true
        }
    }
}

public actor ProviderRegistry {
    private var byId: [InstanceId: RegistryEntry] = [:]
    /// Decoded per-instance `cli` overrides, for describe() — drivers spawn
    /// from their own config; this map only reports what was configured.
    private var cliByInstance: [InstanceId: String] = [:]
    private var driversByKind: [DriverKind: any ProviderDriver]

    public init(drivers: [any ProviderDriver]) {
        driversByKind = Dictionary(drivers.map { ($0.driverKind, $0) },
                                   uniquingKeysWith: { _, replacement in replacement })
    }

    // MARK: loading

    /// Build entries from a fleet map. Unknown driver kinds and decode or
    /// create failures both downgrade to shadow snapshots; neither throws.
    public func load(configs: InstanceConfigMap) async {
        for (instanceId, entry) in configs {
            guard let driver = driversByKind[entry.driver] else {
                byId[instanceId] = .shadow(ShadowInstance(
                    instanceId: instanceId,
                    driverKind: entry.driver,
                    displayName: entry.displayName,
                    cli: Self.cliOfRaw(entry.config),
                    reason: "unknown driver \"\(entry.driver)\" — kept as configured, unavailable here"
                ))
                continue
            }
            do {
                // Upstream: entry.config === undefined ? driver.defaultConfig()
                // : driver.decodeConfig(entry.config). The SPI's decodeConfig
                // validates in place, so the raw envelope rides through.
                let config: JSONValue
                if let raw = entry.config {
                    try driver.decodeConfig(raw)
                    config = raw
                } else {
                    config = driver.defaultConfig()
                }
                // Override detection is on the RAW config, never the decoded
                // one: decodeConfig fills in the driver default ("claude",
                // "codex", …), so reading `cli` there would flag every
                // instance as overridden.
                if let rawCli = Self.cliOfRaw(entry.config) {
                    cliByInstance[instanceId] = rawCli
                }
                let live = try await driver.create(DriverCreateInput(
                    instanceId: instanceId,
                    displayName: entry.displayName ?? driver.metadata.displayName,
                    environment: entry.environment ?? [:],
                    enabled: entry.enabled ?? true,
                    config: config
                ))
                byId[instanceId] = .live(live)
            } catch {
                byId[instanceId] = .shadow(ShadowInstance(
                    instanceId: instanceId,
                    driverKind: entry.driver,
                    displayName: entry.displayName ?? driver.metadata.displayName,
                    cli: Self.cliOfRaw(entry.config),
                    reason: Self.errorText(error)
                ))
            }
        }
    }

    // MARK: lookups

    public func get(_ instanceId: InstanceId) -> (any ProviderInstance)? {
        byId[instanceId]?.liveInstance
    }

    public func entries() -> [RegistryEntry] {
        byId.values.map { $0 }
    }

    public func instances() -> [any ProviderInstance] {
        byId.values.compactMap { $0.liveInstance }
    }

    public func shadowInstances() -> [ShadowInstance] {
        byId.values.compactMap { $0.shadowInstance }
    }

    // MARK: describe

    /// Instance snapshots for the model picker: id, driver, models, health.
    /// Multiple instances may share a driver; each default binary is scanned
    /// once per response instead of repeating filesystem work per row.
    public func describe() async -> [InstanceDescription] {
        // Warm the PATH cache (and kick the async login-shell probe) once so
        // candidate scans below see a consistent, already-augmented PATH.
        _ = EnvPath.augmentedPath()
        var candidatesByName: [String: [String]] = [:]
        func candidatesFor(_ driver: (any ProviderDriver)?) -> [String] {
            guard let name = Self.cliDefaultOf(driver), !name.isEmpty else { return [] }
            if let cachedValue = candidatesByName[name] { return cachedValue }
            let candidates = EnvPath.findCliCandidates(name: name)
            candidatesByName[name] = candidates
            return candidates
        }

        var rows: [InstanceDescription] = []
        for entry in byId.values {
            let driver = driversByKind[entry.driverKind]
            if let shadow = entry.shadowInstance {
                rows.append(InstanceDescription(
                    instanceId: entry.instanceId,
                    driverKind: shadow.driverKind,
                    displayName: shadow.displayName ?? shadow.driverKind,
                    snapshot: ProviderSnapshot(state: .unavailable, reason: shadow.reason),
                    models: ModelCatalog(default: "", options: []),
                    capabilities: InstanceDescription.DescribeCapabilities(from: AdapterCapabilities()),
                    access: driver?.metadata.access ?? .subscription,
                    install: driver?.install,
                    cli: shadow.cli,
                    cliDefault: Self.cliDefaultOf(driver),
                    // a shadow is exactly the "your CLI is broken, pick
                    // another" case where the detected-path dropdown matters
                    // most
                    cliCandidates: candidatesFor(driver)
                ))
                continue
            }
            guard let inst = entry.liveInstance else { continue }
            // The ported SPI's snapshot() is non-throwing — drivers surface
            // unavailability through the snapshot value itself.
            await inst.refreshModels()
            let snapshot = await inst.snapshot()
            rows.append(InstanceDescription(
                instanceId: inst.instanceId,
                driverKind: inst.driverKind,
                displayName: inst.displayName ?? inst.driverKind,
                snapshot: snapshot,
                models: inst.models,
                capabilities: InstanceDescription.DescribeCapabilities(from: inst.adapter.capabilities),
                access: driver?.metadata.access ?? .subscription,
                install: driver?.install,
                cli: cliByInstance[inst.instanceId],
                cliDefault: Self.cliDefaultOf(driver),
                cliCandidates: candidatesFor(driver)
            ))
        }
        return rows
    }

    // MARK: teardown

    /// Dispose every live instance and forget all state.
    public func disposeAll() async {
        let live = instances()
        for instance in live {
            await instance.dispose()
        }
        byId.removeAll()
        cliByInstance.removeAll()
    }

    // MARK: helpers

    /// The `cli` field off a driver's default config, when it has one — the
    /// placeholder an override input shows when nothing is set.
    static func cliDefaultOf(_ driver: (any ProviderDriver)?) -> String? {
        guard let driver else { return nil }
        let cfg = driver.defaultConfig()
        return cfg["cli"]?.stringValue
    }

    /// Raw `config.cli` straight from disk — shadow snapshots can't decode,
    /// so this is the only faithful way to echo back what was configured.
    static func cliOfRaw(_ raw: JSONValue?) -> String? {
        guard let cli = raw?["cli"], case .string(let text) = cli, !text.isEmpty else { return nil }
        return text
    }

    static func errorText(_ error: any Error) -> String {
        let described = String(describing: error)
        // ProviderError's CustomStringConvertible form carries the code and
        // message; plain errors fall back to String(describing:).
        if let provider = error as? ProviderError {
            return provider.message
        }
        return described
    }
}
