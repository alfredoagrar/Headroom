import Foundation

/// State accumulated from a Codex rollout (`sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// `token_count` events carry cumulative totals. Each increase is attributed to the model of the
/// latest `turn_context`, so sessions that switch models are priced per model.
struct CodexRolloutUsage: Sendable {
    private(set) var sessionID: String?
    private(set) var cwd: String?
    private(set) var originator: String?
    private(set) var source: String?
    private(set) var cliVersion: String?
    private(set) var startedAt: Date?
    private(set) var model: String?
    private(set) var contextWindow: Int?
    private(set) var isWorking = false
    private(set) var totals = CodexTokenTotals()
    private(set) var totalsByModel: [String: CodexTokenTotals] = [:]

    private static let markers = ["session_meta", "turn_context", "token_count", "task_started", "task_complete", "turn_aborted"]
        .map { Data($0.utf8) }

    mutating func reset() { self = CodexRolloutUsage() }

    mutating func consume(_ line: Data) {
        guard Self.markers.contains(where: { line.hasMarker($0) }),
              let entry = try? JSONDecoder().decode(Line.self, from: line), let payload = entry.payload else { return }

        switch (entry.type, payload.type) {
        case ("session_meta", _):
            sessionID = payload.id ?? sessionID
            cwd = payload.cwd ?? cwd
            originator = payload.originator ?? originator
            source = payload.source ?? source
            cliVersion = payload.cliVersion ?? cliVersion
            startedAt = ISODate.parse(payload.timestamp) ?? startedAt
        case ("turn_context", _):
            model = payload.model ?? model
        case ("event_msg", "task_started"):
            isWorking = true
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            isWorking = false
        case ("event_msg", "token_count"):
            guard let info = payload.info, let raw = info.totalTokenUsage else { return }
            let current = CodexTokenTotals(input: raw.inputTokens ?? 0, cached: raw.cachedInputTokens ?? 0,
                                           cacheWrite: raw.cacheWriteInputTokens ?? 0, output: raw.outputTokens ?? 0,
                                           reasoning: raw.reasoningOutputTokens ?? 0)
            let key = model ?? "unknown"
            totalsByModel[key] = (totalsByModel[key] ?? CodexTokenTotals()) + current.delta(since: totals)
            totals = current
            contextWindow = info.modelContextWindow ?? contextWindow
        default:
            break
        }
    }

    var byModel: [String: ModelUsage] {
        totalsByModel.reduce(into: [:]) { result, item in
            result[item.key] = ModelUsage(tokens: item.value.tokens, cost: item.value.cost(model: item.key))
        }
    }

    var usage: ModelUsage { byModel.values.reduce(ModelUsage(), +) }

    func host(executablePath: String?) -> AgentHost {
        let path = executablePath ?? ""
        if path.contains("/.cursor/extensions/") { return .cursor }
        if path.contains("/.vscode/extensions/") { return .vscode }
        if path.contains("/Codex.app/") { return .desktop }
        switch (originator, source) {
        case ("codex_exec", _), (_, "exec"): return .exec
        case ("codex_cli_rs", _), (_, "cli"): return .cli
        case (_, "vscode"): return .vscode
        case (_, "app-server"), (_, "app_server"): return .appServer
        case (let originator?, _): return .other(originator)
        default: return .cli
        }
    }

    // Only these fields are decoded; `base_instructions`, `creator_*` ids and message content are never read.
    private struct Line: Decodable {
        let type: String?
        let payload: Payload?

        enum CodingKeys: String, CodingKey { case type, payload }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(.type)
            payload = c.lenient(.payload)
        }
    }

    private struct Payload: Decodable {
        let type: String?
        let id: String?
        let timestamp: String?
        let cwd: String?
        let originator: String?
        let source: String?
        let cliVersion: String?
        let model: String?
        let info: Info?

        enum CodingKeys: String, CodingKey {
            case type, id, timestamp, cwd, originator, source, cliVersion = "cli_version", model, info
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(.type)
            id = c.lenient(.id)
            timestamp = c.lenient(.timestamp)
            cwd = c.lenient(.cwd)
            originator = c.lenient(.originator)
            source = c.lenient(.source)
            cliVersion = c.lenient(.cliVersion)
            model = c.lenient(.model)
            info = c.lenient(.info)
        }
    }

    private struct Info: Decodable {
        let totalTokenUsage: Usage?
        let modelContextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage", modelContextWindow = "model_context_window"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalTokenUsage = c.lenient(.totalTokenUsage)
            modelContextWindow = c.lenient(.modelContextWindow)
        }
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let cacheWriteInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", cachedInputTokens = "cached_input_tokens"
            case cacheWriteInputTokens = "cache_write_input_tokens", outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = c.lenient(.inputTokens)
            cachedInputTokens = c.lenient(.cachedInputTokens)
            cacheWriteInputTokens = c.lenient(.cacheWriteInputTokens)
            outputTokens = c.lenient(.outputTokens)
            reasoningOutputTokens = c.lenient(.reasoningOutputTokens)
        }
    }
}

enum CodexRolloutFinder {
    static var defaultRoot: URL { CodexCredentials.authFile.deletingLastPathComponent() }

    /// Rollout folders use the local date: scan from the process start day to today, at most 7 days.
    static func candidateFiles(root: URL, since: Date, now: Date = .now, calendar: Calendar = .current) -> [URL] {
        let fm = FileManager.default
        let start = max(calendar.startOfDay(for: since), calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? since)
        var day = start
        var files: [URL] = []
        while day <= now {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appending(path: String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            files += names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.map { folder.appending(path: $0) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return files
    }

    /// Assigns each rollout (by its session start) to the latest-started process with the same cwd that
    /// started before it, so two Codex processes in one folder don't both claim every session.
    static func assign(rollouts: [(path: String, cwd: String, startedAt: Date)],
                       processes: [(pid: Int32, cwd: String, startedAt: Date)]) -> [Int32: [String]] {
        var result: [Int32: [String]] = [:]
        for rollout in rollouts {
            let owner = processes
                .filter { $0.cwd == rollout.cwd && $0.startedAt <= rollout.startedAt.addingTimeInterval(5) }
                .max { $0.startedAt < $1.startedAt }
            if let owner { result[owner.pid, default: []].append(rollout.path) }
        }
        return result
    }
}
