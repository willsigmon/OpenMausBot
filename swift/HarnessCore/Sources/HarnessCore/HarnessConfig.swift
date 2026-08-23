import Foundation

// Config load/save — the port of server/config.ts (the value half).
//
// One file, ~/.openmausbot/config.json, env fallbacks for secrets:
//   { "xai": {"key":"xai-…"}, "composio": {"apiKey":"ak_…"}, "box": {"token":"…"},
//     "instances": { "<instanceId>": {"driver":"grok", …} } }
//
// zod becomes hand-rolled decoding with typed errors; merge-patch save
// semantics and the env-wins-over-file credential rule are preserved.

// ── value model ──────────────────────────────────────────────────────────

public struct CredentialPair: Sendable, Codable, Equatable {
    public var key: String?
    public var url: String?

    public init(key: String? = nil, url: String? = nil) {
        self.key = key
        self.url = url
    }
}

public struct TtsConfig: Sendable, Codable, Equatable {
    public var key: String?
    public var voice: String?

    public init(key: String? = nil, voice: String? = nil) {
        self.key = key
        self.voice = voice
    }
}

/// Non-secret profile details shown in the sidebar.
public struct ProfileConfig: Sendable, Codable, Equatable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

public struct RoomsConfig: Sendable, Codable, Equatable {
    /// Minutes; validated at decode to [1, 1440].
    public var turnTimeoutMinutes: Int

    public init(turnTimeoutMinutes: Int) {
        self.turnTimeoutMinutes = turnTimeoutMinutes
    }

    public static let defaultTurnTimeoutMinutes = 5
    public static let minTurnTimeoutMinutes = 1
    public static let maxTurnTimeoutMinutes = 1_440
}

public struct LocalVmConfig: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable {
        case shared
        case perBot = "per-bot"
    }

    public var mode: Mode?
    /// Validated at decode to [1, 4].
    public var maxInstances: Int?

    public init(mode: Mode? = nil, maxInstances: Int? = nil) {
        self.mode = mode
        self.maxInstances = maxInstances
    }

    public static let defaultMode: Mode = .shared
    public static let defaultMaxInstances = 2
    public static let minMaxInstances = 1
    public static let maxMaxInstances = 4
}

/// A named host from the user's SSH config. Authentication stays with SSH;
/// the persisted shape stays deliberately smaller than an SSH connection.
public struct VpsConfig: Sendable, Codable, Equatable {
    public var sshAlias: String?

    public init(sshAlias: String? = nil) {
        self.sshAlias = sshAlias
    }

    static let aliasPattern = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"

    public static func isValidSshAlias(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.range(of: aliasPattern, options: .regularExpression) != nil
    }

    /// Decode + normalize from untyped JSON. Throws on a malformed payload,
    /// mirroring upstream normalizeVpsConfig.
    public static func normalize(_ raw: JSONValue?) throws -> VpsConfig {
        guard let raw, !raw.isNullLiteral else { return VpsConfig() }
        guard let object = raw.objectValue else {
            throw ConfigError.validation("vps must be an object containing an SSH config alias")
        }
        switch object["sshAlias"] {
        case .none, .some(.null), .some(.string("")):
            return VpsConfig()
        case .string(let alias):
            guard isValidSshAlias(alias) else { throw ConfigError.validation(Self.aliasIssue) }
            return VpsConfig(sshAlias: alias)
        case .some:
            throw ConfigError.validation(Self.aliasIssue)
        }
    }

    static let aliasIssue =
        "vps.sshAlias must be a simple SSH config alias (letters, numbers, dot, dash, or underscore)"
}

/// Per-instance fleet entry. `config` stays opaque (JSONValue) exactly like
/// upstream's `unknown` — drivers decode it inside `create`, and invalid
/// config downgrades the instance to a shadow instead of failing startup.
public struct InstanceConfig: Sendable, Codable, Equatable {
    public var driver: DriverKind
    public var displayName: String?
    public var accentColor: String?
    public var environment: [String: String]?
    public var enabled: Bool?
    public var config: JSONValue?

    public init(
        driver: DriverKind,
        displayName: String? = nil,
        accentColor: String? = nil,
        environment: [String: String]? = nil,
        enabled: Bool? = nil,
        config: JSONValue? = nil
    ) {
        self.driver = driver
        self.displayName = displayName
        self.accentColor = accentColor
        self.environment = environment
        self.enabled = enabled
        self.config = config
    }

