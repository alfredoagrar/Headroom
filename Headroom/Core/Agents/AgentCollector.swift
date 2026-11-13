import Darwin
import Foundation

protocol AgentCollecting: Sendable {
    /// `refreshFiles` re-reads transcripts and rollouts; otherwise only processes are sampled.
    func collect(refreshFiles: Bool) async -> AgentSnapshot
}

/// Samples agent processes and maps them to Claude Code / Codex session files.
/// All state is in memory; nothing is written to disk.
actor AgentCollector: AgentCollecting {
    private let claudeRoot: URL
    private let codexRoot: URL
    private let uid = getuid()

    private var cpuSamples: [Int32: CPUSample] = [:]
    private var claudeSessions: [String: ClaudeSessionState] = [:]
    private var codexFiles: [String: CodexFileState] = [:]
    private var codexAssignments: [Int32: [String]] = [:]
    private var codexScanned = false

    init(claudeRoot: URL = ClaudeSessionRegistry.defaultRoot, codexRoot: URL = CodexRolloutFinder.defaultRoot) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot.resolvingSymlinksInPath()
    }

    func collect(refreshFiles: Bool) -> AgentSnapshot {
        let now = Date()
        let processes = LibProc.allProcesses()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = byPID.mapValues(\.ppid)
        let children = ProcessTree.children(processes)

        // Claude Code: the registry is the source of truth, validated against the live process table.
        var claudeAgents: [Int32: ClaudeRegistryEntry] = [:]
        for entry in ClaudeSessionRegistry.load(root: claudeRoot) where Self.isSafeSessionID(entry.sessionID) {
            guard let process = byPID[entry.pid], process.uid == uid,
                  ClaudeSessionRegistry.matches(entry, processStart: process.startTime) else { continue }
            claudeAgents[entry.pid] = entry
        }
        let registered = Set(claudeAgents.keys)

        // Codex has no registry: match the native executable, skipping codex processes spawned by codex.
        let mine = processes.filter { $0.uid == uid }
        let codexCandidates = Set(mine.filter { $0.command == "codex" }.map(\.pid))
        let codexAgents = codexCandidates.filter { !ProcessTree.hasAncestor($0, in: codexCandidates, parents: parents) }

        // `claude` processes without a registry entry (older versions), unless they belong to another agent.
        let claudeCandidates = Set(mine.filter { $0.command == "claude" }.map(\.pid)).subtracting(registered)
        let looseClaude = claudeCandidates.filter {
            !ProcessTree.hasAncestor($0, in: registered.union(claudeCandidates), parents: parents)
        }
        let agentPIDs = registered.union(codexAgents).union(looseClaude)

        if refreshFiles {
            refreshClaude(claudeAgents.values)
            refreshCodex(agents: codexAgents, byPID: byPID, now: now)
            codexScanned = true
        }

        var rows: [AgentRow] = []
        for pid in agentPIDs.sorted() {
            guard let process = byPID[pid], let own = sample(process, now: now) else { continue }
            let descendants = ProcessTree.descendants(of: pid, children: children, excluding: agentPIDs)
            var childCPU = 0.0
            var childMemory: UInt64 = 0
            for child in descendants {
                guard let entry = byPID[child], let usage = sample(entry, now: now) else { continue }
                childCPU += usage.cpu ?? 0
                childMemory += usage.footprint
            }
            let path = LibProc.executablePath(pid: pid) ?? process.command
            let entry = claudeAgents[pid]
            let kind: AgentKind = codexAgents.contains(pid) ? .codex : .claudeCode
            let sessions: [AgentSession] = switch kind {
            case .claudeCode: entry.map { [claudeSession($0, executablePath: path)] } ?? []
            case .codex: codexSessions(pid: pid, executablePath: path, now: now)
            }
            rows.append(AgentRow(
                pid: pid, kind: kind, startedAt: process.startTime, executablePath: path,
                processCWD: entry?.cwd ?? LibProc.workingDirectory(pid: pid),
                cpuPercent: own.cpu.map { $0 + childCPU }, ownCPUPercent: own.cpu,
                memoryBytes: own.footprint + childMemory, ownMemoryBytes: own.footprint,
                childCount: descendants.count, sessions: sessions,
                sessionsPending: kind == .codex && !codexScanned))
        }

        cpuSamples = cpuSamples.filter { byPID[$0.key] != nil }
        claudeSessions = claudeSessions.filter { id, _ in claudeAgents.values.contains { $0.sessionID == id } }
        return AgentSnapshot(rows: rows, summary: AgentSummary(rows: rows), collectedAt: now)
    }

    /// Session ids become file names; anything that could escape the projects folder is rejected.
    static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: - Processes

    private struct CPUSample: Sendable {
        let startTime: Date
        let cpuNanos: UInt64
        let at: Date
        let percent: Double?
    }

    /// CPU % needs two samples at least a second apart; closer calls reuse the last value.
    private func sample(_ process: ProcessEntry, now: Date) -> (cpu: Double?, footprint: UInt64)? {
        guard let usage = LibProc.resourceUsage(pid: process.pid) else { return nil }
        guard let previous = cpuSamples[process.pid], previous.startTime == process.startTime else {
            cpuSamples[process.pid] = CPUSample(startTime: process.startTime, cpuNanos: usage.cpuNanos, at: now, percent: nil)
            return (nil, usage.footprint)
        }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed >= 1 else { return (previous.percent, usage.footprint) }
        let percent = ProcessTree.cpuPercent(previousNanos: previous.cpuNanos, currentNanos: usage.cpuNanos, elapsed: elapsed)
        cpuSamples[process.pid] = CPUSample(startTime: process.startTime, cpuNanos: usage.cpuNanos, at: now, percent: percent)
        return (percent, usage.footprint)
    }

    // MARK: - Claude Code

    private struct TranscriptState: Sendable {
        var tail = JSONLTail()
        var usage = ClaudeTranscriptUsage()
        var stamp: FileStamp?
    }

    private struct SubagentState: Sendable {
        var transcript = TranscriptState()
        var meta: ClaudeSubagentMeta?
    }

    private struct ClaudeSessionState: Sendable {
        var transcriptURL: URL?
        var main = TranscriptState()
        var subagents: [String: SubagentState] = [:]
        var scanned = false
    }

    private func refreshClaude(_ entries: some Sequence<ClaudeRegistryEntry>) {
        for entry in entries {
            var state = claudeSessions[entry.sessionID] ?? ClaudeSessionState()
            if state.transcriptURL == nil { state.transcriptURL = transcriptURL(for: entry.sessionID) }
            if let url = state.transcriptURL {
                Self.refresh(&state.main, url: url)
                refreshSubagents(&state, transcript: url, sessionID: entry.sessionID)
            }
            state.scanned = true
            claudeSessions[entry.sessionID] = state
        }
    }

    private func transcriptURL(for sessionID: String) -> URL? {
        let fm = FileManager.default
        let projects = claudeRoot.appending(path: "projects")
        let folders = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appending(path: "\(sessionID).jsonl") }.first { fm.fileExists(atPath: $0.path) }
    }

    private func refreshSubagents(_ state: inout ClaudeSessionState, transcript: URL, sessionID: String) {
        let folder = transcript.deletingLastPathComponent().appending(path: sessionID).appending(path: "subagents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            var sub = state.subagents[name] ?? SubagentState()
            Self.refresh(&sub.transcript, url: folder.appending(path: name))
            if sub.meta == nil {
                let meta = folder.appending(path: String(name.dropLast(".jsonl".count)) + ".meta.json")
                sub.meta = (try? Data(contentsOf: meta)).flatMap(ClaudeSubagentMeta.parse)
            }
            state.subagents[name] = sub
        }
    }

    private static func refresh(_ state: inout TranscriptState, url: URL) {
        guard let stamp = FileStamp.of(url), stamp != state.stamp else { return }
        guard let (lines, fromStart) = try? state.tail.readNewLines(at: url, stamp: stamp) else { return }
        if fromStart { state.usage.reset() }
        for line in lines { state.usage.consume(line) }
        state.stamp = stamp
    }

    private func claudeSession(_ entry: ClaudeRegistryEntry, executablePath: String) -> AgentSession {
        let state = claudeSessions[entry.sessionID]
        var usage = UsageState.loading
        var byModel: [String: ModelUsage] = [:]
        var subagents: [AgentSubagent] = []
        var lastActivity = entry.statusUpdatedAt

        if let state, state.scanned {
            if state.transcriptURL == nil {
                usage = .unavailable(reason: "Session transcript not found")
            } else {
                var total = state.main.usage.usage
                byModel = state.main.usage.byModel
                lastActivity = Self.latest(lastActivity, state.main.stamp?.modified)
                for (name, sub) in state.subagents {
                    let subUsage = sub.transcript.usage.usage
                    total += subUsage
                    byModel.merge(sub.transcript.usage.byModel, uniquingKeysWith: +)
                    subagents.append(AgentSubagent(id: name, agentType: sub.meta?.agentType, description: sub.meta?.description,
                                                   model: sub.transcript.usage.lastModel, usage: subUsage,
                                                   lastActivity: sub.transcript.stamp?.modified))
                    lastActivity = Self.latest(lastActivity, sub.transcript.stamp?.modified)
                }
                usage = .loaded(total)
            }
        }
        subagents.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }

        return AgentSession(id: entry.sessionID, kind: .claudeCode, host: entry.host(executablePath: executablePath),
                            cwd: entry.cwd, title: entry.title, version: entry.version, startedAt: entry.startedAt,
                            lastActivity: lastActivity, status: entry.agentStatus, model: state?.main.usage.lastModel,
                            usage: usage, byModel: byModel, subagents: subagents)
    }

    private static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        default: a ?? b
        }
    }

    // MARK: - Codex

    private struct CodexFileState: Sendable {
        var tail = JSONLTail()
        var usage = CodexRolloutUsage()
        var stamp: FileStamp?
    }

    private func refreshCodex(agents: Set<Int32>, byPID: [Int32: ProcessEntry], now: Date) {
        let sessionsFolder = codexRoot.appending(path: "sessions").path + "/"
        var assignments: [Int32: [String]] = [:]
        var unmapped: [(pid: Int32, cwd: String, startedAt: Date)] = []

        for pid in agents {
            let open = Set(LibProc.openFilePaths(pid: pid).filter { $0.hasPrefix(sessionsFolder) && $0.hasSuffix(".jsonl") })
            if !open.isEmpty {
                assignments[pid] = open.sorted()
            } else if let process = byPID[pid], let cwd = LibProc.workingDirectory(pid: pid) {
                unmapped.append((pid, cwd, process.startTime))
            }
        }

        var considered = Set(assignments.values.joined())
        // Fallback when a process doesn't keep its rollout open: match by cwd and start time.
        if let earliest = unmapped.map(\.startedAt).min() {
            var rollouts: [(path: String, cwd: String, startedAt: Date)] = []
            for url in CodexRolloutFinder.candidateFiles(root: codexRoot, since: earliest, now: now)
            where !considered.contains(url.path) {
                guard let stamp = FileStamp.of(url), stamp.modified >= earliest.addingTimeInterval(-60) else { continue }
                refreshCodexFile(url)
                considered.insert(url.path)
                if let usage = codexFiles[url.path]?.usage, let cwd = usage.cwd {
                    rollouts.append((url.path, cwd, usage.startedAt ?? stamp.modified))
                }
            }
            assignments.merge(CodexRolloutFinder.assign(rollouts: rollouts, processes: unmapped)) { $0 + $1 }
        }

        for path in Set(assignments.values.joined()) { refreshCodexFile(URL(fileURLWithPath: path)) }
        codexAssignments = assignments
        codexFiles = codexFiles.filter { considered.contains($0.key) }
    }

    private func refreshCodexFile(_ url: URL) {
        var state = codexFiles[url.path] ?? CodexFileState()
        guard let stamp = FileStamp.of(url), stamp != state.stamp else { return }
        guard let (lines, fromStart) = try? state.tail.readNewLines(at: url, stamp: stamp) else { return }
        if fromStart { state.usage.reset() }
        for line in lines { state.usage.consume(line) }
        state.stamp = stamp
        codexFiles[url.path] = state
    }

    private func codexSessions(pid: Int32, executablePath: String, now: Date) -> [AgentSession] {
        (codexAssignments[pid] ?? []).compactMap { path in
            guard let state = codexFiles[path] else { return nil }
            let rollout = state.usage
            let modified = state.stamp?.modified
            // A turn that never logged `task_complete` (crash, kill) shouldn't stay "working" forever.
            let working = rollout.isWorking && (modified.map { now.timeIntervalSince($0) < 1800 } ?? false)
            return AgentSession(id: rollout.sessionID ?? path, kind: .codex, host: rollout.host(executablePath: executablePath),
                                cwd: rollout.cwd ?? "", title: nil, version: rollout.cliVersion, startedAt: rollout.startedAt,
                                lastActivity: modified, status: working ? .working : .idle(since: modified),
                                model: rollout.model, usage: .loaded(rollout.usage), byModel: rollout.byModel, subagents: [])
        }
    }
}
