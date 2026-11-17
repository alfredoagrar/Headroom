import Foundation
import Testing

/// Opt-in checks against this Mac's real `~/.claude` and `~/.codex` (AC12, AC13).
/// Run with `TEST_RUNNER_HEADROOM_LIVE_TESTS=1 xcodebuild … test`. Prints counts only — never ids or content.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HEADROOM_LIVE_TESTS"] == "1"))
struct AgentLiveTests {
    @Test func listsRunningAgents() async throws {
        let collector = AgentCollector()
        _ = await collector.collect(refreshFiles: false)
        try await Task.sleep(for: .seconds(2))

        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = await collector.collect(refreshFiles: true)
        let firstScan = clock.now - start
        start = clock.now
        _ = await collector.collect(refreshFiles: true)
        let incremental = clock.now - start

        print("[live] rows \(snapshot.rows.count) · first scan \(firstScan) · incremental \(incremental)")
        for row in snapshot.rows.sorted(by: { $0.pid < $1.pid }) {
            let usage = row.usage.loaded
            let tokens = usage.map { "in \($0.tokens.input) out \($0.tokens.output) cr \($0.tokens.cacheRead) cw \($0.tokens.cacheWrite)" } ?? "\(row.usage)"
            print("[live] pid \(row.pid) \(row.kind.displayName) · \(row.host?.displayName ?? "?") · \(row.status) · cpu \(row.cpuPercent.map(AgentFormat.percent) ?? "—") · mem \(AgentFormat.bytes(row.memoryBytes)) · children \(row.childCount) · \(tokens) · \(usage.map { AgentFormat.cost($0.cost) } ?? "")")
        }

        let registered = ClaudeSessionRegistry.load(root: ClaudeSessionRegistry.defaultRoot)
        #expect(snapshot.rows.filter { $0.kind == .claudeCode && !$0.sessions.isEmpty }.count <= registered.count)
        #expect(incremental < .milliseconds(200))
    }

    @Test func scansLargeTranscriptQuickly() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "headroom-large-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        // ~30 MB: assistant lines with large content blocks, interleaved with tool results.
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 40)
        var data = Data()
        var index = 0
        while data.count < 30_000_000 {
            let assistant = #"{"type":"assistant","message":{"id":"msg_\#(index / 3)","model":"claude-opus-5-5","content":[{"type":"text","text":"\#(filler)"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":500,"cache_read_input_tokens":90000,"output_tokens":400}},"uuid":"a\#(index)"}"#
            let user = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\#(filler)"}]},"uuid":"u\#(index)"}"#
            data.append(Data((assistant + "\n" + user + "\n").utf8))
            index += 1
        }
        try data.write(to: url)

        let clock = ContinuousClock()
        let start = clock.now
        var tail = JSONLTail()
        var usage = ClaudeTranscriptUsage()
        try tail.drain(url, into: &usage)
        let elapsed = clock.now - start

        print("[live] \(data.count / 1_000_000) MB, \(usage.messages.count) responses in \(elapsed)")
        #expect(usage.messages.count == (index + 2) / 3)
        #if !DEBUG
        #expect(elapsed < .seconds(1))
        #endif
    }
}
