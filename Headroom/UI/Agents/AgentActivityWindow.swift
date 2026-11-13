import SwiftUI

struct AgentActivityWindow: View {
    static let windowID = "agents"

    @Environment(AgentMonitor.self) private var monitor
    @State private var selection: AgentRow.ID?
    @State private var sortOrder = [KeyPathComparator(\AgentRow.statusRank), KeyPathComparator(\AgentRow.cpuSortValue, order: .reverse)]
    @State private var workingOnly = false
    @State private var showInspector = true

    private var visibleRows: [AgentRow] {
        (workingOnly ? monitor.rows.filter(\.isWorking) : monitor.rows).sorted(using: sortOrder)
    }

    private var now: Date { monitor.lastUpdated ?? .now }

    var body: some View {
        VStack(spacing: 12) {
            SummaryTiles(summary: monitor.summary)
                .padding([.horizontal, .top], 14)
            content
        }
        .frame(minWidth: 720, minHeight: 400)
        .navigationTitle("Agent activity")
        .toolbar {
            ToolbarItem {
                Toggle("Working only", isOn: $workingOnly)
                    .help("Hide idle agents")
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(showInspector ? "Hide inspector" : "Show inspector")
            }
        }
        .inspector(isPresented: $showInspector) {
            AgentInspector(row: monitor.rows.first { $0.id == selection }, now: now)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if monitor.lastUpdated == nil {
            ProgressView("Looking for agents…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if monitor.rows.isEmpty {
            ContentUnavailableView("No agents running", systemImage: "moon.zzz",
                                   description: Text("Start Claude Code or Codex and they'll show up here."))
        } else {
            table
        }
    }

    private var table: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Agent", value: \.agentSortName) { row in
                AgentNameCell(row: row)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Project", value: \.projectName) { row in
                Text(row.projectName).lineLimit(1).help(row.projectPath)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Status", value: \.statusRank) { row in
                StatusLabel(status: row.status, now: now)
            }
            .width(min: 80, ideal: 100)

            TableColumn("CPU", value: \.cpuSortValue) { row in
                Text(row.cpuPercent.map(AgentFormat.percent) ?? "—")
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Memory", value: \.memoryBytes) { row in
                Text(AgentFormat.bytes(row.memoryBytes))
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 72)

            TableColumn("Uptime", value: \.startedAt) { row in
                Text(AgentFormat.duration(now.timeIntervalSince(row.startedAt)))
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 66)

            TableColumn("Tokens", value: \.tokenSortValue) { row in
                UsageValue(usage: row.usage) { AgentFormat.tokens($0.tokens.total) }
            }
            .width(min: 56, ideal: 66)

            TableColumn("Est. cost", value: \.costSortValue) { row in
                UsageValue(usage: row.usage) { AgentFormat.cost($0.cost) }
                    .help(AgentFormat.costDisclaimer)
            }
            .width(min: 60, ideal: 72)
        }
    }
}

private struct AgentNameCell: View {
    let row: AgentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(row.kind.displayName).fontWeight(.medium)
            } icon: {
                Image(systemName: row.kind.symbol).foregroundStyle(row.kind.tint)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let session = row.primarySession
        return [row.host?.displayName, session?.title, session?.model.map(AgentFormat.modelName)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct StatusLabel: View {
    let status: AgentStatus
    let now: Date

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.isWorking ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
    }

    private var text: String {
        switch status {
        case .working: "Working"
        case .idle(let since?): "Idle " + AgentFormat.duration(now.timeIntervalSince(since)).replacingOccurrences(of: "<1m", with: "now")
        case .idle(nil): "Idle"
        case .other(let raw): raw
        case .unknown: "—"
        }
    }
}

/// Token or cost cell: spinner while the first scan runs, "—" with the reason when unavailable.
struct UsageValue: View {
    let usage: UsageState
    let format: (ModelUsage) -> String

    var body: some View {
        Group {
            switch usage {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let value):
                Text(format(value)).monospacedDigit()
            case .unavailable(let reason):
                Text("—").foregroundStyle(.secondary).help(reason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SummaryTiles: View {
    let summary: AgentSummary

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                tile("Agents", "\(summary.agentCount)")
                tile("Working", "\(summary.workingCount)")
                tile("CPU", AgentFormat.percent(summary.cpuPercent))
                tile("Memory", AgentFormat.bytes(summary.memoryBytes))
                tile("Tokens", AgentFormat.tokens(summary.tokens))
                tile("Est. cost", AgentFormat.cost(summary.cost))
                    .help(AgentFormat.costDisclaimer)
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

extension AgentKind {
    var symbol: String {
        switch self {
        case .claudeCode: ProviderID.claude.symbol
        case .codex: ProviderID.codex.symbol
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: ProviderID.claude.tint
        case .codex: ProviderID.codex.tint
        }
    }
}