    /// Hand-rolled decode from untyped JSON (zod instanceConfigSchema):
    /// driver required non-empty; everything else optional and typed.
    public static func decode(_ raw: JSONValue) throws -> InstanceConfig {
        guard let object = raw.objectValue else {
            throw ConfigError.validation("instances entry must be an object")
        }
        guard case .string(let driver) = object["driver"], !driver.isEmpty else {
            throw ConfigError.validation("driver must be a non-empty string")
        }
        func stringField(_ key: String) throws -> String? {
            switch object[key] {
            case .none, .some(.null): return nil
            case .string(let s): return s
            case .some: throw ConfigError.validation("\(key) must be a string")
            }
        }
        var environment: [String: String]?
        if let envRaw = object["environment"] {
            guard let envObject = envRaw.objectValue else {
                throw ConfigError.validation("environment must be an object of strings")
            }
            var decoded: [String: String] = [:]
            for (key, value) in envObject {
                guard case .string(let s) = value else {
                    throw ConfigError.validation("environment must be an object of strings")
                }
                decoded[key] = s
            }
            environment = decoded
        }
        var enabled: Bool?
        if let enabledRaw = object["enabled"] {
            guard case .bool(let flag) = enabledRaw else {
                throw ConfigError.validation("enabled must be a boolean")
            }
            enabled = flag
        }
        return InstanceConfig(
            driver: driver,
            displayName: try stringField("displayName"),
            accentColor: try stringField("accentColor"),
            environment: environment,
            enabled: enabled,
            config: object["config"]
        )
    }
}

/// The whole stored configuration.
public struct AppConfig: Sendable, Codable, Equatable {
    public var xai: CredentialPair?
    public var openaiCompat: CredentialPair?
    public var composio: CredentialPair?
    public var box: BoxConfig?
    public var vps: VpsConfig?
    public var opencodeGo: SingleKeyConfig?
    public var tts: TtsConfig?
    public var imageGen: SingleKeyConfig?
    public var profile: ProfileConfig?
    public var rooms: RoomsConfig?
    public var localVm: LocalVmConfig?
    public var instances: InstanceConfigMap?

    public struct BoxConfig: Sendable, Codable, Equatable {
        public var token: String?
        public init(token: String? = nil) { self.token = token }
    }

    public struct SingleKeyConfig: Sendable, Codable, Equatable {
        public var apiKey: String?
        public init(apiKey: String? = nil) { self.apiKey = apiKey }
    }

    public init(
        xai: CredentialPair? = nil,
        openaiCompat: CredentialPair? = nil,
        composio: CredentialPair? = nil,
        box: BoxConfig? = nil,
        vps: VpsConfig? = nil,
        opencodeGo: SingleKeyConfig? = nil,
        tts: TtsConfig? = nil,
        imageGen: SingleKeyConfig? = nil,
        profile: ProfileConfig? = nil,
        rooms: RoomsConfig? = nil,
        localVm: LocalVmConfig? = nil,
        instances: InstanceConfigMap? = nil
    ) {
        self.xai = xai
        self.openaiCompat = openaiCompat
        self.composio = composio
        self.box = box
        self.vps = vps
        self.opencodeGo = opencodeGo
        self.tts = tts
        self.imageGen = imageGen
        self.profile = profile
        self.rooms = rooms
        self.localVm = localVm
        self.instances = instances
    }
}

/// Upstream: Record<InstanceId, InstanceConfig>. Dictionary preserves no
/// order; consumers sort where display order matters.
public typealias InstanceConfigMap = [InstanceId: InstanceConfig]

// ── decoding ─────────────────────────────────────────────────────────────

