import Foundation
@testable import HarnessCore

/// Shared fixture builders so every event suite constructs events the same
/// way and assertions focus on wire shape, not construction noise.
enum EventFixtures {
    static let threadId: ThreadId = "th-1"
    static let provider: DriverKind = "claude"

    static func base(
        eventId: String = "ev-test-0001",
        createdAt: String = "2026-08-22T04:00:00.000Z"
    ) -> RuntimeEventBase {
        RuntimeEventBase(
            eventId: eventId,
            provider: provider,
            providerInstanceId: "inst-9",
            threadId: threadId,
            createdAt: createdAt
        )
    }

    /// The 12 kind cases with representative payloads.
    static func allKinds() -> [(name: String, kind: RuntimeEventKind)] {
        [
            ("session.started", .sessionStarted(sessionId: "sess-1", model: "claude-sonnet")),
            ("session.exited", .sessionExited(reason: "cli exited")),
            ("turn.started", .turnStarted),
            (
                "turn.completed",
                .turnCompleted(
                    ok: true,
                    stopReason: "end_turn",
                    cost: 0.42,
                    denials: ["bash"],
                    usage: TokenUsage(input: 1000, output: 200)
                )
            ),
            ("item.started", .itemStarted(itemKind: .tool, title: "Bash")),
            ("item.updated", .itemUpdated(itemKind: .reasoning, tokens: 128)),
            ("item.completed(tool)", .itemCompletedTool(ok: false)),
            ("item.completed(assistant_text)", .itemCompletedAssistantText(text: "Done.")),
            ("content.delta", .contentDelta(streamKind: .assistantText, delta: "Hel")),
            (
                "request.opened",
                .requestOpened(
                    requestType: .permission,
                    tool: "bash",
                    summary: "run rm -rf /tmp/x",
                    choices: ["allow", "deny"],
                    approvalScope: .localComputer
                )
            ),
            (
                "request.resolved",
                .requestResolved(behavior: .answer, source: .user, approvalScope: nil)
            ),
            ("thread.token-usage.updated", .threadTokenUsageUpdated(usage: TokenUsage(input: 10, output: 2))),
        ]
    }
}
