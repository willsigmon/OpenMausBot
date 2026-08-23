import SwiftUI
import HarnessCore

struct ContentView: View {
    @EnvironmentObject private var session: ChatSession
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.busy ? Color.orange : Color.green)
                .frame(width: 9, height: 9)
            Text("openwsigbot — native")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(session.engineStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.rows.isEmpty {
                        Text("Say something. Turns run the real claude CLI on this Mac — no Node involved.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 48)
                    }
                    ForEach(session.rows) { row in
                        RowView(row: row)
                            .id(row.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: session.rows.count) { _ in
                if let last = session.rows.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.rows.last) { _ in
                if let last = session.rows.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.system(size: 14))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                )
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: session.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(canSendColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(session.busy && !canActuallySend)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var canActuallySend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSendColor: Color {
        canActuallySend ? Color.accentColor : Color.gray.opacity(0.45)
    }

    private func send() {
        guard canActuallySend, !session.busy else { return }
        let text = draft
        draft = ""
        session.send(text)
    }
}

private struct RowView: View {
    let row: ChatSession.Row

    var body: some View {
        switch row {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 64)
                Text(text)
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.22)))
            }
        case .assistant(_, let text):
            HStack(alignment: .top, spacing: 8) {
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13.5))
                        .textSelection(.enabled)
                } else {
                    Text("thinking…")
                        .font(.system(size: 12.5).italic())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 64)
            }
        case .tool(_, let title):
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        case .error(_, let message):
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        }
    }
}