private extension JSONValue {
    var isNullLiteral: Bool {
        if case .null = self { return true }
        return false
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    /// Mirrors upstream's `schemaIssue` string ("path message").
    case validation(String)

    public var description: String {
        if case .validation(let message) = self { return message }
        return "config error"
    }
}

extension AppConfig {
    /// Decode from untyped JSON, validating field-by-field. This is the port
    /// of parseStoredConfig: invalid input throws instead of being ignored.
    public static func parseStoredConfig(_ value: JSONValue) throws -> AppConfig {
        guard let object = value.objectValue else {
            throw ConfigError.validation("Invalid stored configuration")
        }
        var cfg = AppConfig()
        for (name, raw) in object {
            switch name {
            case "xai":
                cfg.xai = try decodeCredential(raw, path: "xai")
            case "openaiCompat":
                cfg.openaiCompat = try decodeCredential(raw, path: "openaiCompat")
            case "composio":
                cfg.composio = try decodeCredential(raw, path: "composio")
            case "box":
                cfg.box = try decodeBox(raw)
            case "vps":
                cfg.vps = try VpsConfig.normalize(raw)
            case "opencodeGo":
                cfg.opencodeGo = try decodeSingleKey(raw, path: "opencodeGo")
            case "tts":
                cfg.tts = try decodeTts(raw)
            case "imageGen":
                cfg.imageGen = try decodeSingleKey(raw, path: "imageGen")
            case "profile":
                cfg.profile = try decodeProfile(raw)
            case "rooms":
                cfg.rooms = try decodeRooms(raw)
            case "localVm":
                cfg.localVm = try decodeLocalVm(raw)
            case "instances":
                cfg.instances = try decodeInstances(raw)
            default:
                // Unknown top-level keys are tolerated on read, like zod's
                // default strip behavior — they just do not surface here.
                continue
            }
        }
        return cfg
    }

    private static func decodeCredential(_ raw: JSONValue, path: String) throws -> CredentialPair {
        guard let obj = raw.objectValue else { throw ConfigError.validation("\(path) must be an object") }
        var pair = CredentialPair()
        for (key, value) in obj {
            switch key {
            case "key": pair.key = try optionalText(value, "\(path).key")
            case "url": pair.url = try optionalText(value, "\(path).url")
            default: continue
            }
        }
        return pair
    }

    private static func decodeBox(_ raw: JSONValue) throws -> AppConfig.BoxConfig {
        guard let obj = raw.objectValue else { throw ConfigError.validation("box must be an object") }
        var out = AppConfig.BoxConfig()
        for (key, value) in obj where key == "token" {
            out.token = try optionalText(value, "box.token")
        }
        return out
    }

    private static func decodeSingleKey(_ raw: JSONValue, path: String) throws -> AppConfig.SingleKeyConfig {
        guard let obj = raw.objectValue else { throw ConfigError.validation("\(path) must be an object") }
        var out = AppConfig.SingleKeyConfig()
        for (key, value) in obj where key == "apiKey" {
            out.apiKey = try optionalText(value, "\(path).apiKey")
        }
        return out
    }

    private static func decodeTts(_ raw: JSONValue) throws -> TtsConfig {
        guard let obj = raw.objectValue else { throw ConfigError.validation("tts must be an object") }
        var out = TtsConfig()
        for (key, value) in obj {
            switch key {
            case "key": out.key = try optionalText(value, "tts.key")
            case "voice": out.voice = try optionalText(value, "tts.voice")
            default: continue
            }
        }
        return out
    }

    private static func decodeProfile(_ raw: JSONValue) throws -> ProfileConfig {
        guard let obj = raw.objectValue else { throw ConfigError.validation("profile must be an object") }
        var out = ProfileConfig()
        for (key, value) in obj {
            switch key {
            case "name": out.name = try optionalText(value, "profile.name")
            case "email": out.email = try optionalText(value, "profile.email")
            default: continue
            }
        }
        return out
    }

    private static func decodeRooms(_ raw: JSONValue) throws -> RoomsConfig {
        guard let obj = raw.objectValue else { throw ConfigError.validation("rooms must be an object") }
        let bounds = "\(RoomsConfig.minTurnTimeoutMinutes) and \(RoomsConfig.maxTurnTimeoutMinutes)"
        guard let minutes = obj["turnTimeoutMinutes"]?.intValue else {
            throw ConfigError.validation(
                "rooms.turnTimeoutMinutes must be an integer between \(bounds)")
        }
        guard (RoomsConfig.minTurnTimeoutMinutes...RoomsConfig.maxTurnTimeoutMinutes).contains(minutes) else {
            throw ConfigError.validation(
                "rooms.turnTimeoutMinutes must be an integer between \(bounds)")
        }
        return RoomsConfig(turnTimeoutMinutes: minutes)
    }

