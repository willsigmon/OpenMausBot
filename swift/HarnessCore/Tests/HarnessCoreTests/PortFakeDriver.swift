import Darwin
import Foundation
import XCTest
@testable import HarnessCore

// In-memory fake driver used by the Port* registry/bus suites. Defined here
// (not in TestSupport.swift) so this file owns everything it needs — the
// other agent's non-Port* test files are off-limits.

/// Records every listener handed to onEvent and every event it emits, plus
/// the config it was created with, for assertions.
final class FakeAdapter: ProviderAdapter, @unchecked Sendable {
    let provider: DriverKind
    let capabilities: AdapterCapabilities

    private let lock = NSLock()
    private var listeners: [(UUID, RuntimeEventListener)] = []
    private(set) var emitted: [RuntimeEvent] = []
    private(set) var disposed = false

    init(provider: DriverKind, capabilities: AdapterCapabilities = AdapterCapabilities()) {
        self.provider = provider
        self.capabilities = capabilities
    }

    func sendTurn(_ input: SendTurnInput) async throws -> TurnStartResult {
        TurnStartResult(turnId: "fake-turn")
    }

    func interruptTurn(_ threadId: ThreadId, turnId: TurnId?) async throws {}

    func respondToRequest(
        _ threadId: ThreadId,
        requestId: String,
        decision: RequestDecision
    ) async -> RequestOutcome {
        .unavailable
    }

    func hasSession(_ threadId: ThreadId) -> Bool { false }

    func stopAll() async {}

    func dispose() async {
        lock.withLock {
            disposed = true
        }
    }

    func onEvent(_ listener: @escaping RuntimeEventListener) -> Unsubscribe {
        let id = UUID()
        lock.lock()
        listeners.append((id, listener))
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners.removeAll { $0.0 == id }
            self.lock.unlock()
        }
    }

    // ── fake-side controls ────────────────────────────────────────────────

    /// Emit to all current listeners.
    func emit(_ event: RuntimeEvent) {
        lock.lock()
        emitted.append(event)
        let current = listeners.map(\.1)
        lock.unlock()
        for listener in current {
            listener(event)
        }
    }

    var listenerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listeners.count
    }
}

final class FakeInstance: ProviderInstance, @unchecked Sendable {
    let instanceId: InstanceId
    let driverKind: DriverKind
    let displayName: String?
    let enabled: Bool
    var models: ModelCatalog
    let adapter: any ProviderAdapter
    /// When set, snapshot() throws — the registry must surface it as an
    /// unavailable snapshot instead of failing describe().
    var snapshotError: Error?

    init(
        instanceId: InstanceId,
        driverKind: DriverKind,
        displayName: String? = nil,
        enabled: Bool = true,
        models: ModelCatalog = ModelCatalog(default: "fake-model", options: []),
        adapter: FakeAdapter? = nil
    ) {
        self.instanceId = instanceId
        self.driverKind = driverKind
        self.displayName = displayName
        self.enabled = enabled
        self.models = models
        self.adapter = adapter ?? FakeAdapter(provider: driverKind)
    }

    func refreshModels() async {}

    /// The ported SPI's snapshot() never throws; unavailability is a value
    /// on the snapshot, so the fake mirrors that.
    func snapshot() async -> ProviderSnapshot {
        if let snapshotError {
            return ProviderSnapshot(state: .unavailable, reason: String(describing: snapshotError))
        }
        return ProviderSnapshot(state: .available)
    }

    func generateText(_ prompt: String) async throws -> String? { nil }

    func dispose() async {
        await (adapter as? FakeAdapter)?.dispose()
    }
}

/// A decode-failing driver: `decodeConfig` throws unless the raw object has
/// `{"ok": true}`; `create` throws when the environment carries "fail"=1.
struct FakeDriver: ProviderDriver {
    let driverKind: DriverKind
    let metadata = DriverMetadata(displayName: "Fake Engine", access: .subscription)
    let install: EngineInstall? = nil

    /// Set to make create() reject — mirrors a broken CLI spawn.
    var failCreate = false

    static func validConfig(cli: String? = nil) -> JSONValue {
        var obj: [String: JSONValue] = ["ok": true]
        if let cli { obj["cli"] = .string(cli) }
        return .object(obj)
    }

    func decodeConfig(_ raw: JSONValue) throws {
        guard raw["ok"]?.boolValue == true else {
            throw ConfigError.validation("config.ok must be true")
        }
    }

    func defaultConfig() -> JSONValue {
        .object(["ok": true, "cli": "fake-cli"])
    }

    var models: ModelCatalog { ModelCatalog(default: "fake-model", options: []) }

    func create(_ input: DriverCreateInput) async throws -> any ProviderInstance {
        if failCreate || input.environment["fail"] == "1" {
            throw ConfigError.validation("spawn failed (fake)")
        }
        return FakeInstance(
            instanceId: input.instanceId,
            driverKind: driverKind,
            displayName: input.displayName,
            enabled: input.enabled
        )
    }
}

// ── shared assertion helpers ─────────────────────────────────────────────

enum PortTestHelpers {
    /// Drain pending Task hops so bus deliveries land before asserting.
    static func settleBus(_ bus: EventBus) async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    /// Read an NDJSON file as decoded JSON objects, one per line.
    static func readNdjsonLines(path: String) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .map { line in
                let data = Data(line.utf8)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "PortTests", code: 1)
                }
                return obj
            }
    }
}

/// Isolated per-test data dir: sets OMB_DATA_DIR to a unique temp dir and
/// refreshes the DataDirs snapshot. Returns a token that restores the
/// previous override on scope exit (call `defer token.restore()`).
struct DataDirToken {
    private let previous: String?
    private let previousFile: String

    init() {
        previousFile = NSTemporaryDirectory()
            + "port-tests-\(UUID().uuidString.lowercased())"
        previous = ProcessInfo.processInfo.environment["OMB_DATA_DIR"]
        setenv("OMB_DATA_DIR", previousFile, 1)
        DataDirs.reloadEnvironment()
    }

    var dir: String { previousFile }

    func restore() {
        if let previous {
            setenv("OMB_DATA_DIR", previous, 1)
        } else {
            unsetenv("OMB_DATA_DIR")
        }
        DataDirs.reloadEnvironment()
        try? FileManager.default.removeItem(atPath: previousFile)
    }
}
