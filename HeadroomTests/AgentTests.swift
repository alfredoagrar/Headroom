import Darwin
import Foundation
import Testing

private final class AgentFixtureToken {}

private func agentFixture(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle(for: AgentFixtureToken.self).url(forResource: name, withExtension: ext))
    return try Data(contentsOf: url)
}

private func lines(_ data: Data) -> [Data] { data.split(separator: 0x0A).map { Data($0) } }

private func parseTranscript(_ data: Data) -> ClaudeTranscriptUsage {
    var usage = ClaudeTranscriptUsage()
    for line in lines(data) { usage.consume(line) }
    return usage
}

private func parseRollout(_ data: Data) -> CodexRolloutUsage {
    var usage = CodexRolloutUsage()
    for line in lines(data) { usage.consume(line) }
    return usage
}

private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "headroom-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Reads whatever was appended since the last call, like the collector does.
private struct TailReader {
    var tail = JSONLTail()
    var usage = ClaudeTranscriptUsage()

    mutating func pump(_ url: URL) throws { try tail.drain(url, into: &usage) }
}

private struct LineCollector: JSONLConsumer {
    var lines: [String] = []
    var resets = 0
    mutating func reset() { lines = []; resets += 1 }
    mutating func consume(_ line: Data) { lines.append(String(decoding: line, as: UTF8.self)) }
}

// MARK: - Claude Code registry (AC2, AC3)

@Suite struct ClaudeSessionRegistryTests {
    @Test func parsesRegistryFixture() throws {
        let entry = try #require(ClaudeSessionRegistry.parse(agentFixture("claude_session_registry", "json")))
        #expect(entry.pid == 4242)
        #expect(entry.sessionID == "00000000-0000-4000-8000-000000000001")
        #expect(entry.cwd == "/Users/test/Projects/headroom")
        #expect(entry.title == "Fixture session")
        #expect(entry.version == "2.1.321")
        #expect(entry.agentStatus == .working)
        #expect(entry.host(executablePath: nil) == .desktop)
        #expect(entry.host(executablePath: "/Users/test/.cursor/extensions/anthropic.claude-code/claude") == .cursor)
        #expect(entry.startedAt == Date(timeIntervalSince1970: 1_794_542_242.234))
    }

    @Test func procStartGuardsAgainstPIDReuse() throws {
        let entry = try #require(ClaudeSessionRegistry.parse(agentFixture("claude_session_registry", "json")))
        let start = Date(timeIntervalSince1970: 1_794_542_240)  // Fri Nov 13 03:57:20 2026 UTC
        #expect(ClaudeSessionRegistry.matches(entry, processStart: start))
        #expect(ClaudeSessionRegistry.matches(entry, processStart: start.addingTimeInterval(1.5)))
        // Offsets no time zone can explain: a different process now owns the pid.
        #expect(!ClaudeSessionRegistry.matches(entry, processStart: start.addingTimeInterval(30)))
        #expect(!ClaudeSessionRegistry.matches(entry, processStart: start.addingTimeInterval(-90)))
    }

    @Test func fallsBackToStartedAtWithoutProcStart() throws {
        let entry = try #require(ClaudeSessionRegistry.parse(Data(#"{"pid":7,"sessionId":"abc","cwd":"/tmp","startedAt":1794542242234}"#.utf8)))
        #expect(ClaudeSessionRegistry.matches(entry, processStart: Date(timeIntervalSince1970: 1_794_542_240)))
        #expect(!ClaudeSessionRegistry.matches(entry, processStart: Date(timeIntervalSince1970: 1_794_542_300)))
    }

    @Test func rejectsIncompleteEntries() {
        #expect(ClaudeSessionRegistry.parse(Data(#"{"sessionId":"abc"}"#.utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(Data(#"{"pid":7}"#.utf8)) == nil)
        #expect(ClaudeSessionRegistry.parse(Data("garbage".utf8)) == nil)
    }

