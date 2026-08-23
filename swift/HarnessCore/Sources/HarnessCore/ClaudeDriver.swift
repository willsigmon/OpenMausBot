import Foundation

// Claude driver — the Swift port of server/drivers/claude.ts (stage M1
// slice: headless turn runner only). The CLI is spawned per turn with
// `--output-format stream-json --input-format stream-json`, the prompt goes
// over stdin as one stream-json line, and stdout lines decode into canonical
// RuntimeEvents. The conversation continues across turns by passing the
// CLI's session id back in as `resumeCursor` (`--resume <sessionId>`).
//
// EVENT MAPPING COVERAGE vs upstream handleLine() (claude.ts:742-824)
// ────────────────────────────────────────────────────────────────────────
// COVERED (faithful):
//   system/init            → session.started(sessionId, model); session id
//                            captured as this turn's resume cursor.
//   stream_event/
//     content_block_delta  → content.delta; text_delta → assistant_text,
//                            thinking_delta → reasoning_text. Subagent
//                            narration (parent_tool_use_id present) is
//                            dropped exactly like upstream, so parallel
//                            Tasks cannot interleave prose into one bubble.
//   assistant              → fallback content.delta when no streamed delta
//                            was seen for the message, then item.completed
//                            (assistant_text) once; tool_use blocks become
//                            item.started(itemType: tool); usage becomes
//                            thread.token-usage.updated with cache reads
//                            counted as input.
//   user/tool_result       → item.completed(tool, ok: !is_error).
//   result                 → turn.completed(ok: !is_error,
//                            stopReason: stop_reason ?? terminal_reason,
//                            cost: total_cost_usd, usage with input +
//                            cache_read + cache_creation as input).
//
// DEFERRED / APPROXIMATED (documented per the brief):
//   - system/thinking_tokens → upstream emits item.updated(reasoning,
//     tokens). Deferred: it carries an estimated-token count with no
//     matching fixture in the fake-CLI contract suite and no consumer in
//     M1; add when a UI needs the estimate. (Marked TODO below.)
//   - Permission broker      → request.opened/request.resolved ride the
//     per-turn unix socket broker (claude.ts:186-376), which needs
//     Network.framework listener work planned for stage S7. This port
//     runs acceptEdits-shaped turns WITHOUT the broker: no
//     --permission-prompt-tool flag, no mcpServers block, no
//     --allowedTools pre-allow list. Anything acceptEdits would silently
//     deny stays silently denied until S7 lands — fail-closed, never a
//     hang or a crash.
//   - MCP integrations       → composio/computer/localComputer/agents/
//     phone/dweb mounts all flow through the same 0600 mcp.json temp file
//     as upstream. Deferred wholesale WITH the broker (they are mounted to
//     be permission-managed); the argv shape is ready to take them.
//   - Session reuse          → upstream retains one live CLI process per
//     thread across turns and steers into it mid-turn (writeUser on a
//     kept-open stdin). This stage settles the process at every turn end
//     and resumes via --resume next turn: same conversation continuity,
//     different process lifetime. Steer therefore returns false (the
//     ProviderAdapter default) and queueing advertises false.
//   - local-inject model resolution → resolveClaudeTurnModel /
//     applyClaudeInject probe Ollama-class hosts to rewrite leftover API
//     slugs into host::model ids. Needs local-inject.ts's port (S6);
//     here the model id passes through verbatim and ANTHROPIC_API_KEY is
//     always stripped (upstream strips it whenever nothing was injected).
//   - generateText/snapshot auth probes → execCli one-shots exist in
//     ProcessRunner.runCollect but the instance-level snapshot()/version
//     plumbing lands with the registry integration (S3/S4 wiring).

public enum ClaudeDriverError: Error, CustomStringConvertible {
    case invalidPermissionMode(String)

    public var description: String {
        switch self {
        case .invalidPermissionMode(let mode):
            return "claude: invalid permissionMode \(mode)"
        }
    }
}

/// Decoded driver config — the Swift rendering of ClaudeConfig
/// (claude.ts:93-96, decodeConfig at :378-388). Throws on invalid so the
/// registry downgrades the instance to a shadow instead of crashing.
public struct ClaudeConfig: Sendable, Equatable {
    public enum PermissionMode: String, Sendable, Equatable {
        case acceptEdits
        case auto
        case bypassPermissions
    }