    private static func decodeLocalVm(_ raw: JSONValue) throws -> LocalVmConfig {
        guard let obj = raw.objectValue else { throw ConfigError.validation("localVm must be an object") }
        var out = LocalVmConfig()
        for (key, value) in obj {
            switch key {
            case "mode":
                switch value {
                case .null: break
                case .string(LocalVmConfig.Mode.shared.rawValue): out.mode = .shared
                case .string(LocalVmConfig.Mode.perBot.rawValue): out.mode = .perBot
                default:
                    throw ConfigError.validation("localVm.mode must be \"shared\" or \"per-bot\"")
                }
            case "maxInstances":
                let bounds = "\(LocalVmConfig.minMaxInstances) and \(LocalVmConfig.maxMaxInstances)"
                guard let count = value.intValue else {
                    throw ConfigError.validation(
                        "localVm.maxInstances must be an integer between \(bounds)")
                }
                guard (LocalVmConfig.minMaxInstances...LocalVmConfig.maxMaxInstances).contains(count) else {
                    throw ConfigError.validation(
                        "localVm.maxInstances must be an integer between \(bounds)")
                }
                out.maxInstances = count
            default:
                continue
            }
        }
        return out
    }

    private static func decodeInstances(_ raw: JSONValue) throws -> InstanceConfigMap {
        guard let obj = raw.objectValue else { throw ConfigError.validation("instances must be an object") }
        var map = InstanceConfigMap(minimumCapacity: obj.count)
        for (id, entryRaw) in obj {
            do {
                map[id] = try InstanceConfig.decode(entryRaw)
            } catch let error as ConfigError {
                throw ConfigError.validation("instances.\(id): \(error.description)")
            }
        }
        return map
    }

    private static func optionalText(_ value: JSONValue?, _ path: String) throws -> String? {
        switch value {
        case .none, .some(.null): return nil
        case .string(let s): return s
        case .some: throw ConfigError.validation("\(path) must be a string")
        }
    }
}

// ── env-fallback loading ─────────────────────────────────────────────────

public enum HarnessEnvironment {
    /// Environment names of every workspace credential this process may be
    /// holding — injected at boot by the desktop shell or exported by a
    /// developer. Spawned engine CLIs must never inherit them.
    public static let workspaceCredentialEnv: [String] = [
        "XAI_API_KEY",
        "BOX_TOKEN",
        "OPENCODE_API_KEY",
        "OMB_TTS_KEY",
        "OMB_OPENAI_IMAGE_KEY",
        "COMPOSIO_API_KEY",
        "OMB_COMPOSIO_BROKER_TOKEN",
    ]

    /// Env names a provider CLI might read as its own billing identity. A
    /// spawned engine keeps only what its driver explicitly allows: a
    /// foreign key riding along must not flip a subscription CLI onto
    /// pay-as-you-go billing the user never granted.
    public static let providerCredentialEnv: [String] = [
        "ANTHROPIC_API_KEY",
        "FACTORY_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "KIMI_API_KEY",
        "MOONSHOT_API_KEY",
        "OPENAI_API_KEY",
        "OPENCODE_API_KEY",
        "XAI_API_KEY",
        "CURSOR_API_KEY",
        "CURSOR_AUTH_TOKEN",
    ]