    @Test func loaderNeverReadsKeyFiles() throws {
        let root = try makeTempDir()
        let sessions = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try agentFixture("claude_session_registry", "json").write(to: sessions.appending(path: "4242.json"))
        try Data("SECRET-CANARY-key".utf8).write(to: sessions.appending(path: "4242.0123abcd.key"))

        var readPaths: [String] = []
        let entries = ClaudeSessionRegistry.load(root: root, read: { url in
            readPaths.append(url.path)
            return try? Data(contentsOf: url)
        })
        #expect(entries.map(\.pid) == [4242])
        #expect(readPaths.count == 1)
        #expect(!readPaths.contains { $0.hasSuffix(".key") })
    }

    @Test func rejectsUnsafeSessionIDs() {
        #expect(AgentCollector.isSafeSessionID("00000000-0000-4000-8000-000000000001"))
        #expect(!AgentCollector.isSafeSessionID("../../etc/passwd"))
        #expect(!AgentCollector.isSafeSessionID("a/b"))
        #expect(!AgentCollector.isSafeSessionID(""))
    }
}

// MARK: - Claude Code transcripts (AC4, AC5)

@Suite struct ClaudeTranscriptUsageTests {
    @Test func deduplicatesContentBlocksAndKeepsLastLine() throws {
        let usage = parseTranscript(try agentFixture("claude_transcript", "jsonl"))
        // msg_A spans 3 block lines; msg_B is written twice; <synthetic>, garbage and cost-state are skipped.
        #expect(usage.messages.count == 5)
        #expect(usage.messages["msg_B"]?.output == 800)
        #expect(usage.usage.tokens == TokenUsage(input: 2116, cacheRead: 41_000, cacheWrite: 1200, output: 2601, thinking: 100))
        #expect(usage.usage.tokens.total == 46_917)
        #expect(usage.lastModel == "claude-unknown-9")
    }

    @Test func splitsCacheWritesByTTL() throws {
        let usage = parseTranscript(try agentFixture("claude_transcript", "jsonl"))
        #expect(usage.messages["msg_A"]?.cacheWrite1h == 1000)
        #expect(usage.messages["msg_A"]?.cacheWrite5m == 0)
        #expect(usage.messages["msg_B"]?.cacheWrite5m == 200)  // no TTL split → priced as 5 m
        #expect(usage.messages["msg_C"]?.speed == "fast")
    }

    @Test func estimatesCostPerModel() throws {
        let usage = parseTranscript(try agentFixture("claude_transcript", "jsonl"))
        #expect(approx(usage.usage.cost.usd, 0.08756))
        #expect(usage.usage.cost.hasUnpricedUsage)  // claude-unknown-9
        let byModel = usage.byModel
        #expect(Set(byModel.keys) == ["claude-opus-5-5", "claude-haiku-4-5", "claude-unknown-9"])
        #expect(approx(byModel["claude-opus-5-5"]?.cost.usd ?? 0, 0.08406))
        #expect(approx(byModel["claude-haiku-4-5"]?.cost.usd ?? 0, 0.0035))
        #expect(byModel["claude-opus-5-5"]?.tokens.cacheWrite == 1200)
    }

    @Test func subagentTranscriptAndMeta() throws {
        let sub = parseTranscript(try agentFixture("claude_subagent", "jsonl"))
        #expect(sub.messages.count == 1)
        #expect(sub.usage.tokens.total == 1250)
        #expect(approx(sub.usage.cost.usd, 0.0086))
        let meta = try #require(ClaudeSubagentMeta.parse(agentFixture("claude_subagent.meta", "json")))
        #expect(meta.agentType == "Explore")
        #expect(meta.description == "Find usages of LimitWindow")
    }

    @Test func incrementalReadsMatchFullParse() throws {
        let data = try agentFixture("claude_transcript", "jsonl")
        let url = try makeTempDir().appending(path: "transcript.jsonl")
        // Cut in the middle of a line to exercise the partial-line buffer.
        let cut = (data[(data.count / 2)...].firstIndex(of: 0x0A) ?? data.count / 2) - 5
        try data.prefix(upTo: cut).write(to: url)

        var reader = TailReader()
        try reader.pump(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data.suffix(from: cut))
        try handle.close()
        try reader.pump(url)

        #expect(reader.usage.usage == parseTranscript(data).usage)
        #expect(reader.tail.offset == UInt64(data.count))
    }