    public var cli: String
    public var permissionMode: PermissionMode

    public init(cli: String = "claude", permissionMode: PermissionMode = .acceptEdits) {
        self.cli = cli
        self.permissionMode = permissionMode
    }

    /// Port of decodeConfig: unknown/absent fields default; a wrong
    /// permissionMode throws (never silently coerces).
    public static func decode(_ raw: JSONValue?) throws -> ClaudeConfig {
        guard let raw else { return ClaudeConfig() }
        guard case .object(let object) = raw else {
            // Upstream treats any non-object as an empty config via
            // `(raw ?? {}) as Record`; only a bad ENUM value throws.
            if case .null = raw { return ClaudeConfig() }
            throw ClaudeDriverError.invalidPermissionMode("config must be an object")
        }
        let cli: String
        switch object["cli"] {
        case .string(let value): cli = value
        case .none, .some(.null): cli = "claude"
        case .some:
            cli = "claude"
        }
        let mode: PermissionMode
        switch object["permissionMode"] {
        case .none, .some(.null):
            mode = .acceptEdits
        case .string(let value):
            guard let decoded = PermissionMode(rawValue: value) else {
                throw ClaudeDriverError.invalidPermissionMode(value)
            }
            mode = decoded
        case .some:
            throw ClaudeDriverError.invalidPermissionMode("(non-string)")
        }
        return ClaudeConfig(cli: cli, permissionMode: mode)
    }
}

public enum ClaudeDriver {
    public static let driverKind: DriverKind = "claudeAgent"

    /// Static catalog ported from claude.ts:99-107 (originally upstream
    /// packages/contracts/src/model.ts).
    public static let staticModels = ModelCatalog(
        default: "claude-sonnet-5",
        options: [
            ModelOption(id: "claude-fable-5", label: "Claude Fable 5"),
            ModelOption(id: "claude-opus-5", label: "Claude Opus 5"),
            ModelOption(id: "claude-sonnet-5", label: "Claude Sonnet 5"),
            ModelOption(id: "claude-haiku-4-5", label: "Claude Haiku 4.5"),
        ]
    )

    /// The CLI environment shared by auth probes and real turns
    /// (claude.ts:76-89). Subscription users can be billed pay-as-you-go if
    /// an inherited API key leaks through, and a nested CLI must not inherit
    /// this session's identity — CLAUDECODE/CLAUDE_CODE_ENTRYPOINT go away,
    /// workspace credentials go away, PATH is augmented, and
    /// NPM_CONFIG_LOGLEVEL quiets npm shim noise.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        env["PATH"] = EnvPath.augmentedPath(environment: base)
        env["NPM_CONFIG_LOGLEVEL"] = "error"
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        HarnessEnvironment.stripWorkspaceCredentialEnv(&env)
        // applyClaudeInject lands with local-inject (S6); until then nothing
        // is ever injected, so ANTHROPIC_API_KEY is always removed — the
        // branch upstream takes when applied.injected is false.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }

    /// The argv contract of one headless turn (claude.ts:532-541, 691-692).
    /// Prompt NEVER rides argv (ARG_MAX + ps exposure): stdin carries it.
    public static func turnArguments(
        config: ClaudeConfig,
        model: String?,
        effort: EffortLevel?,
        system: String?,
        resumeCursor: String?
    ) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose", // required by stream-json output
            "--include-partial-messages", // token-level streaming deltas
        ]
        switch config.permissionMode {
        case .auto:
            args += ["--permission-mode", "acceptEdits"]
        case .acceptEdits:
            args += ["--permission-mode", "acceptEdits"]
        case .bypassPermissions:
            args += ["--permission-mode", "bypassPermissions"]
        }
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort {
            args += ["--effort", effort.rawValue]
        }
        if let system, !system.isEmpty {
            args += ["--append-system-prompt", system]
        }
        if let resumeCursor {
            args += ["--resume", resumeCursor]
        } else {
            args += ["--session-id", RuntimeEvent.newId()]
        }
        return args
    }

    /// Extract the resume cursor for a turn: a string cursor passes
    /// through; anything else starts a fresh session (upstream reads
    /// `typeof turn.resumeCursor === "string"`).
    public static func resumeSessionId(of input: SendTurnInput) -> String? {
        input.resumeCursor?.stringValue
    }
}