    /// Drop every workspace credential from a child-process env.
    public static func stripWorkspaceCredentialEnv(_ env: inout [String: String]) {
        for name in workspaceCredentialEnv { env.removeValue(forKey: name) }
    }
}

extension AppConfig {
    /// Load config.json from the data dir, then let process env win over the
    /// file for every credential. The desktop shell keeps secrets
    /// OS-encrypted and hands them to the process as env at spawn, so the
    /// file value is the dev-mode fallback, not the primary.
    ///
    /// The environment snapshot may be passed explicitly (tests, embedders);
    /// it defaults to the live process environment.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        var cfg = AppConfig()
        if let text = try? String(contentsOfFile: DataDirs.configFile, encoding: .utf8),
           let value = Self.parseJSONText(text),
           let decoded = try? AppConfig.parseStoredConfig(value)
        {
            cfg = decoded
        }
        if let v = environment["XAI_API_KEY"] {
            cfg.xai = (cfg.xai ?? CredentialPair())
            cfg.xai?.key = v
        }
        if let v = environment["COMPOSIO_API_KEY"] {
            cfg.composio = (cfg.composio ?? CredentialPair())
            cfg.composio?.key = v
        }
        if let v = environment["BOX_TOKEN"] {
            cfg.box = (cfg.box ?? AppConfig.BoxConfig())
            cfg.box?.token = v
        }
        if let v = environment["OPENCODE_API_KEY"] {
            cfg.opencodeGo = (cfg.opencodeGo ?? AppConfig.SingleKeyConfig())
            cfg.opencodeGo?.apiKey = v
        }
        if let v = environment["OMB_TTS_KEY"] {
            cfg.tts = (cfg.tts ?? TtsConfig())
            cfg.tts?.key = v
        }
        if let v = environment["OMB_OPENAI_IMAGE_KEY"] {
            cfg.imageGen = (cfg.imageGen ?? AppConfig.SingleKeyConfig())
            cfg.imageGen?.apiKey = v
        }
        return cfg
    }

    /// After save writes a credential, the running process's env must keep
    /// the newest value or load()'s env preference would shadow the save
    /// until relaunch: the UI would show "saved" while every turn still used
    /// the old key. An empty string means the user cleared the credential,
    /// so the variable is dropped and the file becomes authoritative again.
    @discardableResult
    public static func syncCredentialEnv(
        _ patch: AppConfig?,
        into environment: inout [String: String]
    ) -> [String: String] {
        let secrets: [(value: String?, name: String)] = [
            (patch?.xai?.key, "XAI_API_KEY"),
            (patch?.composio?.key, "COMPOSIO_API_KEY"),
            (patch?.box?.token, "BOX_TOKEN"),
            (patch?.opencodeGo?.apiKey, "OPENCODE_API_KEY"),
            (patch?.tts?.key, "OMB_TTS_KEY"),
            (patch?.imageGen?.apiKey, "OMB_OPENAI_IMAGE_KEY"),
        ]
        for (value, name) in secrets {
            guard let value else { continue }
            if !value.isEmpty { environment[name] = value } else { environment.removeValue(forKey: name) }
        }
        return environment
    }
}

// ── persistence ──────────────────────────────────────────────────────────

/// A partial config patch: sections present are merged into what is on
/// disk; absent sections are untouched.
public struct ConfigPatch: Sendable {
    public var xai: CredentialPair?
    public var openaiCompat: CredentialPair?
    public var composio: CredentialPair?
    public var box: AppConfig.BoxConfig?
    public var vps: VpsConfig?
    public var opencodeGo: AppConfig.SingleKeyConfig?
    public var tts: TtsConfig?
    public var imageGen: AppConfig.SingleKeyConfig?
    public var profile: ProfileConfig?
    public var rooms: RoomsConfig?
    public var localVm: LocalVmConfig?
    /// Whole-instance replacement per id, like upstream's patch semantics
    /// for the instances record.
    public var instances: InstanceConfigMap?

    public init() {}
}