    @Test func replacedFileResetsTotals() throws {
        let url = try makeTempDir().appending(path: "transcript.jsonl")
        try agentFixture("claude_transcript", "jsonl").write(to: url)
        var reader = TailReader()
        try reader.pump(url)
        #expect(reader.usage.messages.count == 5)

        let replacement = try agentFixture("claude_subagent", "jsonl")
        try FileManager.default.removeItem(at: url)
        try replacement.write(to: url)
        try reader.pump(url)
        #expect(reader.usage.usage == parseTranscript(replacement).usage)
    }
}

// MARK: - Codex rollouts (AC6)

@Suite struct CodexRolloutUsageTests {
    @Test func readsSessionMetaAndLatestModel() throws {
        let rollout = parseRollout(try agentFixture("codex_rollout", "jsonl"))
        #expect(rollout.sessionID == "019a0000-0000-7000-8000-000000000002")
        #expect(rollout.cwd == "/Users/test/Projects/sketch")
        #expect(rollout.originator == "codex_exec")
        #expect(rollout.cliVersion == "0.157.0")
        #expect(rollout.model == "gpt-5.6-terra")
        #expect(rollout.contextWindow == 258_400)
        #expect(rollout.startedAt == ISODate.parse("2026-11-10T02:11:30.736Z"))
        #expect(rollout.host(executablePath: "/opt/homebrew/bin/codex") == .exec)
        #expect(rollout.host(executablePath: "/Users/test/.vscode/extensions/openai.chatgpt/bin/codex") == .vscode)
    }

    @Test func lastTokenCountWinsAndTaskStateTracksWork() throws {
        let rollout = parseRollout(try agentFixture("codex_rollout", "jsonl"))
        #expect(rollout.totals == CodexTokenTotals(input: 20_000, cached: 15_000, cacheWrite: 0, output: 506, reasoning: 100))
        #expect(rollout.isWorking)  // task_started t2 follows task_complete t1
        #expect(rollout.usage.tokens == TokenUsage(input: 5000, cacheRead: 15_000, cacheWrite: 0, output: 506, thinking: 100))
        #expect(rollout.usage.tokens.total == 20_506)
    }

    @Test func attributesTokenDeltasToModels() throws {
        let rollout = parseRollout(try agentFixture("codex_rollout", "jsonl"))
        #expect(rollout.totalsByModel["gpt-6-luna"] == CodexTokenTotals(input: 13_693, cached: 10_880, cacheWrite: 0, output: 6, reasoning: 0))
        #expect(rollout.totalsByModel["gpt-5.6-terra"] == CodexTokenTotals(input: 6307, cached: 4120, cacheWrite: 0, output: 500, reasoning: 100))
        #expect(approx(rollout.usage.cost.usd, 0.000_393_1 + 0.011_198))
        #expect(!rollout.usage.cost.hasUnpricedUsage)
    }

    @Test func taskCompleteEndsWork() {
        var rollout = CodexRolloutUsage()
        rollout.consume(Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8))
        #expect(rollout.isWorking)
        rollout.consume(Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8))
        #expect(!rollout.isWorking)
    }

    @Test func assignsRolloutsToTheRightProcess() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let processes: [(pid: Int32, cwd: String, startedAt: Date)] = [
            (1, "/p", t0), (2, "/p", t0.addingTimeInterval(100)), (3, "/q", t0),
        ]
        let rollouts: [(path: String, cwd: String, startedAt: Date)] = [
            ("a", "/p", t0.addingTimeInterval(50)),   // only process 1 existed
            ("b", "/p", t0.addingTimeInterval(150)),  // latest-started process in /p
            ("c", "/q", t0.addingTimeInterval(10)),
            ("d", "/r", t0.addingTimeInterval(10)),   // no process in /r
        ]
        let result = CodexRolloutFinder.assign(rollouts: rollouts, processes: processes)
        #expect(result == [1: ["a"], 2: ["b"], 3: ["c"]])
    }
}

