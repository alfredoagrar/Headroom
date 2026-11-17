import SwiftUI

struct AgentInspector: View {
    let row: AgentRow?
    let now: Date

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(row)
                    if row.sessions.isEmpty {
                        UsageNote(usage: row.usage)
                    }
                    ForEach(row.sessions) { session in
                        SessionDetails(session: session, showHeader: row.sessions.count > 1, now: now)
                    }
                    resources(row)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No agent selected", systemImage: "cpu",
                                   description: Text("Select an agent to see its details."))
        }
    }

    private func header(_ row: AgentRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(row.kind.displayName + (row.host.map { " · \($0.displayName)" } ?? ""), systemImage: row.kind.symbol)
                    .font(.headline)
                Spacer()
                StatusLabel(status: row.status, now: now).font(.callout)
            }
            if let title = row.primarySession?.title, row.sessions.count == 1 {
                Text(title).font(.subheadline)
            }
            Text(row.projectPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(details(row)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func details(_ row: AgentRow) -> String {
        var parts = ["PID \(row.pid)"]
        if let version = row.primarySession?.version { parts.append("v\(version)") }
        parts.append("started " + AgentFormat.dayTime(row.startedAt, now: now))
        return parts.joined(separator: " · ")
    }

    private func resources(_ row: AgentRow) -> some View {
        Section {
            LabeledContent("CPU") {
                Text(cpuText(row)).monospacedDigit()
            }
            LabeledContent("Memory") {
                Text(memoryText(row)).monospacedDigit()
            }
        } header: {
            SectionTitle("Resources")
        }
    }

    private func cpuText(_ row: AgentRow) -> String {
        guard let total = row.cpuPercent, let own = row.ownCPUPercent else { return "—" }
        guard row.childCount > 0 else { return AgentFormat.percent(total) }
        return "\(AgentFormat.percent(total)) (agent \(AgentFormat.percent(own)) · \(row.childCount) children \(AgentFormat.percent(total - own)))"
    }

    private func memoryText(_ row: AgentRow) -> String {
        guard row.childCount > 0 else { return AgentFormat.bytes(row.memoryBytes) }
        return "\(AgentFormat.bytes(row.memoryBytes)) (agent \(AgentFormat.bytes(row.ownMemoryBytes)) · children \(AgentFormat.bytes(row.memoryBytes - row.ownMemoryBytes)))"
    }
}

private struct SessionDetails: View {
    let session: AgentSession
    let showHeader: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showHeader {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: session.cwd).lastPathComponent).font(.subheadline.weight(.semibold))
                    StatusLabel(status: session.status, now: now).font(.caption)
                }
            }
            switch session.usage {
            case .loaded(let usage):
                tokens(usage)
                if session.byModel.count > 0 { byModel }
                if !session.subagents.isEmpty { subagents }
            default:
                UsageNote(usage: session.usage)
            }
        }
    }

    private func tokens(_ usage: ModelUsage) -> some View {
        Section {
            row("Input", usage.tokens.input)
            row("Output", usage.tokens.output,
                note: usage.tokens.thinking > 0 ? "thinking \(AgentFormat.tokens(usage.tokens.thinking))" : nil)
            row("Cache read", usage.tokens.cacheRead)
            row("Cache write", usage.tokens.cacheWrite)
            LabeledContent {
                Text(AgentFormat.cost(usage.cost)).monospacedDigit()
            } label: {
                HStack(spacing: 4) {
                    Text("Est. cost")
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .help(AgentFormat.costDisclaimer)
            }
        } header: {
            HStack {
                SectionTitle("Tokens (session)")
                Spacer()
                Text(AgentFormat.tokens(usage.tokens.total)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
        }
    }

    private func row(_ title: String, _ value: Int, note: String? = nil) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let note { Text("(\(note))").foregroundStyle(.secondary) }
                Text(AgentFormat.tokens(value)).monospacedDigit()
            }
        }
    }

    private var byModel: some View {
        Section {
            ForEach(session.byModel.sorted { $0.value.tokens.total > $1.value.tokens.total }, id: \.key) { model, usage in
                LabeledContent(AgentFormat.modelName(model)) {
                    Text("\(AgentFormat.tokens(usage.tokens.total))  \(AgentFormat.cost(usage.cost))").monospacedDigit()
                }
            }
        } header: {
            SectionTitle("By model")
        }
    }

    private var subagents: some View {
        Section {
            ForEach(session.subagents) { sub in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(sub.agentType ?? "Subagent").fontWeight(.medium)
                        Spacer()
                        Text("\(AgentFormat.tokens(sub.usage.tokens.total))  \(AgentFormat.cost(sub.usage.cost))").monospacedDigit()
                    }
                    HStack {
                        Text(sub.description ?? sub.model.map(AgentFormat.modelName) ?? "")
                            .lineLimit(1)
                        Spacer()
                        if let last = sub.lastActivity {
                            Text(now.timeIntervalSince(last) < 60 ? "active \(AgentFormat.ago(last, now: now))" : AgentFormat.ago(last, now: now))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionTitle("Subagents (\(session.subagents.count))")
        }
    }
}

private struct UsageNote: View {
    let usage: UsageState

    var body: some View {
        switch usage {
        case .loading:
            ProgressView("Reading session…").controlSize(.small)
        case .unavailable(let reason):
            Label(reason, systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
