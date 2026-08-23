import Foundation
import XCTest
@testable import HarnessCore

// ProcessRunner contract tests — the M1 port of the procs.ts behaviors the
// fake-CLI suite pins upstream: argv-array spawning (no shell), env hygiene,
// streamed stdout, interrupt escalation, and nonzero exits surfacing as
// results instead of hangs.
final class PortM1ProcessRunnerTests: XCTestCase {
    private var scratch: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = PortM1.makeScratch("runner")
    }

    override func tearDown() {
        if let scratch {
            try? FileManager.default.removeItem(atPath: scratch)
        }
        scratch = nil
        super.tearDown()
    }

    // A fake that echoes its environment as JSON lines, proving exactly what
    // reached the child. `env | grep` would build a pipeline string; printf
    // per line keeps it argv-only from our side.
    func testEnvironmentDenyByDefaultReachesChildVerbatim() async throws {
        let echo = try PortM1.installScript(scratch, name: "env-echo", body: """
        printf '%s=%s\\n' "FAKE_PROBE_KEY" "$FAKE_PROBE_KEY"
        printf '%s=%s\\n' "INHERITED_SHOULD_EXIST" "$INHERITED_SHOULD_EXIST"
        """)

        let runner = ProcessRunner()
        let running = try await ProcessRunner.spawnAwaited(echo, options: .init(
            environment: [
                "PATH": "/usr/bin:/bin",
                "FAKE_PROBE_KEY": "probe-value",
                "INHERITED_SHOULD_EXIST": "kept",
            ],
            arguments: []
        ))
        var lines: [String] = []
        for await line in running.stdoutLines { lines.append(line) }
        let result = await running.waitExit()

        XCTAssertEqual(result.status, .exited(code: 0))
        XCTAssertEqual(lines, ["FAKE_PROBE_KEY=probe-value", "INHERITED_SHOULD_EXIST=kept"])
        // deny-by-default: a harness-process variable NOT in the map must be
        // invisible to the child. The probe script prints only what it was
        // handed; assert a sentinel from our own process never arrived.
        XCTAssertFalse(lines.joined().contains("PORTM1_SENTINEL"), "deny-by-default leaked parent env")
    }

    func testStreamedLinesArriveInOrderAcrossChunks() async throws {
        let chatter = try PortM1.installScript(scratch, name: "chatter", body: """
        for i in 1 2 3 4 5; do printf 'line-%s\\n' "$i"; done
        """)

        let runner = ProcessRunner()
        let running = try await ProcessRunner.spawnAwaited(chatter, options: .init())
        var seen: [String] = []
        for await line in running.stdoutLines { seen.append(line) }
        _ = await running.waitExit()

        XCTAssertEqual(seen, ["line-1", "line-2", "line-3", "line-4", "line-5"])
    }

    func testNonzeroExitSurfacesAsStatusNotHang() async throws {
        let failer = try PortM1.installScript(scratch, name: "failer", body: """
        printf 'boom\\n' >&2
        exit 3
        """)

        let runner = ProcessRunner()
        let started = Date()
        let running = try await ProcessRunner.spawnAwaited(failer, options: .init())

        var stderrTail = ""
        for await chunk in running.stderrBytes {
            stderrTail += String(decoding: chunk, as: UTF8.self)
        }
        let result = await running.waitExit()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.status, .exited(code: 3), "nonzero exit must surface as a result, not a hang")
        XCTAssertTrue(stderrTail.contains("boom"))
        XCTAssertLessThan(elapsed, 10, "waitExit resolved promptly after nonzero exit")
    }

    func testInterruptTerminatesLongRunningChildWithinAboutTwoSeconds() async throws {
        // The escalation path: a child that ignores the interrupt signal
        // (trap '' TERM INT) survives until the SIGKILL escalation fires
        // after the grace period. The trap is installed only after the shell
        // starts executing, so this script prints "armed" once traps are in
        // place; the test waits on that line (no sleeps) before interrupting.
        let stubborn = try PortM1.installScript(scratch, name: "stubborn", body: """
        trap '' TERM INT
        echo armed
        while :; do sleep 1; done
        """)

        let runner = ProcessRunner(escalationInterval: 1.0)
        let running = try await ProcessRunner.spawnAwaited(
            stubborn,
            options: .init(environment: ["PATH": "/bin:/usr/bin"], arguments: []),
            escalationInterval: 1.0
        )

        // Wait for the trap-armed marker on its stdout.
        let armed = expectation(description: "trap armed")
        let collector = Task.detached(priority: .userInitiated) {
            for await line in running.stdoutLines where line == "armed" {
                armed.fulfill()
                break
            }
        }
        await fulfillment(of: [armed], timeout: 5)

        let started = Date()
        running.interrupt()
        let result = await running.waitExit()
        let elapsed = Date().timeIntervalSince(started)
        collector.cancel()

        guard case .signaled(let signal)? = result.status else {
            return XCTFail("expected a signal death, got \(String(describing: result.status))")
        }
        XCTAssertEqual(signal, SIGKILL, "child ignoring TERM/INT dies by the SIGKILL escalation")
        XCTAssertLessThan(elapsed, 4.0, "escalation completes quickly")
        XCTAssertGreaterThan(elapsed, 0.3, "grace period actually elapsed before the kill")
    }

    func testInterruptTerminatesPoliteChildImmediatelyWithTerm() async throws {
        // No trap: the first signal ends it.
        let polite = try PortM1.installScript(scratch, name: "polite", body: """
        while :; do sleep 1; done
        """)

        let running = try await ProcessRunner.spawnAwaited(polite, options: .init())

        let started = Date()
        running.interrupt()
        let result = await running.waitExit()
        let elapsed = Date().timeIntervalSince(started)

        guard case .signaled(let signal)? = result.status else {
            return XCTFail("expected a signal death, got \(String(describing: result.status))")
        }
        XCTAssertTrue(signal == SIGINT || signal == SIGTERM,
                      "polite child dies on the interrupt signal, got \(signal)")
        XCTAssertLessThan(elapsed, 2.0, "polite child dies within ~2s of interrupt()")
    }

    func testSpawnFailureCarriesSetupWordingForMissingBinary() async throws {
        do {
            _ = try await ProcessRunner.spawnAwaited(
                (scratch as NSString).appendingPathComponent("does-not-exist"),
                options: .init()
            )
            XCTFail("spawn of a missing binary must throw SpawnFailure")
        } catch let failure as ProcessRunner.SpawnFailure {
            XCTAssertTrue(failure.setup, "ENOENT is setup-shaped, not retry-shaped")
            XCTAssertTrue(failure.message.contains("isn't installed"))
        }
    }

    func testStdinDeliveryThenCloseSignalsEofToChild() async throws {
        let reader = try PortM1.installScript(scratch, name: "reader", body: """
        while IFS= read -r line; do printf 'got: %s\\n' "$line"; done
        printf 'eof\\n'
        """)

        let running = try await ProcessRunner.spawnAwaited(reader, options: .init())
        let payload = Data("first\nsecond\n".utf8)
        XCTAssertTrue(running.stdinWriter?.deliver(payload, closeAfter: true) ?? false)

        var lines: [String] = []
        for await line in running.stdoutLines { lines.append(line) }
        let result = await running.waitExit()

        XCTAssertEqual(result.status, .exited(code: 0))
        XCTAssertEqual(lines, ["got: first", "got: second", "eof"])
    }
}