// MARK: - Privacy (AC7)

@Suite struct AgentPrivacyTests {
    @Test func secretContentNeverSurfaces() throws {
        let claude = parseTranscript(try agentFixture("claude_transcript", "jsonl"))
        let sub = parseTranscript(try agentFixture("claude_subagent", "jsonl"))
        let codex = parseRollout(try agentFixture("codex_rollout", "jsonl"))
        let registry = try #require(ClaudeSessionRegistry.parse(agentFixture("claude_session_registry", "json")))
        let surfaces = [String(reflecting: claude), String(reflecting: claude.byModel), String(reflecting: sub),
                        String(reflecting: codex), String(reflecting: codex.byModel), String(reflecting: registry)]
        for text in surfaces {
            #expect(!text.contains("SECRET-CANARY"))
        }
    }
}

// MARK: - Pricing (AC9)

@Suite struct ModelPricingTests {
    private func usd(_ usage: ClaudeMessageUsage) -> Double { usage.cost.usd }

    @Test func opus55StandardRates() {
        #expect(approx(usd(.init(model: "claude-opus-5-5", input: 1_000_000)), 4))
        #expect(approx(usd(.init(model: "claude-opus-5-5", output: 1_000_000)), 20))
        #expect(approx(usd(.init(model: "claude-opus-5-5", cacheRead: 1_000_000)), 0.20))
        #expect(approx(usd(.init(model: "claude-opus-5-5", cacheWrite5m: 1_000_000)), 5))
        #expect(approx(usd(.init(model: "claude-opus-5-5", cacheWrite1h: 1_000_000)), 8))
    }

    @Test func fastModeKeepsCacheMultipliers() {
        #expect(approx(usd(.init(model: "claude-opus-5-5", input: 1_000_000, speed: "fast")), 8))
        #expect(approx(usd(.init(model: "claude-opus-5-5", output: 1_000_000, speed: "fast")), 40))
        #expect(approx(usd(.init(model: "claude-opus-5-5", cacheRead: 1_000_000, speed: "fast")), 0.40))
        #expect(approx(usd(.init(model: "claude-opus-5-5", cacheWrite1h: 1_000_000, speed: "fast")), 16))
        #expect(approx(usd(.init(model: "claude-fable-5-2", output: 1_000_000, speed: "fast")), 80))
        #expect(approx(usd(.init(model: "claude-sonnet-5-5", input: 1_000_000, speed: "fast")), 2))  // no fast price
    }

    @Test func usInferenceCostsMoreOnModernModels() {
        #expect(approx(usd(.init(model: "claude-opus-5-5", input: 1_000_000, inferenceGeo: "us")), 4.4))
        #expect(approx(usd(.init(model: "claude-opus-5-5", input: 1_000_000, inferenceGeo: "global")), 4))
        #expect(approx(usd(.init(model: "claude-opus-4-5", input: 1_000_000, inferenceGeo: "us")), 5))
    }

    @Test func haiku55LongContextTier() {
        #expect(approx(usd(.init(model: "claude-haiku-5-5", input: 50_000, cacheRead: 50_000)), 0.0055))
        #expect(approx(usd(.init(model: "claude-haiku-5-5", input: 50_001, cacheRead: 50_000)), 0.027_500_5))
    }

    @Test func webSearchesAndUnknownModels() {
        #expect(approx(usd(.init(model: "claude-opus-5-5", webSearches: 3)), 0.03))
        let unknown = ClaudeMessageUsage(model: "claude-future-9", input: 10).cost
        #expect(unknown.hasUnpricedUsage && unknown.usd == 0)
        #expect(!ClaudeMessageUsage(model: "claude-future-9").cost.hasUnpricedUsage)
    }

