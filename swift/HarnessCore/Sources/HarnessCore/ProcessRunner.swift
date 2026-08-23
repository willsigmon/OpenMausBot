import Darwin
import Foundation

// Process spawn substrate — the Swift port of server/procs.ts.
//
// Every provider CLI runs as a headless child with piped stdio, spawned by
// ARGV ARRAY ONLY. Upstream's hard rule ("never build command strings for a
// shell", CONTRIBUTING.md platform rules) carries over: there is no shell
// anywhere in this file, no string interpolation into a command line — model
// names, personas, and JSON travel as separate argv elements.
//
// DIVERGENCE from upstream (documented per the port plan §3.1): Node spawns
// `detached: true` so the child leads its own process group, letting
// killCliTree() reap the whole subtree with kill(-pid). Foundation.Process
// exposes neither setsid nor a process-group hook, so group teardown is
// approximated here:
//
//   1. interrupt() sends SIGTERM to just the child (Process.interrupt).
//   2. If it has not exited after `escalationInterval`, SIGKILL follows.
//   3. Orphaned grandchildren (MCP proxies the CLI spawned) are best-effort:
//      they usually exit on their own when stdin closes or the parent dies,
//      but nothing here can guarantee their reaping. The real process-group
//      kill needs the posix_spawn-attribute path planned for stage S1.
//
// The other upstream behaviors are reproduced faithfully:
//   - env hygiene is deny-by-default vs inherit per SpawnOptions;
//   - stdout/stderr are surfaced as line/byte AsyncStreams that never block
//     the child (pipes are drained eagerly in background tasks);
//   - stdin writes swallow EPIPE-style failures instead of crashing the
//     harness (procs.ts:39-51) — writeFailure records them for drivers,
//     which settle the turn from `close` either way;
//   - spawn failures translate through describeSpawnFailure into setup-vs-
//     retry wording, because ENOENT is the most common user-facing error.
public actor ProcessRunner {
    // ── options ───────────────────────────────────────────────────────────

    public struct Options: Sendable {
        /// Working directory; nil inherits the harness process's.
        public var cwd: String?
        /// nil → inherit this process's environment verbatim; non-nil →
        /// DENY-BY-DEFAULT: the child sees exactly this map and nothing else.
        public var environment: [String: String]?
        /// Arguments passed after the executable, one element per argv slot.
        public var arguments: [String]

        public init(cwd: String? = nil, environment: [String: String]? = nil, arguments: [String] = []) {
            self.cwd = cwd
            self.environment = environment
            self.arguments = arguments
        }
    }

    // ── results ───────────────────────────────────────────────────────────

    public enum ExitStatus: Sendable, Equatable {
        case exited(code: Int32)
        case signaled(signal: Int32)

        public var isSuccessful: Bool {
            switch self {
            case .exited(let code): return code == 0
            case .signaled: return false
            }
        }

        /// Upstream reports `code` on clean exits and `signal` on kills;
        /// keep the same two-shape story for driver messages like
        /// "claude exited 3 before result".
        public var descriptionText: String {
            switch self {
            case .exited(let code): return "\(code)"
            case .signaled(let signal): return "signal \(signal)"
            }
        }
    }

    public struct SpawnFailure: Error, Sendable, CustomStringConvertible {
        public var message: String
        /// True when the user fixes this by installing/configuring something,
        /// not by retrying — mirrors procs.ts describeSpawnFailure's flag.
        public var setup: Bool

        public init(message: String, setup: Bool) {
            self.message = message
            self.setup = setup
        }

        public var description: String { message }
    }

    /// One settled run: everything a driver needs to decide ok/not-ok.
    public struct RunResult: Sendable {
        public var status: ExitStatus?
        /// Set only when spawning itself failed (ENOENT/EACCES family) —
        /// never for a child that merely exited nonzero.
        public var spawnFailure: SpawnFailure?
        public var stderrTail: String
        /// Trailing stdout (capped), for execCli-style one-shots whose
        /// payload is small enough to hold whole.
        public var stdoutTail: Data?

        init(
            status: ExitStatus?,
            spawnFailure: SpawnFailure?,
            stderrTail: String,
            stdoutTail: Data? = nil
        ) {
            self.status = status
            self.spawnFailure = spawnFailure
            self.stderrTail = stderrTail
            self.stdoutTail = stdoutTail
        }

        public var isSuccessful: Bool { spawnFailure == nil && status?.isSuccessful == true }
    }

    /// A live child: streams plus the async handles drivers wait on.
    public struct RunningProcess: Sendable {
        public let pid: pid_t?
        public let stdoutLines: AsyncStream<String>
        public let stderrBytes: AsyncStream<Data>
        /// Resolves once the child has exited (or its spawn failed); carries
        /// the captured stderr tail for messages like upstream's
        /// "claude exited N before result: <stderr>".
        public let waitExit: @Sendable () async -> RunResult
        /// Ask the child to terminate: SIGTERM now, SIGKILL after the
        /// runner's escalation interval if it ignores the request.
        public let interrupt: @Sendable () -> Void

        public var stdoutBytes: AsyncStream<Data> { stdoutByteStream }

        let stdoutByteStream: AsyncStream<Data>
        /// Write-then-close handle for the child's stdin. Nil only if the
        /// platform refused the pipe (never on Darwin in practice).
        public let stdinWriter: StdinWriter?
    }

    // ── state ─────────────────────────────────────────────────────────────

    /// Grace period before a SIGTERM'd child gets SIGKILL. Upstream gives
    /// stdin EOF five seconds before insisting (claude.ts closeSession);
    /// interrupts get the same courtesy window.
    private let escalationInterval: TimeInterval

    public init(escalationInterval: TimeInterval = 5.0) {
        self.escalationInterval = escalationInterval
    }

    // MARK: spawn + collect

    /// Spawn the executable and immediately begin draining both pipes so a
    /// chatty child can never fill them and stall (the fake-CLI contract
    /// depends on output arriving even while nobody consumes it yet).
    ///
    /// Never throws: a failed spawn resolves `waitExit` with a RunResult
    /// carrying `spawnFailure` (a failed spawn is a failed turn, not a hang
    /// or a crash).
    ///
    /// Actor-isolated entry point; `spawnAwaited` is the nonisolated form
    /// drivers call from arbitrary tasks.
    public func spawn(_ executablePath: String, options: Options) throws -> RunningProcess {
        try Self.spawnSynced(executablePath, options: options)
    }

    public nonisolated static func spawnAwaited(
        _ executablePath: String,
        options: Options,
        escalationInterval: TimeInterval = 5.0
    ) async throws -> RunningProcess {
        // spawnSync touches only Foundation.Process + Pipe, so hopping to
        // the actor adds nothing; run it directly.
        do {
            let process = try makeProcess(executablePath, options: options)
            return try start(process, escalationInterval: escalationInterval)
        } catch {
            throw error
        }
    }

    /// Synchronous spawn usable from the actor's isolated methods.
    private nonisolated static func spawnSynced(_ executablePath: String, options: Options) throws -> RunningProcess {
        do {
            let process = try makeProcess(executablePath, options: options)
            return try start(process, escalationInterval: 5.0)
        } catch {
            throw error
        }
    }

    /// Spawn and await full termination, collecting stdout lines and the
    /// stderr tail — the execCli() shape of procs.ts.
    public func runCollect(
        _ executablePath: String,
        options: Options,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil
    ) async -> RunResult {
        let running: RunningProcess
        do {
            running = try spawn(executablePath, options: options)
        } catch {
            return RunResult(
                status: nil,
                spawnFailure: (error as? SpawnFailure) ?? SpawnFailure(message: "\(error)", setup: false),
                stderrTail: ""
            )
        }

        // Feed optional stdin, then close it — the EPIPE-tolerant way.
        if let stdinData {
            _ = running.stdinWriter?.deliver(stdinData, closeAfter: true)
        }

        // Feed optional stdin, then close it — the EPIPE-tolerant way.
        if let stdinData {
            _ = running.stdinWriter?.deliver(stdinData, closeAfter: true)
        }

        var stdoutTail = Data()
        for await chunk in running.stdoutBytes {
            stdoutTail.append(chunk)
            if stdoutTail.count > 65536 { stdoutTail = stdoutTail.suffix(65536) }
        }
        let result = await running.waitExit()
        return RunResult(
            status: result.status,
            spawnFailure: result.spawnFailure,
            stderrTail: result.stderrTail,
            stdoutTail: stdoutTail
        )
    }

    // MARK: failure wording

    /// Port of procs.ts describeSpawnFailure: bare errno strings read as a
    /// crash; the common codes each mean exactly one fixable thing.
    public static func describeSpawnFailure(_ error: any Error, cli: String) -> SpawnFailure {
        let nsError = error as NSError
        let text = nsError.localizedDescription.lowercased()
        // Foundation's Process.run() wraps exec failures in NSError 260 /
        // Cocoa domain with the POSIX errno nested in userInfo; older stacks
        // surface it as NSPOSIXErrorDomain directly. Match on both, plus a
        // message fallback because the wrapper shape has drifted across SDKs.
        let posixCode: Int32? = {
            if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return Int32(underlying.code)
            }
            return nil
        }()
        // Cocoa's Process.run() reports a missing executable as
        // NSFileNoSuchFileError (code 4, "doesn't exist.") with no POSIX
        // code nested — treat that shape as ENOENT too.
        if posixCode == POSIXError.ENOENT.rawValue || nsError.code == 4 && nsError.domain == NSCocoaErrorDomain
            || text.contains("no such file") {
            return SpawnFailure(
                message: "`\(cli)` isn't installed, or isn't on this app's PATH",
                setup: true
            )
        }
        if posixCode == POSIXError.EACCES.rawValue || posixCode == POSIXError.EPERM.rawValue
            || text.contains("permission") {
            return SpawnFailure(
                message: "`\(cli)` isn't executable — check its file permissions",
                setup: true
            )
        }
        return SpawnFailure(message: "spawn failed: \(nsError.localizedDescription)", setup: false)
    }

    // MARK: stream helpers

    /// UTF-8-safe byte-to-line splitting over an AsyncStream of Data chunks.
    /// A multibyte character split across two chunks decodes correctly
    /// because bytes are accumulated before decoding (the Swift rendering of
    /// claude.ts's setEncoding("utf8") comment).
    static func lines(of bytes: AsyncStream<Data>) -> AsyncStream<String> {
        return AsyncStream { continuation in
            let task = Task {
                var iterator = bytes.makeAsyncIterator()
                var buffer = Data()
                while let chunk = await iterator.next() {
                    buffer.append(chunk)
                    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = buffer[buffer.startIndex..<newlineIndex]
                        buffer.removeSubrange(buffer.startIndex...newlineIndex)
                        continuation.yield(String(decoding: line, as: UTF8.self))
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: internals

    private nonisolated static func makeProcess(
        _ executablePath: String,
        options: Options
    ) throws -> (Process, Pipe, Pipe, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = options.arguments
        if let cwd = options.cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if let environment = options.environment {
            // Deny-by-default: exactly this map, nothing inherited.
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        return (process, stdoutPipe, stderrPipe, stdinPipe)
    }

    private nonisolated static func start(_ parts: (Process, Pipe, Pipe, Pipe), escalationInterval: TimeInterval) throws -> RunningProcess {
        do {
            try parts.0.run()
        } catch {
            throw describeSpawnFailure(error, cli: parts.0.executableURL?.path ?? "?")
        }
        return wireUpShared(process: parts.0, stdoutPipe: parts.1, stderrPipe: parts.2, stdinPipe: parts.3, escalationInterval: escalationInterval)
    }

    /// Wire up the freshly-run process. Split out so both success paths share
    /// the exact same stream plumbing. Static + nonisolated: it touches only
    /// the process, its pipes, and lock-protected state boxes.
    nonisolated static func wireUpShared(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe, stdinPipe: Pipe, escalationInterval: TimeInterval) -> RunningProcess {
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // stdout: byte stream, fanned back out as both raw bytes and lines.
        let (stdoutBytes, stdoutContinuation) = AsyncStream<Data>.makeStream()
        let (stdoutLineBytes, stdoutLineContinuation) = AsyncStream<Data>.makeStream()

        let (stderrBytes, stderrContinuation) = AsyncStream<Data>.makeStream()

        // Drain via blocking reads on GLOBAL-queue threads, not detached
        // tasks: `availableData` parks its thread until the child closes the
        // pipe, and a parked cooperative-pool thread starves every other
        // task in the process whenever a child outlives its turn. Each
        // reader ends at EOF; the DrainGroup bookkeeping stays task-side.
        let drainGroup = DrainGroup()
        let reader = PipeReader()
        _ = Task.detached(priority: .utility) {
            await reader.run(stdoutHandle) { chunk in
                stdoutContinuation.yield(chunk)
                stdoutLineContinuation.yield(chunk)
            }
            drainGroup.finishStdout()
        }
        _ = Task.detached(priority: .utility) {
            await reader.run(stderrHandle) { chunk in
                stderrContinuation.yield(chunk)
            }
            drainGroup.finishStderr()
        }
        // Streams finish only after their drains end AND the process is gone,
        // so a consumer looping over the stream sees every byte before the
        // stream closes.
        Task.detached(priority: .utility) { [weak process] in
            guard let process else { return }
            _ = await Self.awaitExit(process)
            await drainGroup.awaitBoth()
            stdoutContinuation.finish()
            stdoutLineContinuation.finish()
            stderrContinuation.finish()
        }

        let pid = process.processIdentifier

        // Exit bookkeeping: first waiter wins, everyone shares the verdict.
        let state = RunState()
        let escalation = escalationInterval
        let waitExit: @Sendable () async -> RunResult = {
            await state.awaitResult()
        }

        // Termination watcher: record status once the process is gone. The
        // pipe-drain tasks are NOT cancelled here — they end on their own at
        // EOF, which arrives only after the child flushed and closed its
        // descriptors. This mirrors Node's 'close' firing after stdio flush,
        // and guarantees a fast-exiting child's final stdout lines (the
        // `result` frame) still reach the consumer.
        let stderrTailState = state
        Task.detached(priority: .utility) { [weak process] in
            guard let process else { return }
            let status = await Self.awaitExit(process)
            let result = RunResult(
                status: status,
                spawnFailure: nil,
                stderrTail: stderrTailState.stderrTail
            )
            stderrTailState.complete(result)
        }

        let interrupt: @Sendable () -> Void = { [weak process] in
            guard let process, process.isRunning else { return }
            process.interrupt()  // SIGINT to the child
            // Escalate: a child that traps/ignores SIGINT (and TERM) gets
            // SIGKILL after the grace window. Upstream sends SIGTERM to the
            // process GROUP via kill(-pid); Foundation cannot address a
            // group, so this is the documented divergence — same outcome
            // (the turn's tree dies), different signal choreography.
            let grace = escalationInterval
            let targetPid = pid
            Task.detached(priority: .utility) { [weak process] in
                guard let process else { return }
                let deadline = ContinuousClock.now + .seconds(grace)
                while process.isRunning && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    kill(targetPid, SIGKILL)
                }
            }
        }

        let stdinWriter = StdinWriter(handle: stdinPipe.fileHandleForWriting)
        return RunningProcess(
            pid: pid,
            stdoutLines: Self.lines(of: stdoutLineBytes),
            stderrBytes: stderrBytes,
            waitExit: waitExit,
            interrupt: interrupt,
            stdoutByteStream: stdoutBytes,
            stdinWriter: stdinWriter
        )
    }

    /// Wait for a Process to exit off the calling actor. The blocking
    /// `waitUntilExit` parks a GLOBAL-queue thread, never a cooperative one:
    /// parking a cooperative thread here starves the whole pool whenever a
    /// child outlives its turn (a hung CLI, a leaked fake), deadlocking any
    /// task that awaits a continuation afterwards.
    private static func awaitExit(_ process: Process) async -> ExitStatus {
        let verdict: (Int32, Process.TerminationReason) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, process.terminationReason))
            }
        }
        return classify(verdict.0, reason: verdict.1)
    }

    private static func waitWithTimeout(_ running: RunningProcess, seconds: TimeInterval) async -> RunResult? {
        await withTaskGroup(of: RunResult?.self) { group in
            group.addTask { await running.waitExit() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func classify(_ status: Int32, reason: Process.TerminationReason) -> ExitStatus {
        switch reason {
        case .uncaughtSignal:
            return .signaled(signal: status)
        case .exit:
            return .exited(code: status)
        @unknown default:
            return .exited(code: status)
        }
    }
}

/// Coordinates the two pipe-drain tasks: streams must not finish until both
/// drains have seen EOF, even if the process exits first.
private final class DrainGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutDone = false
    private var stderrDone = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func finishStdout() {
        lock.lock()
        stdoutDone = true
        let ready = stdoutDone && stderrDone
        let pending = ready ? continuations : []
        continuations = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func finishStderr() {
        lock.lock()
        stderrDone = true
        let ready = stdoutDone && stderrDone
        let pending = ready ? continuations : []
        continuations = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func awaitBoth() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stdoutDone && stderrDone {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Write-then-close access to a child's stdin. A write to a dying child's
/// pipe fails differently per platform and one of those ways is fatal — the
/// exact trap procs.ts:39-51 defuses by swallowing stdin errors. Writes here
/// are best-effort: failure is recorded, never thrown, because drivers settle
/// the turn from `waitExit` either way.
public final class StdinWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Deliver bytes; true when they were handed to the pipe. Closing the
    /// writer afterwards is the child's EOF signal (claude.ts's
    /// `s.child.stdin.end()`).
    @discardableResult
    func deliver(_ data: Data, closeAfter close: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        do {
            try handle.write(contentsOf: data)
            if close {
                closed = true
                do { try handle.close() } catch { /* pipe already gone */ }
            }
            return true
        } catch {
            return false
        }
    }
}

/// Shared mutable run state for one child: the terminal result and the
/// trailing stderr every late subscriber should still see.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<ProcessRunner.RunResult, Never>] = []
    private var result: ProcessRunner.RunResult?
    private var _stderrTail = ""

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return _stderrTail
    }

    func appendStderr(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _stderrTail += text
        if _stderrTail.count > 8192 { _stderrTail = String(_stderrTail.suffix(8192)) }
    }

    func awaitResult() async -> ProcessRunner.RunResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func complete(_ value: ProcessRunner.RunResult) {
        lock.lock()
        let pending = continuations
        continuations = []
        result = value
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}

/// Runs a blocking pipe reader on a GLOBAL-queue thread so the cooperative
/// pool never hosts a parked `availableData` call. The yield closure runs
/// back on the cooperative pool (it touches stream continuations).
private final class PipeReader: @unchecked Sendable {
    func run(
        _ handle: FileHandle,
        onChunk: @escaping @Sendable (Data) -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    onChunk(chunk)
                }
                continuation.resume()
            }
        }
    }
}
