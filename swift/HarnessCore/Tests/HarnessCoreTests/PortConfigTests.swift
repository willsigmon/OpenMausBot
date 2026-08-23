import Darwin
import Foundation
import XCTest
@testable import HarnessCore

final class PortConfigTests: XCTestCase {
    private var token: DataDirToken?

    override func setUp() {
        super.setUp()
        token = DataDirToken()
    }

    override func tearDown() {
        token?.restore()
        token = nil
        super.tearDown()
    }

    private var configPath: String { DataDirs.join(DataDirs.dataDir, "config.json") }

    func testEnsureDirsCreatesLayoutAndHonorsOmbDataDirOverride() throws {
        let dir = try XCTUnwrap(token?.dir)
        XCTAssertFalse(dir.hasSuffix(".openmausbot"), "override must win over the home default")
        let resolved = DataDirs.ensureDirs()
        XCTAssertEqual(resolved, dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DataDirs.join(dir, "events")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DataDirs.join(dir, "native")))
        XCTAssertEqual(DataDirs.eventsDir, DataDirs.join(dir, "events"))
        XCTAssertEqual(DataDirs.nativeDir, DataDirs.join(dir, "native"))
    }

    func testLoadMissingFileYieldsEmptyConfig() {
        let cfg = AppConfig.load(environment: [:])
        XCTAssertEqual(cfg, AppConfig())
    }

    func testRoundTripPersistsAndReloads() throws {
        var patch = ConfigPatch()
        patch.profile = ProfileConfig(name: "Will", email: "will@example.com")
        patch.rooms = RoomsConfig(turnTimeoutMinutes: 12)
        patch.instances = [
            "claude": InstanceConfig(driver: "claudeAgent", displayName: "Main Claude"),
            "custom": InstanceConfig(
                driver: "grokAgent",
                environment: ["XAI_API_KEY": "injected"],
                enabled: false,
                config: .object(["cli": "/opt/tools/grok", "temperature": .double(0.4)])
            ),
        ]
        try AppConfig.save(patch)

        // File exists with 0600 permissions.
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint16Value, 0o600, "config.json must be user-only like upstream")

        // Round-trip through load().
        let reloaded = AppConfig.load(environment: [:])
        XCTAssertEqual(reloaded.profile?.name, "Will")
        XCTAssertEqual(reloaded.rooms?.turnTimeoutMinutes, 12)
        let instances = try XCTUnwrap(reloaded.instances)
        XCTAssertEqual(instances["claude"]?.driver, "claudeAgent")
        XCTAssertEqual(instances["claude"]?.displayName, "Main Claude")
        XCTAssertEqual(instances["custom"]?.environment?["XAI_API_KEY"], "injected")
        XCTAssertEqual(instances["custom"]?.enabled, false)
        XCTAssertEqual(instances["custom"]?.config?["cli"]?.stringValue, "/opt/tools/grok")
        XCTAssertEqual(instances["custom"]?.config?["temperature"]?.doubleValue, 0.4)
    }

    func testSaveMergesSectionsInsteadOfReplacing() throws {
        var first = ConfigPatch()
        first.xai = CredentialPair(key: "xai-first", url: "https://api.example")
        try AppConfig.save(first)

        var second = ConfigPatch()
        second.xai = CredentialPair(key: "xai-second")
        second.box = AppConfig.BoxConfig(token: "box-token")
        try AppConfig.save(second)

        let raw = try String(contentsOfFile: configPath, encoding: .utf8)
        let disk = try XCTUnwrap(AppConfig.parseJSONText(raw))
        XCTAssertEqual(disk["xai"]?["key"]?.stringValue, "xai-second", "newer value wins")
        XCTAssertEqual(disk["xai"]?["url"]?.stringValue, "https://api.example", "untouched field survives")
        XCTAssertEqual(disk["box"]?["token"]?.stringValue, "box-token")

        let cfg = AppConfig.load(environment: [:])
        XCTAssertEqual(cfg.xai?.url, "https://api.example")
        XCTAssertEqual(cfg.box?.token, "box-token")
    }

    func testOpenaiCompatSaveIsOmittedLikeUpstream() throws {
        var patch = ConfigPatch()
        patch.openaiCompat = CredentialPair(key: "sk-or-v1-test")
        try AppConfig.save(patch)
        let raw = try String(contentsOfFile: configPath, encoding: .utf8)
        let disk = try XCTUnwrap(AppConfig.parseJSONText(raw))
        XCTAssertNil(disk["openaiCompat"], "upstream's merge loop omits openaiCompat; mirror it")
    }

    func testEnvFallbackOverridesFileCredentials() throws {
        var patch = ConfigPatch()
        patch.tts = TtsConfig(key: "file-key", voice: "Nova")
        try AppConfig.save(patch)

        let cfg = AppConfig.load(environment: ["OMB_TTS_KEY": "env-key"])
        XCTAssertEqual(cfg.tts?.key, "env-key")
        XCTAssertEqual(cfg.tts?.voice, "Nova", "non-secret file fields survive env fallback")

        let withoutEnv = AppConfig.load(environment: [:])
        XCTAssertEqual(withoutEnv.tts?.key, "file-key")
    }

    func testSyncCredentialEnvDropsEmptyStringAndKeepsValues() {
        var env = ["XAI_API_KEY": "stale"]
        AppConfig.syncCredentialEnv(AppConfig(xai: CredentialPair(key: "")), into: &env)
        XCTAssertNil(env["XAI_API_KEY"], "cleared credential drops the var so file wins again")

        AppConfig.syncCredentialEnv(AppConfig(box: AppConfig.BoxConfig(token: "fresh")), into: &env)
        XCTAssertEqual(env["BOX_TOKEN"], "fresh")
    }

    func testParseStoredConfigRejectsInvalidRoomsRange() {
        XCTAssertThrowsError(try AppConfig.parseStoredConfig(.object([
            "rooms": .object(["turnTimeoutMinutes": .int(9_000)]),
        ])))
        XCTAssertThrowsError(try AppConfig.parseStoredConfig(.object([
            "instances": .object(["bad": .object(["driver": .null])]),
        ])))
        XCTAssertNoThrow(try AppConfig.parseStoredConfig(.object([
            "vps": .object(["sshAlias": "prod-host_1"]),
            "localVm": .object(["mode": "per-bot", "maxInstances": .int(3)]),
        ])))
    }

    func testInstanceConfigsInjectsCredentialEnvPerDriver() {
        let cfg = AppConfig(
            xai: CredentialPair(key: "xai-key"),
            box: AppConfig.BoxConfig(token: "box-token"),
            instances: [
                "grok-api": InstanceConfig(driver: "grok"),
                "computer": InstanceConfig(driver: "boxAgent"),
                "claude": InstanceConfig(driver: "claudeAgent"),
            ]
        )
        let map = AppConfig.instanceConfigs(cfg)
        XCTAssertEqual(map["grok-api"]?.environment?["XAI_API_KEY"], "xai-key", "secret goes only to its driver")
        XCTAssertEqual(map["computer"]?.environment?["BOX_TOKEN"], "box-token")
        XCTAssertNil(map["claude"]?.environment?["XAI_API_KEY"])
        XCTAssertNil(map["claude"]?.environment?["BOX_TOKEN"])
    }

    func testWithInstanceCliSetsClearsAndStripsInjectedSecrets() {
        var cfg = AppConfig(
            box: AppConfig.BoxConfig(token: "box-token"),
            instances: [
                "computer": InstanceConfig(driver: "boxAgent", environment: ["BOX_TOKEN": "box-token"]),
                "other": InstanceConfig(driver: "claudeAgent"),
            ]
        )
        cfg.instances = AppConfig.instanceConfigs(cfg)

        // Unknown instance → not ok.
        let miss = AppConfig.withInstanceCli(cfg, instanceId: "ghost", cli: "/x/y")
        XCTAssertEqual(miss.ok, false)

        // Set an override on the computer instance.
        let set = AppConfig.withInstanceCli(cfg, instanceId: "computer", cli: " /opt/agy/bin/agy ")
        XCTAssertEqual(set.ok, true)
        XCTAssertEqual(set.config.instances?["computer"]?.config?["cli"]?.stringValue, "/opt/agy/bin/agy")
        // The injected secret is stripped back out of the persistable map.
        XCTAssertNil(set.config.instances?["computer"]?.environment?["BOX_TOKEN"])

        // Empty string clears the override.
        let cleared = AppConfig.withInstanceCli(set.config, instanceId: "computer", cli: "")
        XCTAssertEqual(cleared.ok, true)
        XCTAssertNil(cleared.config.instances?["computer"]?.config?["cli"])
    }
}
