import Foundation

/// One running Claude Code session from `~/.claude/sessions/<pid>.json`.
struct ClaudeRegistryEntry: Sendable, Hashable {
    let pid: Int32
    let sessionID: String
    let cwd: String
    let startedAt: Date?
    let procStart: String?
    let version: String?
    let kind: String?
    let entrypoint: String?
    let title: String?
    let status: String?
    let statusUpdatedAt: Date?
}

enum ClaudeSessionRegistry {
    static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// Lists `*.json` only. The folder also holds `<pid>.<hash>.key` socket secrets, which are never read.
    /// Entries are small; anything over 64 KB, a symlink or a non-regular file is skipped.
    static func load(root: URL,
                     list: (URL) -> [URL] = { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] },
                     read: (URL) -> Data? = { RegularFile.contents(of: $0, maxBytes: 64 << 10) }) -> [ClaudeRegistryEntry] {
        list(root.appending(path: "sessions"))
            .filter { $0.pathExtension == "json" }
            .compactMap { read($0).flatMap(parse) }
    }

    static func parse(_ data: Data) -> ClaudeRegistryEntry? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let pid = raw.pid, pid > 0, let sessionID = raw.sessionId, !sessionID.isEmpty else { return nil }
        return ClaudeRegistryEntry(
            pid: pid, sessionID: sessionID, cwd: raw.cwd ?? "",
            startedAt: date(milliseconds: raw.startedAt),
            procStart: raw.procStart, version: raw.version, kind: raw.kind, entrypoint: raw.entrypoint,
            title: raw.name.flatMap { $0.isEmpty ? nil : $0 }, status: raw.status,
            statusUpdatedAt: date(milliseconds: raw.statusUpdatedAt))
    }

    /// Rejects values a real timestamp can't have, so later date math can't trap.
    private static func date(milliseconds: Double?) -> Date? {
        guard let ms = milliseconds, ms.isFinite, ms > 0, ms < 32_503_680_000_000 else { return nil }  // before year 3000
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Guards against PID reuse: the live process must be the one that wrote the entry.
    static func matches(_ entry: ClaudeRegistryEntry, processStart: Date) -> Bool {
        if let text = entry.procStart {
            let candidates = parseProcStart(text)
            if !candidates.isEmpty {
                return candidates.contains { abs($0.timeIntervalSince(processStart)) <= 2 }
            }
        }
        // A reused pid always starts after the entry was written, so a registration time is enough.
        if let startedAt = entry.startedAt { return startedAt.timeIntervalSince(processStart) >= -2 }
        return false  // no start-time evidence: never attach an entry to an arbitrary process
    }

    /// `Fri Nov 13 03:57:20 2026`, read as UTC and as local time (the writer's zone isn't recorded).
    static func parseProcStart(_ text: String) -> [Date] {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return [TimeZone(identifier: "UTC")!, .current].compactMap { zone in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return formatter.date(from: normalized)
        }
    }

    private struct Raw: Decodable {
        let pid: Int32?
        let sessionId: String?
        let cwd: String?
        let startedAt: Double?
        let procStart: String?
        let version: String?
        let kind: String?
        let entrypoint: String?
        let name: String?
        let status: String?
        let statusUpdatedAt: Double?

        enum CodingKeys: String, CodingKey {
            case pid, sessionId, cwd, startedAt, procStart, version, kind, entrypoint, name, status, statusUpdatedAt
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = c.lenient(.pid)
            sessionId = c.lenient(.sessionId)
            cwd = c.lenient(.cwd)
            startedAt = c.lenient(.startedAt)
            procStart = c.lenient(.procStart)
            version = c.lenient(.version)
            kind = c.lenient(.kind)
            entrypoint = c.lenient(.entrypoint)
            name = c.lenient(.name)
            status = c.lenient(.status)
            statusUpdatedAt = c.lenient(.statusUpdatedAt)
        }
    }
}

extension ClaudeRegistryEntry {
    var agentStatus: AgentStatus {
        switch status {
        case "busy": .working
        case "idle": .idle(since: statusUpdatedAt)
        case let other?: .other(other.capitalized)
        case nil: .unknown
        }
    }

    func host(executablePath: String?) -> AgentHost {
        let path = executablePath ?? ""
        if path.contains("/.cursor/extensions/") { return .cursor }
        switch entrypoint {
        case "claude-desktop": return .desktop
        case "claude-vscode": return .vscode
        case "claude-jetbrains": return .jetbrains
        case "cli": return .cli
        case let value? where value.hasPrefix("sdk"): return .sdk
        case let value?: return .other(value)
        case nil:
            if path.contains("/Application Support/Claude/") { return .desktop }
            if path.contains("/.vscode/extensions/") { return .vscode }
            return .cli
        }
    }
}
