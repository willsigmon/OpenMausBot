import CompanionCore
import SwiftUI
import UIKit

struct ConnectedAppsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.scenePhase) private var scenePhase
    @State private var catalog: ConnectorCatalog?
    @State private var statuses: [String: ConnectorStatus] = [:]
    @State private var query = ""
    @State private var aliasCard: ConnectorCard?
    @State private var alias = ""
    @State private var disconnectTarget: DisconnectTarget?
    @State private var loading = true
    @State private var refreshing = false

    private var cards: [ConnectorCard] {
        let values = catalog?.cards ?? []
        guard !query.isEmpty else { return values }
        return values.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.slug.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if catalog?.configured == false {
                Section {
                    ContentUnavailableView(
                        "Connected apps need setup",
                        systemImage: "link.badge.plus",
                        description: Text("Configure Composio on your computer first. Provider credentials are never returned to this phone.")
                    )
                }
            }

            ForEach(cards) { card in
                Section {
                    let status = statuses[card.slug]
                    let accounts = status?.accounts ?? []
                    let isConnected = status?.connected == true
                    let isPending = status?.pending == true
                    if accounts.isEmpty, !isConnected, !isPending {
                        Button("Connect \(card.label)", systemImage: "plus.circle") {
                            Task { await authorize(card, alias: nil) }
                        }
                        .disabled(catalog?.configured != true)
                    } else if accounts.isEmpty {
                        let statusLabel = isPending ? "Connecting…" : "Connected"
                        let statusSymbol = isPending ? "clock" : "checkmark.circle.fill"
                        let statusColor = isPending ? Color.secondary : Color.green
                        Label(statusLabel, systemImage: statusSymbol)
                            .foregroundStyle(statusColor)
                        Text("Account details are unavailable from this provider. Refresh after authorization finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(accounts) { account in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.nonemptyAlias ?? "Primary account")
                                    Text(account.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(account.id)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Image(systemName: account.status.lowercased().contains("active") ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(account.status.lowercased().contains("active") ? .green : .secondary)
                            }
                            .swipeActions {
                                Button("Disconnect", role: .destructive) {
                                    disconnectTarget = DisconnectTarget(card: card, account: account)
                                }
                            }
                        }
                        Button("Add another account", systemImage: "person.crop.circle.badge.plus") {
                            alias = ""
                            aliasCard = card
                        }
                        .disabled(accounts.count >= 5)
                    }
                } header: {
                    HStack {
                        Text(card.label)
                        Spacer()
                        if statuses[card.slug]?.pending == true { Text("Connecting…") }
                    }
                } footer: {
                    Text(card.blurb)
                }
            }
        }
        .navigationTitle("Connected Apps")
        .searchable(text: $query, prompt: "Search apps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshStatuses(showProgress: true) }
                }
                .disabled(refreshing)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await refreshStatuses() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshStatuses() } }
        }
        .alert("Account alias", isPresented: Binding(
            get: { aliasCard != nil },
            set: { if !$0 { aliasCard = nil } }
        )) {
            TextField("Work, Personal, Client…", text: $alias)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { aliasCard = nil }
            Button("Continue") {
                guard let card = aliasCard else { return }
                let value = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
                aliasCard = nil
                Task { await authorize(card, alias: value) }
            }
            .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("An alias makes the account explicit when this agent uses more than one \(aliasCard?.label ?? "app") account.")
        }
        .confirmationDialog(
            "Disconnect \(disconnectTarget?.accountLabel ?? "this account")?",
            isPresented: Binding(get: { disconnectTarget != nil }, set: { if !$0 { disconnectTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect account", role: .destructive) {
                guard let target = disconnectTarget else { return }
                Task {
                    if await session.disconnectConnector(target.card.slug, accountId: target.account.id) {
                        await refreshStatuses()
                    }
                    disconnectTarget = nil
                }
            }
        } message: {
            Text("Only this \(disconnectTarget?.card.label ?? "app") account is removed. Other aliases remain connected.")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        catalog = await session.loadConnectorCatalog()
        await refreshStatuses()
    }

    private func refreshStatuses(showProgress: Bool = false) async {
        if showProgress { refreshing = true }
        defer { if showProgress { refreshing = false } }
        guard let response = await session.loadAllConnectorStatuses() else { return }
        statuses = response.services
    }

    private func authorize(_ card: ConnectorCard, alias: String?) async {
        guard let url = await session.authorizeConnector(card.slug, alias: alias) else { return }
        guard await UIApplication.shared.open(url) else {
            session.actionError = "The authorization page could not be opened. Try again after checking your browser restrictions."
            return
        }
    }
}

private struct DisconnectTarget: Identifiable {
    let card: ConnectorCard
    let account: ConnectorAccount
    var id: String { "\(card.slug):\(account.id)" }
    var accountLabel: String { account.nonemptyAlias ?? "this account" }
}

private extension ConnectorAccount {
    var nonemptyAlias: String? {
        alias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
