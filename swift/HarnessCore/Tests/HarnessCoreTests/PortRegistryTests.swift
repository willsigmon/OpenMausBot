import Foundation
import XCTest
@testable import HarnessCore

final class PortRegistryTests: XCTestCase {
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

    func testHappyPathCreatesLiveInstances() async throws {
        let driver = FakeDriver(driverKind: "fakeAgent")
        let registry = ProviderRegistry(drivers: [driver])
        await registry.load(configs: [
            "one": InstanceConfig(driver: "fakeAgent", displayName: "One"),
            "two": InstanceConfig(driver: "fakeAgent", enabled: false),
        ])

        let live = await registry.instances()
        XCTAssertEqual(live.count, 2)
        let one = await registry.get("one")
        let unwrappedOne = try XCTUnwrap(one)
        XCTAssertEqual(unwrappedOne.instanceId, "one")
        XCTAssertEqual(unwrappedOne.driverKind, "fakeAgent")
        XCTAssertEqual(unwrappedOne.displayName, "One")
        let two = await registry.get("two")
        XCTAssertEqual(try XCTUnwrap(two).enabled, false)
        let ghost = await registry.get("ghost")
        XCTAssertNil(ghost)
        XCTAssertTrue(live.allSatisfy { $0.adapter.provider == "fakeAgent" })
    }

    func testUnknownDriverBecomesShadowSnapshot() async throws {
        let driver = FakeDriver(driverKind: "fakeAgent")
        let registry = ProviderRegistry(drivers: [driver])
        await registry.load(configs: [
            "kept": InstanceConfig(
                driver: "timeMachineAgent",
                displayName: "From The Future",
                config: .object(["ok": true, "cli": "/future/cli"])
            ),
            "live": InstanceConfig(driver: "fakeAgent"),
        ])

        // The unknown config must not fail the fleet, and the known one
        // must still be live.
        let live = await registry.instances()
        XCTAssertEqual(live.map(\.instanceId), ["live"])

        let shadows = await registry.shadowInstances()
        let shadow = try XCTUnwrap(shadows.first)
        XCTAssertEqual(shadow.instanceId, "kept")
        XCTAssertEqual(shadow.driverKind, "timeMachineAgent")
        XCTAssertEqual(shadow.displayName, "From The Future")
        XCTAssertEqual(shadow.cli, "/future/cli", "raw cli is echoed back without decoding")
        XCTAssertTrue(shadow.reason.contains("unknown driver"), "reason names the missing driver kind")

        let rows = await registry.describe()
        let keptRow = try XCTUnwrap(rows.first { $0.instanceId == "kept" })
        XCTAssertEqual(keptRow.snapshot.state, .unavailable)
        XCTAssertEqual(keptRow.snapshot.reason, shadow.reason)
        XCTAssertEqual(keptRow.models.default, "", "shadow has no model catalog")
        XCTAssertEqual(keptRow.access, .subscription, "unknown driver defaults to subscription access")
        XCTAssertNil(keptRow.install, "an unknown driver has no install path")
    }

    func testDecodeFailureBecomesShadowWithReason() async throws {
        let registry = ProviderRegistry(drivers: [FakeDriver(driverKind: "fakeAgent")])
        await registry.load(configs: [
            "broken": InstanceConfig(driver: "fakeAgent", config: .object(["ok": false])),
        ])

        let shadows = await registry.shadowInstances()
        XCTAssertEqual(shadows.count, 1)
        let shadow = try XCTUnwrap(shadows.first)
        XCTAssertEqual(shadow.instanceId, "broken")
        XCTAssertEqual(shadow.driverKind, "fakeAgent")
        XCTAssertTrue(shadow.reason.contains("config.ok must be true"))

        let rows = await registry.describe()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].snapshot.state, .unavailable)
    }

    func testCreateFailureBecomesShadowToo() async throws {
        let registry = ProviderRegistry(drivers: [FakeDriver(driverKind: "fakeAgent")])
        await registry.load(configs: [
            "spawnless": InstanceConfig(
                driver: "fakeAgent",
                environment: ["fail": "1"]
            ),
        ])
        let shadows = await registry.shadowInstances()
        XCTAssertEqual(shadows.count, 1)
        XCTAssertTrue(try XCTUnwrap(shadows.first).reason.contains("spawn failed"))
    }

    func testDisposeAllTearsDownAndClears() async throws {
        let registry = ProviderRegistry(drivers: [FakeDriver(driverKind: "fakeAgent")])
        await registry.load(configs: [
            "a": InstanceConfig(driver: "fakeAgent"),
            "b": InstanceConfig(driver: "fakeAgent"),
            "c": InstanceConfig(driver: "mystery"),
        ])
        let instances = await registry.instances()
        XCTAssertEqual(instances.count, 2)

        await registry.disposeAll()
        let after = await registry.instances()
        XCTAssertTrue(after.isEmpty)
        let entries = await registry.entries()
        XCTAssertTrue(entries.isEmpty)

        for instance in instances {
            let fake = try XCTUnwrap(instance as? FakeInstance)
            let adapter = try XCTUnwrap(fake.adapter as? FakeAdapter)
            XCTAssertTrue(adapter.disposed)
        }
    }

    func testDescribeReportsCliOverrideAndDefaultsForLiveInstances() async throws {
        EnvPath.resetPathCacheForTests()
        let registry = ProviderRegistry(drivers: [FakeDriver(driverKind: "fakeAgent")])
        await registry.load(configs: [
            "overridden": InstanceConfig(
                driver: "fakeAgent",
                config: FakeDriver.validConfig(cli: "/usr/bin/true")
            ),
            "stock": InstanceConfig(driver: "fakeAgent"),
        ])
        let rows = await registry.describe()
        XCTAssertEqual(rows.count, 2)
        let overridden = try XCTUnwrap(rows.first { $0.instanceId == "overridden" })
        let stock = try XCTUnwrap(rows.first { $0.instanceId == "stock" })
        XCTAssertEqual(overridden.cli, "/usr/bin/true", "override detection reads the raw config")
        XCTAssertNil(stock.cli, "no override means no reported cli")
        for row in [overridden, stock] {
            XCTAssertEqual(row.cliDefault, "fake-cli", "placeholder comes from defaultConfig()")
            XCTAssertEqual(row.snapshot.state, .available)
        }
    }
}
