import Foundation
import XCTest
@testable import HarnessCore

final class PortEventBusTests: XCTestCase {
    private var token: DataDirToken?

    override func setUp() {
        super.setUp()
        token = DataDirToken()
        DataDirs.ensureDirs()
    }

    override func tearDown() {
        token?.restore()
        token = nil
        super.tearDown()
    }

    private func makeInstance(
        _ id: String,
        kind: DriverKind,
        adapter: FakeAdapter? = nil
    ) -> FakeInstance {
        FakeInstance(
            instanceId: id,
            driverKind: kind,
            adapter: adapter ?? FakeAdapter(provider: kind)
        )
    }

    func testAttachStampsProviderInstanceIdAndFansIn() async throws {
        let bus = EventBus()
        let alphaAdapter = FakeAdapter(provider: "alpha")
        let betaAdapter = FakeAdapter(provider: "beta")
        let alpha = makeInstance("alpha-1", kind: "alpha", adapter: alphaAdapter)
        let beta = makeInstance("beta-1", kind: "beta", adapter: betaAdapter)
        await bus.attach(instances: [alpha, beta])

        let received = EventSink()
        await bus.subscribe { event in received.append(event) }

        alphaAdapter.emit(RuntimeEvent(provider: "alpha", threadId: "t1", kind: .turnStarted))
        betaAdapter.emit(RuntimeEvent(provider: "beta", threadId: "t1", kind: .turnStarted))
        await bus.flushForTesting()

        let events = await received.all()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.base.providerInstanceId == $0.base.provider + "-1" },
                      "every delivered event is stamped with its instance id")
    }

    func testBusDropsCrossDriverEventsOnTheFloor() async throws {
        let bus = EventBus()
        // A misbehaving (or compromised) adapter emits events claiming to be
        // another driver. The bus must never forward them.
        let rogue = FakeAdapter(provider: "rogue")
        let instance = makeInstance("rogue-1", kind: "rogue", adapter: rogue)
        await bus.attach(instances: [instance])

        let received = EventSink()
        await bus.subscribe { event in received.append(event) }

        rogue.emit(RuntimeEvent(provider: "claudeAgent", threadId: "t1", kind: .contentDelta(streamKind: .assistantText, delta: "hi")))
        rogue.emit(RuntimeEvent(provider: "rogue", threadId: "t1", kind: .contentDelta(streamKind: .assistantText, delta: "ok")))
        await bus.flushForTesting()

        let events = await received.all()
        XCTAssertEqual(events.count, 1, "cross-driver events are dropped, matching-driver ones pass")
        XCTAssertEqual(events.first?.base.provider, "rogue")
    }

    func testFanInOrderingAndUnsubscribe() async throws {
        let bus = EventBus()
        let adapter = FakeAdapter(provider: "solo")
        let instance = makeInstance("solo-1", kind: "solo", adapter: adapter)
        await bus.attach(instances: [instance])

        let sink = OrderedSink()
        let unsubA = await bus.subscribe { event in sink.append("a:\(event.base.eventId)") }
        let b = await bus.subscribe { event in sink.append("b:\(event.base.eventId)") }
        let keepB = UnsubscribeBox()
        keepB.store(b)

        adapter.emit(RuntimeEvent(provider: "solo", threadId: "t1", kind: .turnStarted))
        await bus.flushForTesting()

        // Both listeners saw the same events, in publish order.
        let before = await sink.lines()
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(Set(before.map { String($0.prefix(2)) }), ["a:", "b:"])
        let firstIdA = before.first { $0.hasPrefix("a:") }
        let firstIdB = before.first { $0.hasPrefix("b:") }
        XCTAssertEqual(firstIdA?.dropFirst(2), firstIdB?.dropFirst(2))

        // Unsubscribe A; only B keeps receiving.
        let box = UnsubscribeBox()
        box.store(unsubA)
        box.callStored()
        adapter.emit(
            RuntimeEvent(
                provider: "solo", threadId: "t1",
                kind: .turnCompleted(ok: true, stopReason: nil, cost: nil, denials: [], usage: nil)
            )
        )
        await bus.flushForTesting()

        let after = await sink.lines()
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(after[after.count - 1].hasPrefix("b:"), "unsubscribed listener no longer receives")
    }

    func testTeeWritesRedactedPerThreadNdjson() async throws {
        let bus = EventBus()
        let adapter = FakeAdapter(provider: "tee")
        let instance = makeInstance("tee-1", kind: "tee", adapter: adapter)
        await bus.attach(instances: [instance])
        await bus.subscribe { _ in }

        adapter.emit(RuntimeEvent(
            provider: "tee",
            threadId: "thread-42",
            kind: .runtimeError(
                message: "failed: Bearer sk-ant-api03-0123456789abcdef and BOX_TOKEN=supersecret99",
                setup: true
            )
        ))
        adapter.emit(RuntimeEvent(provider: "tee", threadId: "other-thread", kind: .turnStarted))
        await bus.flushForTesting()

        let path = DataDirs.join(DataDirs.eventsDir, "thread-42.ndjson")
        let lines = try PortTestHelpers.readNdjsonLines(path: path)
        XCTAssertEqual(lines.count, 1)
        let message = try XCTUnwrap(lines.first?["message"] as? String)
        XCTAssertFalse(message.contains("supersecret99"), "secret-shaped content must be masked")
        XCTAssertTrue(message.contains("redacted"), "the mask preserves the shape")
        XCTAssertEqual(lines.first?["type"] as? String, "runtime.error")
        XCTAssertEqual(lines.first?["providerInstanceId"] as? String, "tee-1")

        // Per-thread separation.
        let otherPath = DataDirs.join(DataDirs.eventsDir, "other-thread.ndjson")
        XCTAssertEqual(try PortTestHelpers.readNdjsonLines(path: otherPath).count, 1)
    }

    func testPublishWithoutListenersDoesNotThrow() async throws {
        let bus = EventBus()
        await bus.publish(RuntimeEvent(provider: "x", threadId: "t", kind: .turnStarted))
        await bus.flushForTesting()
        let lines = try PortTestHelpers.readNdjsonLines(
            path: DataDirs.join(DataDirs.eventsDir, "t.ndjson"))
        XCTAssertEqual(lines.count, 1, "the tee runs even with zero subscribers")
    }
}

// Thread-safe sinks for async delivery assertions. Lock-backed on purpose:
// listener invocation is synchronous inside the bus's ordered drain, so by
// the time flushForTesting() resolves, every append below has landed too.

final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []
    func append(_ event: RuntimeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func all() -> [RuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class OrderedSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ line: String) {
        lock.lock()
        values.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Keeps unsubscribe closures alive across await suspension points and lets
/// tests invoke them without escaping-closure friction.
final class UnsubscribeBox: @unchecked Sendable {
    private var stored: [@Sendable () -> Void] = []
    func store(_ unsub: @escaping @Sendable () -> Void) { stored.append(unsub) }
    func callStored() { stored.forEach { $0() } }
}
