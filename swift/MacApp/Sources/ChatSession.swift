import Foundation
import HarnessCore

/// Owns the conversation: turns of the claude CLI folded into transcript
/// rows. Mirrors the desktop app's shape — user row, assistant text as it
/// streams, tool activity, errors — without any HTTP in between.
@MainActor
final class ChatSession: ObservableObject {
    enum Row: Identifiable, Equatable {
        case user(id: UUID, text: String)
        case assistant(id: UUID, text: String)
        case tool(id: UUID, title: String)
        case error(id: UUID, message: String)

        nonisolated var id: UUID {
            switch self {
            case .user(let id, _), .assistant(let id, _), .tool(let id, _), .error(let id, _):
                return id
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var busy = false
    @Published private(set) var engineStatus = "checking…"

    private let config = ClaudeConfig()
    private let runner = ProcessRunner()
    private var turnTask: Task<Void, Never>?
    /// Serializes event delivery onto the main actor from the CLI pump.
    private var pendingAssistantId: UUID?

    init() {
        Task { await probeEngine() }
    }

    private func probeEngine() async {
        // A cheap availability probe: can we find the CLI at all? Uses the
        // same PATH augmentation the real turns use.
        let candidates = EnvPath.findCliCandidates(name: config.cli)
        if candidates.isEmpty {
            engineStatus = "claude CLI not found on PATH"
        } else {
            engineStatus = "claude ready"
        }
    }

    var canSend: Bool { !busy && !rows.isEmpty || !busy }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }

        rows.append(.user(id: UUID(), text: text))
        busy = true
        let assistantId = UUID()
        pendingAssistantId = assistantId
        rows.append(.assistant(id: assistantId, text: ""))

        let input = SendTurnInput(
            threadId: "mac-main",
            text: text,
            resumeCursor: lastResumeCursor.map(JSONValue.string),
            system: nil
        )
        let emitBox = EventSink(target: self)
        let config = self.config
        let runner = self.runner

        turnTask = Task { [weak self] in
            let cursor = await ClaudeDriver.runTurn(
                config: config,
                input: input,
                turnId: RuntimeEvent.newId(),
                baseEnvironment: ClaudeDriver.environment(),
                runner: runner,
                emit: { event in
                    emitBox.deliver(event)
                }
            )
            await MainActor.run {
                self?.lastResumeCursor = cursor ?? self?.lastResumeCursor ?? nil
                self?.busy = false
                self?.pendingAssistantId = nil
            }
        }
    }

    func interrupt() {
        turnTask?.cancel()
        busy = false
    }

    private var lastResumeCursor: String?

    /// Hops canonical events onto the main actor. A separate object so the
    /// @Sendable emit closure captures something stable instead of self.
    fileprivate final class EventSink: @unchecked Sendable {
        private weak var target: ChatSession?

        init(target: ChatSession) {
            self.target = target
        }

        func deliver(_ event: RuntimeEvent) {
            guard let target else { return }
            Task { @MainActor [weak target] in
                guard let target else { return }
                target.absorb(event)
            }
        }
    }

    private func absorb(_ event: RuntimeEvent) {
        switch event.kind {
        case .contentDelta(_, let delta):
            appendToAssistant(delta)
        case .itemCompletedAssistantText(let text):
            replaceAssistant(with: text)
        case .itemStarted(.tool, let title):
            rows.append(.tool(id: UUID(), title: title ?? "running a tool…"))
        case .turnCompleted:
            break
        case .runtimeError(let message, _):
            if rows.last?.id == pendingAssistantId, case .assistant(let id, let text) = rows[rows.count - 1], text.isEmpty {
                rows.removeLast()
            } else if rows.last?.id == pendingAssistantId {
                _ = rows.popLast()
            }
            rows.append(.error(id: UUID(), message: message))
        default:
            break
        }
    }

    private func appendToAssistant(_ delta: String) {
        guard let index = rows.lastIndex(where: { $0.id == pendingAssistantId }) else { return }
        if case .assistant(let id, let existing) = rows[index] {
            rows[index] = .assistant(id: id, text: existing + delta)
        }
    }

    private func replaceAssistant(with text: String) {
        guard let index = rows.lastIndex(where: { $0.id == pendingAssistantId }) else { return }
        if case .assistant(let id, _) = rows[index] {
            rows[index] = .assistant(id: id, text: text)
        }
    }
}