// ── stream-json decoding ──────────────────────────────────────────────────

/// One decoded stdout line of the claude CLI's stream-json protocol,
/// normalized into RuntimeEvent values. Mirrors upstream handleLine()'s
/// switch statement; see the header comment for coverage notes.
public enum ClaudeStreamDecoder {
    struct Usage: Decodable {
        var input_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation_input_tokens: Int?
        var output_tokens: Int?
    }

    /// Decode one protocol line against the turn context. Returns the
    /// canonical events the line produces (often one; assistant frames emit
    /// several) or an empty array for lines that carry none — unknown types,
    /// non-JSON noise, subagent narration — skipping them must not lose the
    /// turn.
    public static func decode(
        line: String,
        provider: DriverKind,
        threadId: ThreadId,
        turnId: TurnId,
        sessionIdBox: SessionIdBox
    ) -> [RuntimeEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else { return [] }

        func make(_ kind: RuntimeEventKind, itemId: String? = nil, requestId: String? = nil) -> RuntimeEvent {
            var event = RuntimeEvent(provider: provider, threadId: threadId, turnId: turnId, kind: kind)
            event.base.itemId = itemId
            event.base.requestId = requestId
            return event
        }

        func firstText(_ content: JSONValue?) -> String {
            guard let content else { return "" }
            if case .string(let text) = content { return text }
            if case .array(let blocks) = content {
                return blocks.compactMap { block -> String? in
                    guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue else { return nil }
                    return text
                }.joined()
            }
            return ""
        }

        switch object["type"]?.stringValue {
        case "system":
            guard object["subtype"]?.stringValue == "init" else { return [] }
            if let sessionId = object["session_id"]?.stringValue {
                sessionIdBox.sessionId = sessionId
            }
            return [make(.sessionStarted(sessionId: object["session_id"]?.stringValue, model: object["model"]?.stringValue))]

        case "stream_event":
            // Subagent narration drops — parallel Tasks would interleave.
            if object["parent_tool_use_id"] != nil && !(object["parent_tool_use_id"] == .null) { return [] }
            let event = object["event"]
            guard event?["type"]?.stringValue == "content_block_delta" else { return [] }
            let delta = event?["delta"]
            if delta?["type"]?.stringValue == "text_delta", let text = delta?["text"]?.stringValue, !text.isEmpty {
                return [make(.contentDelta(streamKind: .assistantText, delta: text))]
            }
            if delta?["type"]?.stringValue == "thinking_delta", let text = delta?["thinking"]?.stringValue, !text.isEmpty {
                return [make(.contentDelta(streamKind: .reasoningText, delta: text))]
            }
            return []

        case "assistant":
            let message = object["message"]
            let text = firstText(message?["content"])
            var events: [RuntimeEvent] = []
            // Fallback delta for paths that never streamed the block.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sessionIdBox.sawStreamDelta {
                events.append(make(.contentDelta(streamKind: .assistantText, delta: text)))
            }
            sessionIdBox.sawStreamDelta = false
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(make(.itemCompletedAssistantText(text: text)))
            }
            if case .array(let blocks)? = message?["content"] {
                for block in blocks where block["type"]?.stringValue == "tool_use" {
                    events.append(make(
                        .itemStarted(itemKind: .tool, title: block["name"]?.stringValue),
                        itemId: block["id"]?.stringValue
                    ))
                }
            }
            if let usage = message?["usage"], let parsed = try? JSONDecoder().decode(Usage.self, from: JSONEncoder().encode(usage)) {
                let input = (parsed.input_tokens ?? 0) + (parsed.cache_read_input_tokens ?? 0)
                events.append(make(.threadTokenUsageUpdated(usage: TokenUsage(input: input, output: parsed.output_tokens ?? 0))))
            }
            return events