    @Test func normalizesModelIDs() {
        #expect(ModelID.normalizedClaude("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(ModelID.normalizedClaude("claude-opus-5-5[1m]") == "claude-opus-5-5")
        #expect(ModelPricing.claude("claude-opus-5-5[1m]") != nil)
        #expect(ModelPricing.claude("claude-mythos-5-2") == ModelPricing.claude("claude-fable-5-2"))
    }

    @Test func codexCachedTokensAreASubsetOfInput() {
        let totals = CodexTokenTotals(input: 13_693, cached: 10_880, cacheWrite: 0, output: 6, reasoning: 0)
        #expect(approx(totals.cost(model: "gpt-6-luna").usd, 0.000_393_1))
        #expect(totals.tokens.total == 13_699)
        #expect(totals.cost(model: "gpt-reserve").hasUnpricedUsage)
        #expect(totals.cost(model: nil).hasUnpricedUsage)
    }
}

// MARK: - Processes (AC8)

@Suite struct ProcessTreeTests {
    private func entry(_ pid: Int32, _ ppid: Int32) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, uid: 501, startTime: .distantPast, command: "test")
    }

    @Test func cpuPercentFromTwoSamples() {
        #expect(ProcessTree.cpuPercent(previousNanos: 1_000_000_000, currentNanos: 1_500_000_000, elapsed: 2) == 25)
        #expect(ProcessTree.cpuPercent(previousNanos: 0, currentNanos: 4_000_000_000, elapsed: 2) == 200)
        #expect(ProcessTree.cpuPercent(previousNanos: 5, currentNanos: 1, elapsed: 2) == 0)
        #expect(ProcessTree.cpuPercent(previousNanos: 0, currentNanos: 10, elapsed: 0) == 0)
    }

    @Test func descendantsStopAtNestedAgents() {
        // 10 (agent) → 11 → 13; 10 → 12 → 20 (nested agent) → 21; 30 is orphaned.
        let table = [entry(10, 1), entry(11, 10), entry(12, 10), entry(13, 11), entry(20, 12), entry(21, 20), entry(30, 999)]
        let children = ProcessTree.children(table)
        #expect(Set(ProcessTree.descendants(of: 10, children: children, excluding: [10, 20])) == [11, 12, 13])
        #expect(Set(ProcessTree.descendants(of: 20, children: children, excluding: [10, 20])) == [21])
        #expect(ProcessTree.descendants(of: 30, children: children).isEmpty)
    }

    @Test func toleratesCycles() {
        let children = ProcessTree.children([entry(40, 41), entry(41, 40)])
        #expect(ProcessTree.descendants(of: 40, children: children) == [41])
        #expect(!ProcessTree.hasAncestor(50, in: [99], parents: [50: 51, 51: 50]))
    }

    @Test func detectsAncestors() {
        let parents: [Int32: Int32] = [11: 10, 10: 1, 21: 20, 20: 12, 12: 10]
        #expect(ProcessTree.hasAncestor(21, in: [10], parents: parents))
        #expect(!ProcessTree.hasAncestor(10, in: [20], parents: parents))
    }

    @Test func readsThisProcess() throws {
        let me = try #require(LibProc.entry(pid: getpid()))
        #expect(me.uid == getuid())
        #expect(me.startTime < Date())
        #expect((LibProc.resourceUsage(pid: getpid())?.footprint ?? 0) > 0)
        #expect(LibProc.executablePath(pid: getpid()) != nil)
        #expect(LibProc.workingDirectory(pid: getpid()) != nil)
        #expect(LibProc.allProcesses().contains { $0.pid == getpid() })
    }
}

// MARK: - Formatting

@Suite struct AgentFormatTests {
    @Test func compactTokens() {
        #expect(AgentFormat.tokens(950) == "950")
        #expect(AgentFormat.tokens(2100) == "2.1K")
        #expect(AgentFormat.tokens(14_000) == "14K")
        #expect(AgentFormat.tokens(812_000) == "812K")
        #expect(AgentFormat.tokens(999_999) == "1M")
        #expect(AgentFormat.tokens(3_400_000) == "3.4M")
        #expect(AgentFormat.tokens(24_100_000) == "24.1M")
        #expect(AgentFormat.tokens(1_200_000_000) == "1.2B")
    }

