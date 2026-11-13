import Foundation

enum AgentKind: String, Sendable, Hashable {
    case claudeCode, codex

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

enum AgentHost: Sendable, Hashable {
    case desktop, vscode, cursor, jetbrains, cli, exec, appServer, sdk
    case other(String)

    var displayName: String {
        switch self {
        case .desktop: "Desktop"
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .jetbrains: "JetBrains"
        case .cli: "CLI"
        case .exec: "Exec"
        case .appServer: "App server"
        case .sdk: "SDK"
        case .other(let raw): raw
        }
    }
}

enum AgentStatus: Sendable, Hashable {
    case working
    case idle(since: Date?)
    case other(String)
    case unknown

    var isWorking: Bool { self == .working }

    /// Sort rank: working first, unknown last.
    var rank: Int {
        switch self {
        case .working: 0
        case .other: 1
        case .idle: 2
        case .unknown: 3
        }
    }
}

/// Token counts in disjoint categories, so `total` never double counts.
struct TokenUsage: Sendable, Hashable {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0
    /// Subset of `output`; shown for information only.
    var thinking = 0

    var total: Int { input + cacheRead + cacheWrite + output }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, cacheRead: lhs.cacheRead + rhs.cacheRead,
                   cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output,
                   thinking: lhs.thinking + rhs.thinking)
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}

struct CostEstimate: Sendable, Hashable {
    var usd = 0.0
    /// Some usage belongs to a model without a known price, so `usd` is a lower bound.
    var hasUnpricedUsage = false

    static func + (lhs: CostEstimate, rhs: CostEstimate) -> CostEstimate {
        CostEstimate(usd: lhs.usd + rhs.usd, hasUnpricedUsage: lhs.hasUnpricedUsage || rhs.hasUnpricedUsage)
    }

    static func += (lhs: inout CostEstimate, rhs: CostEstimate) { lhs = lhs + rhs }
}

struct ModelUsage: Sendable, Hashable {
    var tokens = TokenUsage()
    var cost = CostEstimate()

    static func + (lhs: ModelUsage, rhs: ModelUsage) -> ModelUsage {
        ModelUsage(tokens: lhs.tokens + rhs.tokens, cost: lhs.cost + rhs.cost)
    }

    static func += (lhs: inout ModelUsage, rhs: ModelUsage) { lhs = lhs + rhs }
}

enum UsageState: Sendable, Hashable {
    case loading
    case loaded(ModelUsage)
    case unavailable(reason: String)

    var loaded: ModelUsage? {
        if case .loaded(let usage) = self { usage } else { nil }
    }
}

struct AgentSubagent: Sendable, Hashable, Identifiable {
    let id: String
    let agentType: String?
    let description: String?
    let model: String?
    let usage: ModelUsage
    let lastActivity: Date?
}

struct AgentSession: Sendable, Hashable, Identifiable {
    /// Provider session id: used for lookups, never displayed.
    let id: String
    let kind: AgentKind
    let host: AgentHost
    let cwd: String
    let title: String?
    let version: String?
    let startedAt: Date?
    let lastActivity: Date?
    let status: AgentStatus
    let model: String?
    /// Totals including subagents.
    let usage: UsageState
    let byModel: [String: ModelUsage]
    let subagents: [AgentSubagent]
}

/// One row per agent process.
struct AgentRow: Sendable, Hashable, Identifiable {
    let pid: Int32
    let kind: AgentKind
    let startedAt: Date
    let executablePath: String
    let processCWD: String?
    /// `nil` until two samples exist.
    let cpuPercent: Double?
    let ownCPUPercent: Double?
    let memoryBytes: UInt64
    let ownMemoryBytes: UInt64
    let childCount: Int
    /// Claude Code: one. Codex app-server: zero or more.
    let sessions: [AgentSession]
    /// Session files haven't been scanned yet (first refresh still running).
    let sessionsPending: Bool

    var id: Int32 { pid }

    var primarySession: AgentSession? {
        sessions.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
    }

    var host: AgentHost? { primarySession?.host }

    var status: AgentStatus {
        if sessions.contains(where: \.status.isWorking) { return .working }
        return primarySession?.status ?? .unknown
    }

    var isWorking: Bool { status.isWorking }

    var projectPath: String { primarySession?.cwd ?? processCWD ?? "" }

    var projectName: String {
        let name = projectPath.isEmpty ? "—" : URL(fileURLWithPath: projectPath).lastPathComponent
        return sessions.count > 1 ? "\(name) +\(sessions.count - 1)" : name
    }

    var usage: UsageState {
        guard !sessions.isEmpty else { return sessionsPending ? .loading : .unavailable(reason: "Session data not found") }
        if sessions.contains(where: { $0.usage == .loading }) { return .loading }
        let loaded = sessions.compactMap(\.usage.loaded)
        if loaded.isEmpty, case .unavailable(let reason)? = sessions.first?.usage {
            return .unavailable(reason: reason)
        }
        return .loaded(loaded.reduce(ModelUsage(), +))
    }

    // Sort keys for the table.
    var agentSortName: String { kind.displayName + (host?.displayName ?? "") }
    var statusRank: Int { status.rank }
    var cpuSortValue: Double { cpuPercent ?? 0 }
    var tokenSortValue: Int { usage.loaded?.tokens.total ?? -1 }
    var costSortValue: Double { usage.loaded?.cost.usd ?? -1 }
}

struct AgentSummary: Sendable, Hashable {
    var agentCount = 0
    var workingCount = 0
    var cpuPercent = 0.0
    var memoryBytes: UInt64 = 0
    var tokens = 0
    var cost = CostEstimate()

    init() {}

    init(rows: [AgentRow]) {
        agentCount = rows.count
        workingCount = rows.filter(\.isWorking).count
        for row in rows {
            cpuPercent += row.cpuPercent ?? 0
            memoryBytes += row.memoryBytes
            if let usage = row.usage.loaded {
                tokens += usage.tokens.total
                cost += usage.cost
            }
        }
    }
}

struct AgentSnapshot: Sendable {
    let rows: [AgentRow]
    let summary: AgentSummary
    let collectedAt: Date

    static let empty = AgentSnapshot(rows: [], summary: AgentSummary(), collectedAt: .distantPast)
}