        case "user":
            guard case .array(let blocks)? = object["message"]?["content"] else { return [] }
            var events: [RuntimeEvent] = []
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                events.append(make(
                    .itemCompletedTool(ok: block["is_error"]?.boolValue != true),
                    itemId: block["tool_use_id"]?.stringValue
                ))
            }
            return events

        case "result":
            // usage is this invocation's total; cache reads count as input
            // because they are billed and they fill the window.
            var usage: TokenUsage? = nil
            if let rawUsage = object["usage"],
               let parsed = try? JSONDecoder().decode(Usage.self, from: JSONEncoder().encode(rawUsage)) {
                let input = (parsed.input_tokens ?? 0)
                    + (parsed.cache_read_input_tokens ?? 0)
                    + (parsed.cache_creation_input_tokens ?? 0)
                usage = TokenUsage(input: input, output: parsed.output_tokens ?? 0)
            }
            let stopReason = object["stop_reason"]?.stringValue ?? object["terminal_reason"]?.stringValue
            return [make(.turnCompleted(
                ok: object["is_error"]?.boolValue != true,
                stopReason: stopReason,
                cost: object["total_cost_usd"]?.doubleValue,
                denials: [],
                usage: usage
            ))]

        default:
            // TODO(M1 follow-up): system/subtype=thinking_tokens maps to
            // item.updated(reasoning, tokens) upstream — deferred, see the
            // header note. Everything else unknown is skipped like upstream.
            return []
        }
    }

    /// True when a raw protocol line is a text_delta stream event — used by
    /// the turn runner to flip the sawStreamDelta fallback gate before
    /// decoding (upstream tracks it inside handleLine).
    static func isTextDelta(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else { return false }
        guard object["type"]?.stringValue == "stream_event",
              object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] == .null,
              object["event"]?["type"]?.stringValue == "content_block_delta"
        else { return false }
        return object["event"]?["delta"]?["type"]?.stringValue == "text_delta"
    }
}

/// Per-turn scratch the decoder mutates: the CLI-announced session id (the
/// next turn's resume cursor), whether the current assistant message already
/// streamed deltas, and whether a settling `result` frame was seen.
public final class SessionIdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionId: String?
    private var _sawStreamDelta = false
    private var _sawTurnCompleted = false

    public init() {}

    var sessionId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _sessionId }
        set { lock.lock(); defer { lock.unlock() }; _sessionId = newValue }
    }

    var sawStreamDelta: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sawStreamDelta }
        set { lock.lock(); defer { lock.unlock() }; _sawStreamDelta = newValue }
    }

    /// Set when the decoder produces a turnCompleted event — the mark of a
    /// turn settled by the protocol rather than by process exit.
    var sawTurnCompleted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sawTurnCompleted }
        set { lock.lock(); defer { lock.unlock() }; _sawTurnCompleted = newValue }
    }

    public var currentSessionId: String? { sessionId }
}

// MARK: - turn runner