    @Test func costs() {
        #expect(AgentFormat.cost(CostEstimate(usd: 4.62)) == "$4.62")
        #expect(AgentFormat.cost(CostEstimate(usd: 0.004)) == "<$0.01")
        #expect(AgentFormat.cost(CostEstimate(usd: 4.12, hasUnpricedUsage: true)) == "$4.12+")
        #expect(AgentFormat.cost(CostEstimate(usd: 0, hasUnpricedUsage: true)) == "—")
        #expect(AgentFormat.cost(CostEstimate()) == "$0.00")
        #expect(AgentFormat.cost(CostEstimate(usd: 1234.6)) == "$1,235")
    }

    @Test func percentsBytesAndDurations() {
        #expect(AgentFormat.percent(19.66) == "19.7%")
        #expect(AgentFormat.percent(219.3) == "219%")
        #expect(AgentFormat.bytes(310 * 1_048_576) == "310 MB")
        #expect(AgentFormat.bytes(UInt64(1.6 * 1_073_741_824)) == "1.6 GB")
        #expect(AgentFormat.bytes(900 * 1024) == "900 KB")
        #expect(AgentFormat.duration(30) == "<1m")
        #expect(AgentFormat.duration(120) == "2m")
        #expect(AgentFormat.duration(2 * 3600 + 22 * 60) == "2h 22m")
        #expect(AgentFormat.duration(4 * 86400 + 2 * 3600) == "4d 2h")
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AgentFormat.ago(now.addingTimeInterval(-5), now: now) == "5s ago")
        #expect(AgentFormat.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3h ago")
    }

    @Test func dayAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Phoenix"))
        let now = try #require(ISODate.parse("2026-11-13T03:57:20Z"))  // Thu Nov 12, 20:57 local
        func format(_ iso: String) throws -> String {
            AgentFormat.dayTime(try #require(ISODate.parse(iso)), now: now, calendar: calendar)
        }
        #expect(try format("2026-11-13T03:57:20Z") == "today, 20:57")
        #expect(try format("2026-11-11T16:05:00Z") == "yesterday, 09:05")
        #expect(try format("2026-11-10T03:57:00Z") == "Mon Nov 9, 20:57")
        #expect(try format("2025-12-31T19:00:00Z") == "Wed Dec 31 2025, 12:00")
    }

    @Test func modelNames() {
        #expect(AgentFormat.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentFormat.modelName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(AgentFormat.modelName("claude-opus-4") == "Opus 4")
        #expect(AgentFormat.modelName("claude-fable-5-2") == "Fable 5.2")
        #expect(AgentFormat.modelName("claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(AgentFormat.modelName("claude-unknown-9") == "claude-unknown-9")
        #expect(AgentFormat.modelName("gpt-6-luna") == "gpt-6-luna")
    }
}

// MARK: - Monitor lifecycle (AC11)

private actor CountingCollector: AgentCollecting {
    private(set) var calls = 0
    private(set) var refreshes = 0

    func collect(refreshFiles: Bool) -> AgentSnapshot {
        calls += 1
        if refreshFiles { refreshes += 1 }
        return AgentSnapshot(rows: [], summary: AgentSummary(), collectedAt: Date())
    }
}

@MainActor @Suite struct AgentMonitorTests {
    @Test func stopHaltsCollection() async throws {
        let collector = CountingCollector()
        let monitor = AgentMonitor(collector: collector, interval: .milliseconds(10), fileRefreshEvery: 3)
        monitor.start()
        try await Task.sleep(for: .milliseconds(150))
        monitor.stop()

        let atStop = await collector.calls
        #expect(atStop >= 3)
        #expect(monitor.lastUpdated != nil)
        #expect(!monitor.isRunning)
        let refreshes = await collector.refreshes
        #expect(refreshes >= 1 && refreshes < atStop)

        try await Task.sleep(for: .milliseconds(150))
        #expect(await collector.calls == atStop)
    }
}

