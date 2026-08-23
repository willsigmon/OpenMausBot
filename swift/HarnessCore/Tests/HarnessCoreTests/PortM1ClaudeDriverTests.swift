import Foundation
import XCTest
@testable import HarnessCore

// ClaudeDriver contract tests — the M1 slice of the upstream claude.test.ts
// contract: a scripted fake CLI (shell script, toggled by env) is spawned by
// the driver, and the canonical RuntimeEvent sequence, argv/env hygiene,
// resume-cursor passthrough, interrupts, and failure modes are asserted.
final class PortM1ClaudeDriverTests: XCTestCase {
    private var scratch: String!
    private var fakePath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = PortM1.makeScratch("claude")
        fakePath = try installFake(name: "fake-claude", body: defaultFakeBody())
    }

    override func tearDown() {
        if let scratch {
            try? FileManager.default.removeItem(atPath: scratch)
        }
        scratch = nil
        fakePath = nil
        super.tearDown()
    }

    // MARK: fake CLI

    private func installFake(name: String, body: String) throws -> String {
        try PortM1.installScript(scratch, name: name, body: body)
    }

    /// Shell reimplementation of fake-claude-cli.ts's happy/stream/exit-early/
    /// hang/malformed modes plus the FAKE_CLAUDE_DUMP probe. Reads one stdin
    /// line as the prompt, then plays frames; DUMP_FILE captures argv+env.
    private func defaultFakeBody() -> String {
        """
        MODE="${FAKE_CLAUDE_MODE:-happy}"
        MODEL="claude-fake"
        # The real CLI reports the RESUMED session id in its init frame:
        # --resume wins, then --session-id, then the env default.
        SESSION=""
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--resume" ]; then SESSION="$a"; fi
          if [ "$prev" = "--session-id" ] && [ -z "$SESSION" ]; then SESSION="$a"; fi
          prev="$a"
        done
        SESSION="${SESSION:-${FAKE_CLAUDE_SESSION:-fake-session}}"

        if [ "$FAKE_CLAUDE_DUMP" != "" ]; then
          # argv + env as a flat JSON object. Values here are simple (no
          # quotes/backslashes in the asserted vars), so naive quoting is safe.
          printf '%s' "{\\"argv\\":[" > "$FAKE_CLAUDE_DUMP"
          first=1
          for a in "$@"; do
            [ $first -eq 1 ] && first=0 || printf ',' >> "$FAKE_CLAUDE_DUMP"
            printf '"%s"' "$a" >> "$FAKE_CLAUDE_DUMP"
          done
          printf '],"env":{' >> "$FAKE_CLAUDE_DUMP"
          # Only the vars the test actually asserts on are captured, and only
          # when actually SET in this child's environment — an empty value
          # means the variable was stripped before spawn (deny-by-default).
          # Its presence here would therefore prove a leak.
          efirst=1
          while IFS='=' read -r k v; do
            [ -z "$k" ] && continue
            [ -z "$v" ] && continue
            [ $efirst -eq 1 ] && efirst=0 || printf ',' >> "$FAKE_CLAUDE_DUMP"
            printf '"%s":"%s"' "$k" "$v" >> "$FAKE_CLAUDE_DUMP"
          done <<EOF_PROBE
        NPM_CONFIG_LOGLEVEL=$NPM_CONFIG_LOGLEVEL
        ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
        CLAUDECODE=$CLAUDECODE
        XAI_API_KEY=$XAI_API_KEY
        BOX_TOKEN=$BOX_TOKEN
        EOF_PROBE
          printf '},"prompt":' >> "$FAKE_CLAUDE_DUMP"
          # consume exactly ONE line — the prompt — then keep going with the
          # turn while stdin stays open (the real CLI reads stream-json
          # messages one per line and never blocks on EOF)
          head -n 1 >> "$FAKE_CLAUDE_DUMP"
          printf '}' >> "$FAKE_CLAUDE_DUMP"
        else
          IFS= read -r PROMPT
          :
        fi

        emit() { printf '%s\\n' "$1"; }

        if [ "$MODE" = "exit-early" ]; then
          printf 'fake-claude: simulated crash before result\\n' >&2
          exit 3
        fi

        emit "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$SESSION\\",\\"model\\":\\"$MODEL\\"}"

        if [ "$MODE" = "hang" ]; then
          # never settle; interrupt() must end this. The background sleep
          # detaches its stdio on purpose: an orphaned child holding the
          # stdout/stderr pipes open would keep the driver's drain loops from
          # ever seeing EOF (the exact trap upstream's kill(-pid) avoids by
          # reaping the whole group).
          sleep 300 >/dev/null 2>&1 </dev/null &
          wait $!
          exit 0
        fi

        if [ "$MODE" = "malformed" ]; then
          printf 'this is not json\\n{broken\\n'
        fi

        if [ "$MODE" = "stream" ]; then
          emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}'
          emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello from "}}}'
          emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"fake claude"}}}'
          # subagent narration — the driver must drop this, not render it
          emit '{"type":"stream_event","parent_tool_use_id":"task-1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"SUBAGENT NOISE"}}}'
        fi

        emit '{"type":"assistant","message":{"content":[{"type":"text","text":"hello from fake claude"},{"type":"tool_use","id":"tu-1","name":"Bash"}],"usage":{"input_tokens":10,"cache_read_input_tokens":2,"output_tokens":5}}}'
        emit '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu-1","is_error":false}]}}'
        emit '{"type":"result","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_read_input_tokens":2,"output_tokens":5}}'
        exit 0
        """
    }

    // MARK: helpers

    private func makeInstance(
        config: ClaudeConfig,
        environment: [String: String] = [:]
    ) -> (instance: ClaudeInstance, recorder: PortM1.Recorder) {
        let input = DriverCreateInput(
            instanceId: "claude-m1",
            displayName: "Claude M1",
            environment: environment,
            enabled: true,
            config: .object([
                "cli": .string(fakePath),
                "permissionMode": .string(config.permissionMode.rawValue),
            ])
        )
        let instance = ClaudeInstance(input: input, config: config)
        let recorder = PortM1.Recorder()
        _ = instance.adapter.onEvent { [weak recorder] event in
            recorder?.record(event)
        }
        return (instance, recorder)
    }

    // MARK: config decode

    func testDecodeConfigDefaultsAndThrowsOnInvalidMode() throws {
        XCTAssertEqual(try ClaudeConfig.decode(.object([:])), ClaudeConfig(cli: "claude", permissionMode: .acceptEdits))
        XCTAssertEqual(try ClaudeConfig.decode(nil), ClaudeConfig())
        for mode in ["acceptEdits", "auto", "bypassPermissions"] {
            let decoded = try ClaudeConfig.decode(.object(["permissionMode": .string(mode)]))
            XCTAssertEqual(decoded.permissionMode.rawValue, mode)
        }
        XCTAssertThrowsError(try ClaudeConfig.decode(.object(["permissionMode": .string("yolo")]))) { error in
            XCTAssertTrue("\(error)".contains("yolo"), "invalid mode names itself")
        }
    }

    func testStaticCatalogMatchesUpstreamRows() {
        XCTAssertEqual(ClaudeDriver.staticModels.default, "claude-sonnet-5")
        XCTAssertEqual(
            ClaudeDriver.staticModels.options.map(\.id),
            ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        )
    }

    // MARK: turn normalization

    func testHappyTurnDecodesExactCanonicalEventSequence() async throws {
        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        let result = try await instance.adapter.sendTurn(SendTurnInput(
            threadId: "t-happy", text: "hi", model: "claude-sonnet-5"
        ))
        let done = try await recorder.until { $0.kind.typeKey == "turn.completed" }
        await instance.dispose()

        let types = recorder.all.map(\.kind.typeKey)
        XCTAssertEqual(types, [
            "turn.started",
            "session.started",
            "content.delta",    // fallback delta (happy mode streams nothing)
            "item.completed",   // assistant_text settled exactly once
            "item.started",     // tool tu-1
            "thread.token-usage.updated",
            "item.completed",   // tool result
            "turn.completed",
        ], "full sequence: \(types)")

        for event in recorder.all {
            XCTAssertEqual(event.base.provider, "claudeAgent")
            XCTAssertEqual(event.base.turnId, result.turnId)
        }
        guard case .turnCompleted(let ok, let stopReason, let cost, _, let usage) = done.kind else {
            return XCTFail("last event was not turn.completed")
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(stopReason, "end_turn")
        XCTAssertEqual(cost ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(usage?.input, 12)  // 10 + cache_read 2
        XCTAssertEqual(usage?.output, 5)

        let usageEvent = try XCTUnwrap(recorder.all.first {
            $0.kind.typeKey == "thread.token-usage.updated"
        })
        guard case .threadTokenUsageUpdated(let live) = usageEvent.kind else {
            return XCTFail("usage frame malformed")
        }
        XCTAssertEqual(live.input, 12)
        XCTAssertEqual(live.output, 5)
    }

    func testStreamedDeltasAndSubagentNoise() async throws {
        setenv("FAKE_CLAUDE_MODE", "stream", 1)
        defer { unsetenv("FAKE_CLAUDE_MODE") }

        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        _ = try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-stream", text: "hi"))
        _ = try await recorder.until { $0.kind.typeKey == "turn.completed" }
        await instance.dispose()

        let deltas = recorder.all.filter { $0.kind.typeKey == "content.delta" }
        var textDeltas: [String] = []
        var sawReasoning = false
        for delta in deltas {
            guard let (kind, text) = delta.kind.asContentDelta() else { continue }
            switch kind {
            case .assistantText: textDeltas.append(text)
            case .reasoningText: sawReasoning = text == "hmm"
            }
        }
        XCTAssertEqual(textDeltas, ["hello from ", "fake claude"])
        XCTAssertTrue(sawReasoning, "reasoning streams on its own kind")
        XCTAssertFalse(textDeltas.joined().contains("SUBAGENT"), "subagent narration never surfaces")

        // settled message lands once, with no duplicate full-text fallback
        let completed = recorder.all.filter {
            $0.kind.typeKey == "item.completed" && !$0.kind.isToolCompletion
        }
        XCTAssertEqual(completed.count, 1)
    }

    func testPromptRidesStdinNeverArgvAndEnvIsStripped() async throws {
        let dump = (scratch as NSString).appendingPathComponent("dump.json")
        setenv("FAKE_CLAUDE_DUMP", dump, 1)
        // The harness process may hold these (env-injected at boot); they
        // ride in through the inherited base env exactly as upstream's test
        // sets them on process.env.
        setenv("ANTHROPIC_API_KEY", "sk-should-not-leak", 1)
        setenv("CLAUDECODE", "1", 1)
        setenv("XAI_API_KEY", "xai-should-not-leak", 1)
        setenv("BOX_TOKEN", "box-should-not-leak", 1)
        defer {
            unsetenv("FAKE_CLAUDE_DUMP")
            unsetenv("ANTHROPIC_API_KEY")
            unsetenv("CLAUDECODE")
            unsetenv("XAI_API_KEY")
            unsetenv("BOX_TOKEN")
        }

        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        _ = try await instance.adapter.sendTurn(SendTurnInput(
            threadId: "t-hygiene", text: "the secret prompt", system: "You are Testy."
        ))
        _ = try await recorder.until { $0.kind.typeKey == "turn.completed" }
        await instance.dispose()

        let seen = try PortM1.readDump(dump)

        // The prompt reached the child on STDIN, never argv.
        let argvStrings = (try XCTUnwrap(seen["argv"] as? [Any])).compactMap { $0 as? String }
        XCTAssertFalse(argvStrings.contains("the secret prompt"), "prompt leaked onto argv")
        XCTAssertTrue(argvStrings.contains("--append-system-prompt"))
        XCTAssertTrue(argvStrings.contains("You are Testy."), "system prompt rides argv (it is not secret)")
        XCTAssertTrue(argvStrings.contains("--output-format") && argvStrings.contains("stream-json"))
        XCTAssertTrue(argvStrings.contains("--input-format") && argvStrings.contains("stream-json"))
        XCTAssertTrue(argvStrings.contains("--verbose"))
        XCTAssertTrue(argvStrings.contains("--include-partial-messages"))

        // The dump's "prompt" field IS the stdin line the child consumed.
        if let rawPrompt = seen["prompt"] {
            let promptText = String(describing: rawPrompt)
            XCTAssertTrue(promptText.contains("the secret prompt"), "stdin prompt did not reach the child")
        } else {
            XCTFail("fake did not capture the stdin prompt")
        }

        // Env hygiene: identity + workspace credentials stripped.
        let seenEnv = seen["env"] as? [String: String] ?? [:]
        for forbidden in ["ANTHROPIC_API_KEY", "CLAUDECODE", "XAI_API_KEY", "BOX_TOKEN"] {
            XCTAssertNil(seenEnv[forbidden], "\(forbidden) reached the CLI child")
        }
        XCTAssertEqual(seenEnv["NPM_CONFIG_LOGLEVEL"], "error", "npm noise quieted for the child")
    }

    func testResumeCursorBecomesResumeArgvAndSessionIdAnnounced() async throws {
        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        _ = try await instance.adapter.sendTurn(SendTurnInput(
            threadId: "t-resume",
            text: "again",
            resumeCursor: .string("sess-123")
        ))
        let started = try await recorder.until { $0.kind.typeKey == "session.started" }
        await instance.dispose()

        guard let (sessionId, _) = started.kind.asSessionStarted() else {
            return XCTFail("malformed session.started")
        }
        XCTAssertEqual(sessionId, "sess-123", "the announced id matches the resumed cursor")

        let args = ClaudeDriver.turnArguments(
            config: ClaudeConfig(),
            model: nil, effort: nil, system: nil,
            resumeCursor: "sess-123"
        )
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertFalse(args.contains("--session-id"), "a resumed turn never mints a fresh session id")
    }

    func testFreshTurnMintsSessionIdForLaterResume() {
        let args = ClaudeDriver.turnArguments(
            config: ClaudeConfig(),
            model: "claude-opus-5",
            effort: .xhigh,
            system: nil,
            resumeCursor: nil
        )
        let modelIndex = args.firstIndex(of: "--model").map { args[args.index(after: $0)] }
        XCTAssertEqual(modelIndex, "claude-opus-5")
        let effortIndex = args.firstIndex(of: "--effort").map { args[args.index(after: $0)] }
        XCTAssertEqual(effortIndex, "xhigh")
        let sessionIndex = args.firstIndex(of: "--session-id").map { args[args.index(after: $0)] }
        XCTAssertNotNil(sessionIndex, "fresh turns carry --session-id so the CLI reports a stable id")
    }

    // MARK: failure modes

    func testExitBeforeResultSurfacesRuntimeErrorThenFailedTurn() async throws {
        setenv("FAKE_CLAUDE_MODE", "exit-early", 1)
        defer { unsetenv("FAKE_CLAUDE_MODE") }

        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        _ = try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-crash", text: "go"))
        let done = try await recorder.until { $0.kind.typeKey == "turn.completed" }

        guard case .turnCompleted(let ok, let stopReason, _, _, _) = done.kind else {
            return XCTFail("not a completion")
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(stopReason, "exit_before_result")
        let error = recorder.all.first { $0.kind.typeKey == "runtime.error" }
        XCTAssertNotNil(error, "crash surfaces runtime.error")
        if case .runtimeError(let message, _)? = error?.kind {
            XCTAssertTrue(message.contains("simulated crash"), "stderr tail rides the message")
        } else {
            XCTFail("runtime.error malformed")
        }
    }

    func testMalformedProtocolLinesDoNotLoseTheTurn() async throws {
        setenv("FAKE_CLAUDE_MODE", "malformed", 1)
        defer { unsetenv("FAKE_CLAUDE_MODE") }

        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        _ = try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-noise", text: "go"))
        let done = try await recorder.until { $0.kind.typeKey == "turn.completed" }

        guard case .turnCompleted(let ok, _, _, _, _) = done.kind else {
            return XCTFail("not a completion")
        }
        XCTAssertTrue(ok, "noise is skipped; the result frame still settles the turn")
    }

    func testMissingBinaryIsASpawnShapedFailedTurnNotAHang() async throws {
        let missing = (scratch as NSString).appendingPathComponent("no-such-cli")
        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: missing))

        let started = Date()
        _ = try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-missing", text: "go"))
        let done = try await recorder.until { $0.kind.typeKey == "turn.completed" }
        let elapsed = Date().timeIntervalSince(started)

        guard case .turnCompleted(let ok, let stopReason, _, _, _) = done.kind else {
            return XCTFail("not a completion")
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(stopReason, "spawn_error")
        if case .runtimeError(let message, let setup)? = recorder.all
            .first(where: { $0.kind.typeKey == "runtime.error" })?.kind {
            XCTAssertTrue(setup, "ENOENT is setup-shaped")
            XCTAssertTrue(message.contains(missing) || message.contains("isn't installed"))
        } else {
            XCTFail("missing binary did not produce runtime.error")
        }
        XCTAssertLessThan(elapsed, 10, "failed spawn resolves promptly — never a hang")

        let snapshot = await instance.snapshot()
        XCTAssertEqual(snapshot.state, .unavailable, "snapshot says unavailable for a broken CLI")
        XCTAssertTrue(snapshot.reason?.contains(missing) ?? false)
    }

    // MARK: interrupt

    func testInterruptSettlesAHangingTurnAsFailedWithinAboutTwoSeconds() async throws {
        setenv("FAKE_CLAUDE_MODE", "hang", 1)
        setenv("FAKE_CLAUDE_SESSION", "sess-hang", 1)
        defer { unsetenv("FAKE_CLAUDE_MODE"); unsetenv("FAKE_CLAUDE_SESSION") }

        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath), environment: [:])

        // sendTurn resolves only once the turn settles, so drive it from a
        // detached task and interrupt as soon as the session starts — the
        // same shape the harness uses (send returns; interrupt arrives
        // while the CLI is mid-turn).
        let sendTask = Task.detached(priority: .userInitiated) {
            try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-int", text: "go"))
        }
        _ = try await recorder.until { $0.kind.typeKey == "session.started" }

        let started = Date()
        try await instance.adapter.interruptTurn("t-int", turnId: nil)
        let done = try await recorder.until { $0.kind.typeKey == "turn.completed" }
        let elapsed = Date().timeIntervalSince(started)

        guard case .turnCompleted(let ok, let stopReason, _, _, _) = done.kind else {
            return XCTFail("interrupted turn never settled")
        }
        XCTAssertFalse(ok, "an interrupted turn is a failed turn")
        XCTAssertEqual(stopReason, "exit_before_result")
        XCTAssertLessThan(elapsed, 4.0, "interrupt terminates the hanging child quickly")
        _ = try? await sendTask.value
        await instance.dispose()
    }

    // MARK: busy-thread rule

    func testSecondSendWhileBusyThrowsLikeUpstream() async throws {
        setenv("FAKE_CLAUDE_MODE", "hang", 1)
        defer { unsetenv("FAKE_CLAUDE_MODE") }

        let (instance, recorder) = makeInstance(config: ClaudeConfig(cli: fakePath))

        // sendTurn awaits the whole turn, so run it concurrently and gate
        // the second send on the session having started.
        let firstTask = Task.detached(priority: .userInitiated) {
            try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-busy", text: "one"))
        }
        _ = try await recorder.until { $0.kind.typeKey == "session.started" }

        do {
            _ = try await instance.adapter.sendTurn(SendTurnInput(threadId: "t-busy", text: "two"))
            XCTFail("second concurrent send must throw")
        } catch {
            // expected — upstream: "a turn is already running on this thread"
        }
        XCTAssertTrue(instance.adapter.hasSession("t-busy"))
        try await instance.adapter.interruptTurn("t-busy", turnId: nil)
        _ = try await recorder.until { $0.kind.typeKey == "turn.completed" }
        _ = try? await firstTask.result.get()
        await instance.dispose()
    }
}

extension RuntimeEventKind {
    func asContentDelta() -> (streamKind: StreamKind, delta: String)? {
        if case .contentDelta(let streamKind, let delta) = self { return (streamKind, delta) }
        return nil
    }

    func asSessionStarted() -> (sessionId: String?, model: String?)? {
        if case .sessionStarted(let sessionId, let model) = self { return (sessionId, model) }
        return nil
    }

    var isToolCompletion: Bool {
        if case .itemCompletedTool = self { return true }
        return false
    }
}