extension AppConfig {
    /// Merge a partial config into config.json (secrets never echoed back —
    /// callers report configured-or-not booleans only), written atomically
    /// with 0600 permissions.
    ///
    /// Faithful divergence note: upstream's merge loop covers xai, composio,
    /// box, opencodeGo, tts, imageGen, profile, rooms, localVm — it omits
    /// openaiCompat even though the schema accepts one. This port mirrors
    /// that behavior exactly rather than "fixing" it.
    public static func save(_ patch: ConfigPatch) throws {
        let path = DataDirs.configFile
        var root: [String: JSONValue] = [:]
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let parsed = Self.parseJSONText(text),
           let object = parsed.objectValue
        {
            root = object
        }

        func merge(_ key: String, _ encoded: JSONValue?) {
            guard case .object(let incoming)? = encoded else { return }
            var current = root[key]?.objectValue ?? [:]
            for (field, value) in incoming where !value.isNullLiteral {
                current[field] = value
            }
            root[key] = .object(current)
        }

        // Upstream merge-loop order; openaiCompat deliberately absent.
        merge("xai", Self.sectionJSON(patch.xai))
        merge("composio", Self.sectionJSON(patch.composio))
        merge("box", Self.sectionJSON(patch.box))
        merge("opencodeGo", Self.sectionJSON(patch.opencodeGo))
        merge("tts", Self.sectionJSON(patch.tts))
        merge("imageGen", Self.sectionJSON(patch.imageGen))
        merge("profile", Self.sectionJSON(patch.profile))
        merge("rooms", Self.sectionJSON(patch.rooms))
        merge("localVm", Self.sectionJSON(patch.localVm))

        if let vps = patch.vps {
            root["vps"] = try normalizedVpsJSON(vps)
        }
        if let instances = patch.instances {
            var diskInstances = root["instances"]?.objectValue ?? [:]
            for (instanceId, entry) in instances {
                var current = diskInstances[instanceId]?.objectValue ?? [:]
                current["driver"] = .string(entry.driver)
                if let v = entry.displayName { current["displayName"] = .string(v) } else { current.removeValue(forKey: "displayName") }
                if let v = entry.accentColor { current["accentColor"] = .string(v) } else { current.removeValue(forKey: "accentColor") }
                if let v = entry.environment {
                    current["environment"] = .object(v.mapValues { .string($0) })
                } else { current.removeValue(forKey: "environment") }
                if let v = entry.enabled { current["enabled"] = .bool(v) } else { current.removeValue(forKey: "enabled") }
                if let v = entry.config { current["config"] = v } else { current.removeValue(forKey: "config") }
                diskInstances[instanceId] = .object(current)
            }
            root["instances"] = .object(diskInstances)
        }

        DataDirs.ensureDirs()
        try AtomicWrite.writeString(path, prettyJSON(.object(root)), mode: 0o600)
    }

    /// Set one instance's `config.cli` ("" clears the override back to the
    /// driver default). Creating the instance entry is fine — a config-less
    /// entry rides driver.defaultConfig(). Returns false for unknown
    /// instances when the fleet is explicitly configured. The returned map
    /// stays persistable: credential env instanceConfigs() would have
    /// injected is stripped back out so saving an override never copies
    /// secrets into the instances section of config.json.
    public static func withInstanceCli(
        _ cfg: AppConfig,
        instanceId: InstanceId,
        cli: String
    ) -> (ok: Bool, config: AppConfig) {
        let baseMap = instanceConfigs(cfg)
        guard baseMap[instanceId] != nil else { return (false, cfg) }
        var map = baseMap
        let trimmed = cli.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = map[instanceId]!
        var currentObject = entry.config?.objectValue ?? [:]

        if !trimmed.isEmpty {
            currentObject["cli"] = .string(trimmed)
            entry.config = .object(currentObject)
        } else if currentObject["cli"] != nil {
            currentObject.removeValue(forKey: "cli")
            entry.config = currentObject.isEmpty ? nil : .object(currentObject)
        }
        map[instanceId] = entry

        let nextForInjection = replacingInstances(cfg, with: map)
        for (id, var e) in map {
            guard var env = e.environment else { continue }
            let injected = injectedEnvironment(nextForInjection, driver: e.driver)
            for (k, v) in env where injected[k] == v {
                env.removeValue(forKey: k)
            }
            e.environment = env.isEmpty ? nil : env
            map[id] = e
        }
        return (true, replacingInstances(cfg, with: map))
    }

    /// The credential env instanceConfigs() injects for one driver — shared
    /// with withInstanceCli() so the inject rule and the strip rule cannot
    /// drift apart. Each secret goes only to the driver that actually reads
    /// it; every other engine brings its own login.
    public static func injectedEnvironment(_ cfg: AppConfig, driver: DriverKind) -> [String: String] {
        var env: [String: String] = [:]
        if driver == "grok", let key = cfg.xai?.key, !key.isEmpty { env["XAI_API_KEY"] = key }
        if driver == "openai-compat", let key = cfg.openaiCompat?.key, !key.isEmpty {
            env["OPENAI_COMPAT_API_KEY"] = key
        }
        if driver == "openai-compat", let url = cfg.openaiCompat?.url, !url.isEmpty {
            env["OPENAI_COMPAT_URL"] = url
        }
        if driver == "boxAgent", let token = cfg.box?.token, !token.isEmpty { env["BOX_TOKEN"] = token }
        if driver == "opencodeGo", let key = cfg.opencodeGo?.apiKey, !key.isEmpty {
            env["OPENCODE_API_KEY"] = key
        }
        return env
    }

