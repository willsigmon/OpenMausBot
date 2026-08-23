import Foundation
import XCTest
@testable import HarnessCore

// Shared fake-CLI plumbing for the PortM1 contract suites — the Swift
// rendering of the fake-CLI pattern (CONTRIBUTING.md Tests house rules):
// tiny executable shell scripts written into a per-test temp dir, chmod +x,
// spawned through ProcessRunner/ClaudeDriver like real CLIs. Failure modes
// are toggled by env var; nothing mocks the process substrate itself.
enum PortM1 {
    /// Create a temp dir unique to one test.
    static func makeScratch(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "portm1-\(label)-\(UUID().uuidString.lowercased())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write an executable shell script into `dir` and return its path.
    @discardableResult
    static func installScript(
        _ dir: String,
        name: String,
        body: String
    ) throws -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        let script = "#!/bin/sh\n" + body
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        let result = chmod(path, 0o755)
        XCTAssertEqual(result, 0, "chmod +x failed for \(path)")
        return path
    }

    /// The canonical stream-json lines the happy-path fake emits — mirrors
    /// server/testing/fake-claude-cli.ts playTurn()'s frame order.
    static func emitLine(_ json: String) -> String {
        "printf '%s\\n' '" + json + "'\n"
    }

    static func happyTurnFrames(sessionId: String, model: String) -> [String] {
        [
            #"{"type":"system","subtype":"init","session_id":"\#(sessionId)","model":"\#(model)"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello from "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"fake claude"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello from fake claude"},{"type":"tool_use","id":"tu-1","name":"Bash"}],"usage":{"input_tokens":10,"cache_read_input_tokens":2,"output_tokens":5}}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu-1","is_error":false}]}}"#,
            #"{"type":"result","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_read_input_tokens":2,"output_tokens":5}}"#,
        ]
    }

    /// Event recorder with an event-condition wait (the recordEvents(...).until
    /// discipline: no sleeps — wait on the event that proves the behavior).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RuntimeEvent] = []
        private var continuations: [(RuntimeEvent) -> Bool] = []

        func record(_ event: RuntimeEvent) {
            lock.lock()
            events.append(event)
            let pending = continuations
            continuations = []
            lock.unlock()
            for predicate in pending {
                if predicate(event) { return }
            }
        }

        var all: [RuntimeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        /// Resolve when an event matching `predicate` arrives; also checks
        /// already-recorded history first so late subscribers still pass.
        func until(_ timeout: TimeInterval = 10, _ predicate: @escaping (RuntimeEvent) -> Bool) async throws -> RuntimeEvent {
            if let existing = all.first(where: predicate) { return existing }
            return try await withCheckedThrowingContinuation { continuation in
                let gate = ResumeGate()
                let wrapped: (RuntimeEvent) -> Bool = { event in
                    guard predicate(event) else { return false }
                    if gate.claim() {
                        continuation.resume(returning: event)
                    }
                    return true
                }
                lock.lock()
                // re-check under the same lock that guards appends
                if let existing = events.first(where: predicate) {
                    lock.unlock()
                    _ = wrapped(existing)
                    return
                }
                continuations.append(wrapped)
                lock.unlock()
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .seconds(timeout))
                    if gate.claim() {
                        continuation.resume(throwing: NSError(
                            domain: "PortM1", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for expected event"]
                        ))
                    }
                }
            }
        }
    }

    /// One-shot resume flag safe from any context (NSLock is unavailable in
    /// async contexts, so the claim uses an atomic exchange).
    final class ResumeGate: @unchecked Sendable {
        private let claimed = AtomicFlag()

        /// True exactly once — the first caller wins.
        func claim() -> Bool { claimed.testAndSet() }
    }

    final class AtomicFlag: @unchecked Sendable {
        private var value: Bool = false

        func testAndSet() -> Bool {
            Darwin.os_unfair_lock_lock(&lock)
            defer { Darwin.os_unfair_lock_unlock(&lock) }
            if value { return false }
            value = true
            return true
        }

        private var lock = os_unfair_lock_s()
    }

    /// Pull the JSON object a fake wrote via DUMP_FILE (argv/env/prompt).
    static func readDump(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }
}
