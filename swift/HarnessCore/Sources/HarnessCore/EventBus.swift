import Foundation

// Fan-in event bus — the port of server/harness/bus.ts.
//
// Every adapter's event stream merges into one bus; each event is stamped
// with its providerInstanceId, teed to a per-thread canonical NDJSON log
// (the debugging trick both upstream and agentcal lean on), and delivered
// to subscribers (the SSE endpoint and the server-side message folder).
//
// Swift shape: an actor fed by an AsyncStream pump. Adapter callbacks are
// synchronous (matching ProviderAdapter.onEvent), so they enqueue into the
// stream and a single consumer task drains one event at a time — tee to the
// canonical log, then fan out to every subscriber in subscription order,
// exactly like upstream's serial publish loop.
public actor EventBus {
    /// One registered listener.
    private struct Subscriber {
        var id: UUID
        var listener: RuntimeEventListener
    }

    private var listeners: [Subscriber] = []
    /// Detach handles for every adapter wired by attach(instances:).
    private var unsubscribes: [Unsubscribe] = []
    /// Serial NDJSON appender state (upstream uses appendFileSync).
    private let appendLock = NSLock()
    /// Events enqueued but not yet delivered — the ordered-pump watermark.
    private let pending = PendingCounter()
    /// Inbound queue + its consumer task. The continuation is captured by
    /// synchronous adapter callbacks, which cannot await.
    private let stream: AsyncStream<RuntimeEvent>
    private let inbound: AsyncStream<RuntimeEvent>.Continuation
    private var pump: Task<Void, Never>?

    public init() {
        let (createdStream, continuation) = AsyncStream.makeStream(
            of: RuntimeEvent.self, bufferingPolicy: .unbounded)
        stream = createdStream
        inbound = continuation
    }

    deinit {
        inbound.finish()
        pump?.cancel()
    }

    /// Spawn the ordered consumer once, lazily — actor init cannot start a
    /// task that captures self before all stored properties are set.
    private func startPumpIfNeeded() {
        guard pump == nil else { return }
        var iterator = stream.makeAsyncIterator()
        pump = Task { [weak self] in
            while let event = await iterator.next() {
                await self?.drain(event)
            }
        }
    }

    // MARK: wiring

    /// Attach adapters to the bus. The hard invariant borrowed from
    /// correlateRuntimeEventWithInstance holds here too: an adapter may only
    /// emit events for its own driver kind — anything else is dropped on
    /// the floor with an error line, never forwarded.
    public func attach(instances: [any ProviderInstance]) {
        startPumpIfNeeded()
        for instance in instances {
            let instanceId = instance.instanceId
            let driverKind = instance.driverKind
            let inbound = self.inbound
            let pending = self.pending
            let unsub = instance.adapter.onEvent { event in
                guard event.base.provider == driverKind else {
                    FileHandle.standardError.write(
                        Data("bus: dropped cross-driver event from \(instanceId)\n".utf8))
                    return
                }
                var stamped = event
                stamped.base.providerInstanceId = instanceId
                pending.increment()
                inbound.yield(stamped)
            }
            unsubscribes.append(unsub)
        }
    }

    /// Publish an already-stamped event. Enqueues onto the ordered pump;
    /// arrival order is delivery order even under concurrent callers.
    public func publish(_ event: RuntimeEvent) {
        startPumpIfNeeded()
        pending.increment()
        inbound.yield(event)
    }

    /// Register a listener; returns its unsubscribe closure, matching
    /// ProviderAdapter.onEvent's contract. Calling it twice is harmless.
    @discardableResult
    public func subscribe(_ listener: @escaping RuntimeEventListener) -> Unsubscribe {
        let token = UUID()
        listeners.append(Subscriber(id: token, listener: listener))
        return { [weak self] in
            guard let self else { return }
            Task { await self.remove(token) }
        }
    }

    /// Undo every attach(instances:) — adapters stop feeding the bus.
    public func detachAll() {
        for unsub in unsubscribes.splice() {
            unsub()
        }
    }

    /// Resolves after every event yielded so far has been teed and
    /// dispatched — used by tests (and shutdown paths) that must observe
    /// settled bus state without guessing at scheduler timing.
    public func flushForTesting() async {
        await pending.waitUntilEmpty()
    }

    // MARK: internals

    /// Deliver ONE event: tee + fan-out. Only ever runs on the pump task,
    /// so events are processed strictly in arrival order.
    private func drain(_ event: RuntimeEvent) {
        teeToNdjson(event)
        for subscriber in listeners {
            subscriber.listener(event)
        }
        pending.decrement()
    }

    private func remove(_ id: UUID) {
        listeners.removeAll { $0.id == id }
    }

    /// Tee a redacted copy of the event to its per-thread canonical NDJSON
    /// log. The log is a file people paste into bug reports — credential-
    /// shaped content keeps its shape but loses its values.
    private func teeToNdjson(_ event: RuntimeEvent) {
        do {
            let dir = DataDirs.eventsDir
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = DataDirs.join(dir, "\(event.base.threadId).ndjson")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // Re-encode through untyped JSON so the redactor can walk keys
            // and string values without knowing the event schema.
            let eventData = try encoder.encode(event)
            let value = try JSONDecoder().decode(JSONValue.self, from: eventData)
            let redactedData = try encoder.encode(Redact.secrets(value))
            try appendLine(redactedData + Data("\n".utf8), to: path)
        } catch {
            /* logging must never take down the stream */
        }
    }

    /// Lock-backed counter the flush gate polls; simple and sufficient —
    /// the pump drains continuously, so a short poll loop converges.
    final class PendingCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func decrement() {
            lock.lock()
            count -= 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Resolve once every pending event has been delivered.
        func waitUntilEmpty(timeout: TimeInterval = 10) async {
            let deadline = Date().addingTimeInterval(timeout)
            while value > 0 && Date() < deadline {
                await Task.yield()
            }
        }
    }

    private func appendLine(_ data: Data, to path: String) throws {
        // Serialize concurrent appends from multiple publishes so lines
        // never interleave mid-write.
        appendLock.lock()
        defer { appendLock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try? handle.close()
            } catch {
                try? handle.close()
                // Recreate rather than leave a truncated line behind.
                FileManager.default.createFile(
                    atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

private extension Array {
    /// Remove and return all elements.
    mutating func splice() -> [Element] {
        let out = self
        removeAll()
        return out
    }
}