// MARK: - Collector end to end (AC2, AC4)

@Suite struct AgentCollectorTests {
    /// Registers this test process as a fake Claude Code session in a temporary `~/.claude`.
    @Test func mapsRegistryTranscriptAndSubagents() async throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        let me = try #require(LibProc.entry(pid: getpid()))
        let sessionID = "11111111-2222-4333-8444-555555555555"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let procStart = formatter.string(from: me.startTime)

        let sessions = root.appending(path: "sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let live: [String: Any] = ["pid": Int(getpid()), "sessionId": sessionID, "cwd": "/Users/test/Projects/headroom",
                                   "procStart": procStart, "entrypoint": "cli", "status": "idle", "name": "Collector test"]
        try JSONSerialization.data(withJSONObject: live).write(to: sessions.appending(path: "\(getpid()).json"))
        let dead: [String: Any] = ["pid": 999_999, "sessionId": "22222222-2222-4333-8444-555555555555", "cwd": "/tmp", "procStart": procStart]
        try JSONSerialization.data(withJSONObject: dead).write(to: sessions.appending(path: "999999.json"))
        try Data("SECRET-CANARY-key".utf8).write(to: sessions.appending(path: "\(getpid()).0123abcd.key"))

        let project = root.appending(path: "projects/-Users-test-Projects-headroom")
        let subagents = project.appending(path: "\(sessionID)/subagents")
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
        try agentFixture("claude_transcript", "jsonl").write(to: project.appending(path: "\(sessionID).jsonl"))
        try agentFixture("claude_subagent", "jsonl").write(to: subagents.appending(path: "agent-abc123.jsonl"))
        try agentFixture("claude_subagent.meta", "json").write(to: subagents.appending(path: "agent-abc123.meta.json"))

        let collector = AgentCollector(claudeRoot: root, codexRoot: root.appending(path: "no-codex"))
        let quick = await collector.collect(refreshFiles: false)
        #expect(try #require(quick.rows.first { $0.pid == getpid() }).usage == .loading)

        let snapshot = await collector.collect(refreshFiles: true)
        #expect(!snapshot.rows.contains { $0.pid == 999_999 })
        let row = try #require(snapshot.rows.first { $0.pid == getpid() })
        #expect(row.kind == .claudeCode)
        let session = try #require(row.sessions.first)
        #expect(session.title == "Collector test")
        #expect(session.host == .cli)
        #expect(session.status == .idle(since: nil))
        let usage = try #require(session.usage.loaded)
        #expect(usage.tokens.total == 46_917 + 1250)
        #expect(approx(usage.cost.usd, 0.08756 + 0.0086))
        #expect(session.subagents.map(\.agentType) == ["Explore"])
        #expect(session.byModel["claude-fable-5-2"]?.tokens.total == 1250)
        #expect(!String(reflecting: snapshot.rows).contains("SECRET-CANARY"))
    }
}

// MARK: - Hardening (security review findings)

@Suite struct AgentHardeningTests {
    @Test func registryWithoutStartTimesNeverMatches() throws {
        let entry = try #require(ClaudeSessionRegistry.parse(Data(#"{"pid":7,"sessionId":"abc","cwd":"/tmp"}"#.utf8)))
        #expect(!ClaudeSessionRegistry.matches(entry, processStart: Date()))
        let garbled = try #require(ClaudeSessionRegistry.parse(Data(#"{"pid":7,"sessionId":"abc","procStart":"soon","startedAt":"now"}"#.utf8)))
        #expect(!ClaudeSessionRegistry.matches(garbled, processStart: Date()))
    }

    @Test func impossibleTimestampsAreDropped() throws {
        let json = #"{"pid":7,"sessionId":"abc","status":"idle","statusUpdatedAt":1e300,"startedAt":-5}"#
        let entry = try #require(ClaudeSessionRegistry.parse(Data(json.utf8)))
        #expect(entry.statusUpdatedAt == nil)
        #expect(entry.startedAt == nil)
        #expect(AgentFormat.duration(-1e297) == "—")
        #expect(AgentFormat.duration(.nan) == "—")
        #expect(AgentFormat.ago(Date(timeIntervalSince1970: 1e300), now: Date()) == "—")
    }

