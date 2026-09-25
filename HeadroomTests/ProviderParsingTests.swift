import Foundation
import Testing

private final class BundleToken {}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

private func date(_ iso: String) -> Date { ISODate.parse(iso)! }

@Suite struct ClaudeParsingTests {
    let creds = ClaudeCredentials(accessToken: "x", expiresAt: nil, subscriptionType: "pro", rateLimitTier: "default_claude_ai")

    @Test func parsesNormalizedLimits() throws {
        let snap = try ClaudeUsageParser.parse(fixture("claude_usage"), credentials: creds)
        #expect(snap.planName == "Pro")
        #expect(snap.windows.map(\.label) == ["Sesión (5h)", "Semanal"])
        #expect(snap.windows.map(\.kind) == [.session, .weekly])
        #expect(snap.windows.map(\.usedPercent) == [12, 2])
        let reset = try #require(snap.windows[0].resetsAt)
        #expect(abs(reset.timeIntervalSince(date("2026-09-25T19:29:59Z"))) < 1)
    }

    @Test func includesExtraCreditsAndBreakdown() throws {
        let snap = try ClaudeUsageParser.parse(fixture("claude_usage"), credentials: creds)
        let extra = try #require(snap.details.first { $0.label.hasPrefix("Créditos extra") })
        #expect(extra.value.contains("21.11") || extra.value.contains("21,11"))
        #expect(snap.details.contains(DetailRow(label: "Semanal · Chats", value: "38%")))
        #expect(!snap.details.contains { $0.label == "Semanal · Cowork" })
    }

    @Test func fallsBackToLegacyWindows() throws {
        let json = #"{"five_hour":{"utilization":50,"resets_at":"2026-09-25T19:29:59+00:00"},"seven_day":{"utilization":10,"resets_at":null},"seven_day_opus":null}"#
        let snap = try ClaudeUsageParser.parse(Data(json.utf8), credentials: nil)
        #expect(snap.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(snap.windows[1].resetsAt == nil)
    }

    @Test(arguments: [
        ("weekly_all", "weekly", "Semanal"),
        ("weekly_opus", "weekly", "Semanal · Opus"),
        ("session", "session", "Sesión (5h)"),
    ])
    func describesLimitKinds(kind: String, group: String, label: String) {
        #expect(ClaudeUsageParser.describe(kind: kind, group: group).1 == label)
    }

    @Test func detectsMaxPlans() {
        let max = ClaudeCredentials(accessToken: "x", expiresAt: nil, subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        #expect(ClaudeUsageParser.planName(max) == "Max 20x")
    }

    @Test func ignoresEmptyKeychainTokens() {
        let empty = #"{"claudeAiOauth":{"accessToken":"","expiresAt":0,"subscriptionType":"pro"}}"#
        #expect(ClaudeCredentials.decode(Data(empty.utf8)) == nil)
        let ok = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1790391695821}}"#
        #expect(ClaudeCredentials.decode(Data(ok.utf8))?.expiresAt == Date(timeIntervalSince1970: 1790391695.821))
    }
}

@Suite struct CodexParsingTests {
    @Test func parsesFreePlanMonthlyWindow() throws {
        let snap = try CodexUsageParser.parse(fixture("codex_usage"))
        #expect(snap.planName == "Free")
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].kind == .monthly)
        #expect(snap.windows[0].label == "Mensual")
        #expect(snap.windows[0].resetsAt == Date(timeIntervalSince1970: 1792954931))
    }

    @Test func parsesPlusPlanSessionAndWeekly() throws {
        let json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":96,"limit_window_seconds":18000,"reset_after_seconds":2280},"secondary_window":{"used_percent":52,"limit_window_seconds":604800,"reset_at":1792954931}}}"#
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snap = try CodexUsageParser.parse(Data(json.utf8), now: now)
        #expect(snap.windows.map(\.label) == ["Sesión (5h)", "Semanal"])
        #expect(snap.windows[0].resetsAt == now.addingTimeInterval(2280))
        #expect(snap.maxUsedPercent == 96)
    }
}

@Suite struct CoreTests {
    @Test func windowKindsByDuration() {
        #expect(WindowKind(seconds: 18000) == .session)
        #expect(WindowKind(seconds: 86400) == .daily)
        #expect(WindowKind(seconds: 604800) == .weekly)
        #expect(WindowKind(seconds: 2592000) == .monthly)
    }

    @Test func resetCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ResetFormatter.short(until: now.addingTimeInterval(4 * 86400 + 3 * 3600 + 100), now: now) == "4d 3h")
        #expect(ResetFormatter.short(until: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now) == "2h 14m")
        #expect(ResetFormatter.short(until: now.addingTimeInterval(38 * 60 + 5), now: now) == "38m")
        #expect(ResetFormatter.short(until: now.addingTimeInterval(-5), now: now) == "ahora")
    }

    @Test func absoluteResetDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Phoenix")!
        let now = date("2026-09-25T18:00:00Z")  // vie 25 sep, 11:00 local
        #expect(ResetFormatter.absolute(date("2026-09-25T19:29:59Z"), now: now, calendar: cal) == "hoy, 12:29")
        #expect(ResetFormatter.absolute(date("2026-09-26T16:05:00Z"), now: now, calendar: cal) == "mañana, 09:05")
        #expect(ResetFormatter.absolute(date("2026-10-01T19:59:59Z"), now: now, calendar: cal) == "jue 1 oct, 12:59")
        #expect(ResetFormatter.absolute(date("2027-01-04T19:00:00Z"), now: now, calendar: cal) == "lun 4 ene 2027, 12:00")
    }

    @Test func severityThresholds() {
        #expect(Severity(percent: 74) == .normal)
        #expect(Severity(percent: 75) == .warning)
        #expect(Severity(percent: 96) == .critical)
    }

    @Test func decodesJWTExpiry() {
        let payload = Data(#"{"exp":1790000000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        #expect(JWT.expiry(of: "h.\(payload).s") == Date(timeIntervalSince1970: 1790000000))
    }
}