extension ClaudeDriver {
    /// Run one headless turn against the claude CLI: spawn, prompt over
    /// stdin, decode stdout into RuntimeEvents delivered to `emit`, settle
    /// from `result` (or surface a crash/spawn failure as runtime.error +
    /// failed turn — never a hang).
    ///
    /// Returns the turn's resume cursor once settled: the session id the CLI
    /// announced in `init`, falling back to the caller-provided cursor.
    public static func runTurn(
        config: ClaudeConfig,
        input: SendTurnInput,
        turnId: TurnId,
        baseEnvironment: [String: String],
        runner: ProcessRunner,
        emit: @escaping @Sendable (RuntimeEvent) -> Void,
        registerInterrupt: (@escaping @Sendable () -> Void) -> Void = { _ in }
    ) async -> String? {
        let threadId = input.threadId
        let resumeCursor = resumeSessionId(of: input)
        let args = turnArguments(
            config: config,
            model: input.model,
            effort: input.effort,
            system: input.system,
            resumeCursor: resumeCursor
        )

        do {
            let running = try await ProcessRunner.spawnAwaited(
                config.cli,
                options: .init(cwd: input.cwd, environment: baseEnvironment, arguments: args)
            )
            registerInterrupt(running.interrupt)

            emit(RuntimeEvent(provider: driverKind, threadId: threadId, turnId: turnId, kind: .turnStarted))

            let box = SessionIdBox()
            box.sessionId = resumeCursor
            let decoderLine: @Sendable (String) -> Void = { line in
                for event in ClaudeStreamDecoder.decode(
                    line: line,
                    provider: driverKind,
                    threadId: threadId,
                    turnId: turnId,
                    sessionIdBox: box
                ) {
                    if case .turnCompleted = event.kind { box.sawTurnCompleted = true }
                    emit(event)
                }
            }

            // Track streamed-delta state around assistant messages: the
            // decoder consults the box, so flip it on text deltas here.
            let lineTask = Task.detached(priority: .userInitiated) {
                for await line in running.stdoutLines {
                    if ClaudeStreamDecoder.isTextDelta(line) { box.sawStreamDelta = true }
                    decoderLine(line)
                }
            }

            let stderrTailTask = Task.detached(priority: .utility) {
                var tail = ""
                for await chunk in running.stderrBytes {
                    tail += String(decoding: chunk, as: UTF8.self)
                    if tail.count > 8192 { tail = String(tail.suffix(8192)) }
                }
                return tail
            }

            // Prompt over stdin as ONE stream-json message — never argv.
            let prompt: JSONValue = .object([
                "type": .string("user"),
                "message": .object([
                    "role": .string("user"),
                    "content": .string(input.text),
                ]),
            ])
            let promptData = try JSONEncoder().encode(prompt) + Data("\n".utf8)
            let wrote = running.stdinWriter?.deliver(promptData) ?? false
            if !wrote {
                running.interrupt()
                emit(runtimeError(threadId, turnId, "claude session stdin is not writable"))
                emit(failedCompletion(threadId, turnId, stopReason: "stdin_write_failed"))
                return box.currentSessionId
            }

            let result = await running.waitExit()
            lineTask.cancel()
            let stderrTail = await stderrTailTask.value

            // The `result` frame already emitted turn.completed on success.
            // A process that exits (nonzero OR clean) before a result frame
            // arrived is a failed turn — surface runtime.error + failed
            // completion, never a hang. A spawn failure is the setup-shaped
            // wording from describeSpawnFailure.
            let sawResult = box.sawTurnCompleted
            if result.spawnFailure == nil && !sawResult {
                emit(runtimeError(
                    threadId,
                    turnId,
                    "claude exited \(result.status?.descriptionText ?? "?") before result\(stderrTail.isEmpty ? "" : ": \(tailOf(stderrTail))")"
                ))
                emit(failedCompletion(threadId, turnId, stopReason: "exit_before_result"))
            }
            return box.currentSessionId ?? resumeCursor
        } catch let failure as ProcessRunner.SpawnFailure {
            emit(runtimeError(threadId, turnId, failure.message, setup: failure.setup))
            emit(failedCompletion(threadId, turnId, stopReason: "spawn_error"))
            return nil
        } catch {
            emit(runtimeError(threadId, turnId, "\(error)"))
            emit(failedCompletion(threadId, turnId, stopReason: "spawn_error"))
            return nil
        }
    }

    // ── event shorthands ────────────────────────────────────────────────

    private static func runtimeError(
        _ threadId: ThreadId, _ turnId: TurnId, _ message: String, setup: Bool = false
    ) -> RuntimeEvent {
        RuntimeEvent(provider: driverKind, threadId: threadId, turnId: turnId, kind: .runtimeError(message: message, setup: setup))
    }

    private static func failedCompletion(_ threadId: ThreadId, _ turnId: TurnId, stopReason: String) -> RuntimeEvent {
        RuntimeEvent(provider: driverKind, threadId: threadId, turnId: turnId, kind: .turnCompleted(ok: false, stopReason: stopReason, cost: nil, denials: [], usage: nil))
    }

    private static func completed(_ threadId: ThreadId, _ turnId: TurnId, ok: Bool, stopReason: String?) -> RuntimeEvent {
        RuntimeEvent(provider: driverKind, threadId: threadId, turnId: turnId, kind: .turnCompleted(ok: ok, stopReason: stopReason, cost: nil, denials: [], usage: nil))
    }

    private static func tailOf(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
    }
}

// ── adapter shell ─────────────────────────────────────────────────────────