    /// The effective fleet map: explicit `instances` when set, otherwise the
    /// built-in default fleet. Product fleets pick up newly shipped engines;
    /// a one-off test/shadow map (no claude/grok/codex) is left exactly as
    /// written. Config-file credential keys are injected as per-instance
    /// environment so drivers see them without real process env vars — but
    /// only into the driver that consumes each key.
    public static func instanceConfigs(_ cfg: AppConfig) -> InstanceConfigMap {
        let configured = cfg.instances.flatMap { $0.isEmpty ? nil : $0 }
        var map: InstanceConfigMap = configured ?? Self.defaultFleet
        if let configured,
           configured["claude"] != nil || configured["grok"] != nil || configured["codex"] != nil
        {
            for (id, entry) in productFleetAdditions where map[id] == nil {
                map[id] = entry
            }
        }
        for (id, entry) in map {
            var environment = entry.environment ?? [:]
            for (key, value) in injectedEnvironment(cfg, driver: entry.driver) {
                environment[key] = value
            }
            map[id] = InstanceConfig(
                driver: entry.driver,
                displayName: entry.displayName,
                accentColor: entry.accentColor,
                environment: environment,
                enabled: entry.enabled,
                config: entry.config
            )
        }
        return map
    }

    /// Default fleet: one instance per built-in driver (upstream
    /// defaultInstanceIdForDriver — instanceId defaults to the driver kind).
    /// The API-key `grok` driver stays registered but out of the default
    /// fleet; Google rides `antigravityAgent` since Gemini CLI retired for
    /// consumer tiers on 2026-06-18.
    public static var defaultFleet: InstanceConfigMap {
        [
            "grok": InstanceConfig(driver: "grokAgent"),
            "kimi": InstanceConfig(driver: "kimiAgent"),
            "droid": InstanceConfig(driver: "droidAgent"),
            "cursor": InstanceConfig(driver: "cursorAgent"),
            "claude": InstanceConfig(driver: "claudeAgent"),
            "codex": InstanceConfig(driver: "codex"),
            "antigravity": InstanceConfig(driver: "antigravityAgent"),
            "opencodeGo": InstanceConfig(driver: "opencodeGo"),
            "computer": InstanceConfig(driver: "boxAgent"),
            "openaiCompat": InstanceConfig(driver: "openai-compat"),
            "qwen": InstanceConfig(driver: "qwenAgent"),
            "hermes": InstanceConfig(driver: "hermesAgent"),
            "pi": InstanceConfig(driver: "piAgent"),
        ]
    }

    /// New default-fleet engines that existing product configs would
    /// otherwise never see. Custom-only engines stay custom-only so a
    /// one-off test map is not expanded.
    public static var productFleetAdditions: InstanceConfigMap {
        [
            "cursor": InstanceConfig(driver: "cursorAgent"),
            "openaiCompat": InstanceConfig(driver: "openai-compat"),
            "qwen": InstanceConfig(driver: "qwenAgent"),
            "hermes": InstanceConfig(driver: "hermesAgent"),
            "pi": InstanceConfig(driver: "piAgent"),
        ]
    }

    // ── helpers ───────────────────────────────────────────────────────────

    private static func replacingInstances(_ cfg: AppConfig, with map: InstanceConfigMap) -> AppConfig {
        var copy = cfg
        copy.instances = map
        return copy
    }

    private static func sectionJSON<T: Encodable>(_ section: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(section) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func normalizedVpsJSON(_ vps: VpsConfig) throws -> JSONValue {
        var normalized = VpsConfig()
        if let alias = vps.sshAlias, !alias.isEmpty {
            guard VpsConfig.isValidSshAlias(alias) else {
                throw ConfigError.validation(VpsConfig.aliasIssue)
            }
            normalized.sshAlias = alias
        }
        return sectionJSON(normalized) ?? .object([:])
    }

    /// Parse JSON text into a JSONValue without type-coercion surprises.
    static func parseJSONText(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