    @Test func hugeAndNegativeTokenCountsAreClamped() {
        var usage = ClaudeTranscriptUsage()
        usage.consume(Data(#"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":9223372036854775807,"output_tokens":-1000005,"cache_creation_input_tokens":9223372036854775807,"cache_creation":{"ephemeral_5m_input_tokens":9223372036854775807}}}}"#.utf8))
        usage.consume(Data(#"{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":5000000000000000000}}}"#.utf8))
        let tokens = usage.usage.tokens
        #expect(tokens.input == 2 * TokenCount.maxValue)
        #expect(tokens.output == 0)
        #expect(tokens.cacheWrite == TokenCount.maxValue)
        #expect(tokens.total > 0)
        #expect(usage.usage.cost.usd >= 0)

        var codex = CodexRolloutUsage()
        codex.consume(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":-2,"output_tokens":-7}}}}"#.utf8))
        codex.consume(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9223372036854775807}}}}"#.utf8))
        #expect(codex.totals.input == TokenCount.maxValue)
        #expect(codex.totals.output == 0)
    }

    @Test func sumsSaturateInsteadOfTrapping() {
        let big = TokenUsage(input: .max, cacheRead: .max, cacheWrite: .max, output: .max)
        #expect((big + big).input == .max)
        #expect(big.total == .max)
        #expect(Int.max.saturatingAdd(1) == .max)
        #expect(Int.min.saturatingAdd(-1) == .min)
    }

    @Test func refusesSymlinksAndFIFOs() throws {
        let dir = try makeTempDir()
        let fifo = dir.appending(path: "pipe.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let link = dir.appending(path: "link.jsonl")
        let target = dir.appending(path: "target.jsonl")
        try agentFixture("claude_transcript", "jsonl").write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        var tail = JSONLTail()
        var usage = ClaudeTranscriptUsage()
        #expect(throws: (any Error).self) { try tail.drain(fifo, into: &usage) }  // returns at once: no blocking open
        #expect(throws: (any Error).self) { try tail.drain(link, into: &usage) }
        #expect(RegularFile.contents(of: link, maxBytes: 1 << 20) == nil)
        #expect(RegularFile.contents(of: fifo, maxBytes: 1 << 20) == nil)
        #expect(usage.messages.isEmpty)
    }

    @Test func smallFileReadsAreCapped() throws {
        let url = try makeTempDir().appending(path: "big.json")
        try Data(repeating: 0x20, count: 70_000).write(to: url)
        #expect(RegularFile.contents(of: url, maxBytes: 64 << 10) == nil)
        #expect(RegularFile.head(of: url, maxBytes: 100)?.count == 100)
    }

    @Test func chunkedReadsMatchAFullParse() throws {
        let data = try agentFixture("claude_transcript", "jsonl")
        let url = try makeTempDir().appending(path: "transcript.jsonl")
        try data.write(to: url)
        var tail = JSONLTail(chunkSize: 37)
        var usage = ClaudeTranscriptUsage()
        try tail.drain(url, into: &usage)
        #expect(usage.usage == parseTranscript(data).usage)
    }

    @Test func oversizedLinesAreSkipped() throws {
        let url = try makeTempDir().appending(path: "lines.jsonl")
        try Data((String(repeating: "x", count: 200) + "\nok-1\nok-2\n").utf8).write(to: url)
        var tail = JSONLTail(chunkSize: 16, maxLineBytes: 64)
        var collector = LineCollector()
        try tail.drain(url, into: &collector)
        #expect(collector.lines == ["ok-1", "ok-2"])

        // Unchanged file: nothing is re-read or reset.
        try tail.drain(url, into: &collector)
        #expect(collector.resets == 1)
        #expect(collector.lines.count == 2)
    }
}