/// One live claude instance. Sessions-per-turn: every sendTurn spawns its own
/// CLI process and settles it; the resumeCursor hands the conversation to the
/// next turn's --resume. (Upstream additionally retains idle processes and
/// steers into them — deferred, see the header.)
public final class ClaudeInstance: ProviderInstance, @unchecked Sendable {
    public let instanceId: InstanceId
    public let driverKind: DriverKind = ClaudeDriver.driverKind
    public let displayName: String?
    public let enabled: Bool
    public var models: ModelCatalog { ClaudeDriver.staticModels }
    public let adapter: any ProviderAdapter

    private let config: ClaudeConfig
    private let baseEnvironment: [String: String]
    private let runner: ProcessRunner

    public init(
        input: DriverCreateInput,
        config: ClaudeConfig,
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.instanceId = input.instanceId
        self.displayName = input.displayName
        self.enabled = input.enabled
        self.config = config
        self.baseEnvironment = ClaudeDriver.environment(extra: input.environment)
        self.runner = runner
        // Two-phase: the adapter needs a back-reference, so it is created
        // first with a mutable link that this init closes over completion.
        let linker = InstanceLinker()
        self.adapter = ClaudeAdapter(link: linker)
        linker.instance = self
    }

    func runTurn(
        _ input: SendTurnInput,
        turnId: TurnId,
        emit: @escaping @Sendable (RuntimeEvent) -> Void,
        registerInterrupt: (@escaping @Sendable () -> Void) -> Void = { _ in }
    ) async -> String? {
        await ClaudeDriver.runTurn(
            config: config,
            input: input,
            turnId: turnId,
            baseEnvironment: baseEnvironment,
            runner: runner,
            emit: emit,
            registerInterrupt: registerInterrupt
        )
    }

    public func refreshModels() async {}

    public func snapshot() async -> ProviderSnapshot {
        // Version probe through the same environment hygiene as real turns
        // (claude.ts:895-908). A missing/broken CLI is unavailable-with-reason,
        // never a crash.
        let result = await runner.runCollect(
            config.cli,
            options: .init(environment: baseEnvironment, arguments: ["--version"]),
            timeout: 8
        )
        guard result.spawnFailure == nil, result.isSuccessful else {
            return ProviderSnapshot(state: .unavailable, reason: "`\(config.cli)` CLI not found")
        }
        let version = String(decoding: result.stdoutTail ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderSnapshot(state: .available, version: version.isEmpty ? nil : version, billing: .subscription)
    }

    public func generateText(_ prompt: String) async throws -> String? {
        // execCli shape (claude.ts:955-963): one-shot -p with text output.
        let result = await runner.runCollect(
            config.cli,
            options: .init(
                environment: baseEnvironment,
                arguments: ["-p", prompt, "--model", "claude-haiku-4-5", "--output-format", "text"]
            ),
            timeout: 60
        )
        guard result.spawnFailure == nil, result.isSuccessful else { return nil }
        let text = String(decoding: result.stdoutTail ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func dispose() async {}
}

    /// Two-phase init helper: the adapter is constructed before the instance
    /// finishes initializing, so it consults this link lazily (at first use)
    /// rather than copying a not-yet-set reference. Strong on purpose — the
    /// instance↔adapter pair shares one lifetime, mirroring upstream's
    /// closures over the instance scope.
    final class InstanceLinker: @unchecked Sendable {
        private let lock = NSLock()
        private var _instance: ClaudeInstance?

        var instance: ClaudeInstance? {
            get { lock.lock(); defer { lock.unlock() }; return _instance }
            set { lock.lock(); defer { lock.unlock() }; _instance = newValue }
        }
    }

/// Adapter surface for the M1 slice: send/interrupt/stopAll work; steer and
/// request answering stay unimplemented until session retention (S4) and the
/// broker (S7) land.
final class ClaudeAdapter: ProviderAdapter, @unchecked Sendable {
    let provider: DriverKind = ClaudeDriver.driverKind
    let capabilities = AdapterCapabilities(
        sessionModelSwitch: .inSession,
        agentsMcp: false,
        computerMcp: false,
        composioMcp: false,
        phoneMcp: false,
        images: true,
        effortLevels: [.low, .medium, .high, .xhigh, .max],
        queueing: false,
        localComputerMcp: false
    )

    private let instanceLink: InstanceLinker
    private let lock = NSLock()
    private var listeners: [(UUID, RuntimeEventListener)] = []
    /// The live child per thread, so interruptTurn can SIGTERM it mid-turn
    /// (upstream's active.get(threadId).stop → killCliTree).
    private var activeInterrupts: [ThreadId: @Sendable () -> Void] = [:]

    init(link: InstanceLinker) {
        self.instanceLink = link
    }

    private var instance: ClaudeInstance? { instanceLink.instance }

    func sendTurn(_ input: SendTurnInput) async throws -> TurnStartResult {
        guard let instance else {
            throw ProviderError(code: .upstreamOutage, message: "instance disposed")
        }
        // One turn at a time per thread — a second send while busy is a
        // caller bug, exactly as upstream throws in sendTurn.
        if boxHasInterrupt(input.threadId) {
            throw ProviderError(code: .upstreamOutage, message: "a turn is already running on this thread")
        }

        let turnId = RuntimeEvent.newId()

        let listener: @Sendable (RuntimeEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            let current = self.listeners.map(\.1)
            self.lock.unlock()
            for sink in current { sink(event) }
        }

        // runTurn hands back its process handle once spawned; the adapter
        // registers the interrupt closure for the duration of the await.
        let registration: @Sendable (@escaping @Sendable () -> Void) -> Void = { [weak self] stop in
            guard let self else { return }
            self.registerInterrupt(stop, threadId: input.threadId)
        }

        markTurnStarted(threadId: input.threadId, turnId: turnId)

        let cursor = await instance.runTurn(
            input,
            turnId: turnId,
            emit: listener,
            registerInterrupt: registration
        )

        finishTurn(threadId: input.threadId, cursor: cursor)

        return TurnStartResult(turnId: turnId)
    }

    private func registerInterrupt(_ stop: @escaping @Sendable () -> Void, threadId: ThreadId) {
        lock.lock()
        activeInterrupts[threadId] = stop
        lock.unlock()
    }

    private func markTurnStarted(threadId: ThreadId, turnId: TurnId) {
        lock.lock()
        activeTurnIds[threadId] = turnId
        lock.unlock()
    }

    private func finishTurn(threadId: ThreadId, cursor: String?) {
        lock.lock()
        activeInterrupts.removeValue(forKey: threadId)
        activeTurnIds.removeValue(forKey: threadId)
        lastCursors[threadId] = cursor
        lock.unlock()
    }

    private func boxHasInterrupt(_ threadId: ThreadId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeInterrupts[threadId] != nil
    }

    private var lastCursors: [ThreadId: String?] = [:]
    private var activeTurnIds: [ThreadId: TurnId] = [:]

    func interruptTurn(_ threadId: ThreadId, turnId: TurnId?) async throws {
        stop(for: threadId)()
    }

    func respondToRequest(
        _ threadId: ThreadId,
        requestId: String,
        decision: RequestDecision
    ) async -> RequestOutcome {
        // No broker in M1: there is never an answerable ask — typed
        // unavailable, the fail-closed default.
        .unavailable
    }

    func hasSession(_ threadId: ThreadId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeTurnIds[threadId] != nil
    }

    func stopAll() async {
        for stop in takeAllStops() { stop() }
    }

    private func stop(for threadId: ThreadId) -> (@Sendable () -> Void) {
        lock.lock()
        let found = activeInterrupts[threadId]
        lock.unlock()
        return found ?? {}
    }

    private func takeAllStops() -> [@Sendable () -> Void] {
        lock.lock()
        let stops = Array(activeInterrupts.values)
        activeInterrupts.removeAll()
        lock.unlock()
        return stops
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
}

/// Hands the interrupt closure from runTurn to the adapter without a data
/// race across the actor hop.
final class TurnProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func register(_ stop: @escaping @Sendable () -> Void) {
        lock.lock()
        handler = stop
        lock.unlock()
    }
}

// TurnProcessBox is retained for future in-process steering (S4); the adapter
// currently registers interrupts directly.
