import Foundation

struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    /// Formato de Claude Code: `{"claudeAiOauth": {accessToken, expiresAt (ms), subscriptionType, rateLimitTier}}`.
    static func decode(_ data: Data) -> ClaudeCredentials? {
        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let accessToken: String?
                let expiresAt: Double?
                let subscriptionType: String?
                let rateLimitTier: String?
            }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Envelope.self, from: data))?.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: oauth.expiresAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil },
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    static func loadFromClaudeCode() -> ClaudeCredentials? {
        if let data = KeychainCLI.readPassword(service: "Claude Code-credentials"), let creds = decode(data) {
            return creds
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        return (try? Data(contentsOf: file)).flatMap(decode)
    }
}

struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetchUsage() async throws(ProviderError) -> UsageSnapshot {
        guard let creds = ClaudeCredentials.loadFromClaudeCode() else {
            throw .notConfigured(hint: "Ejecuta `claude auth login` en la terminal.")
        }
        let renewHint = "Abre Claude Code para renovarla."
        if let expiresAt = creds.expiresAt, expiresAt < .now { throw .expired(hint: renewHint) }

        let data: Data
        do {
            data = try await HTTPClient.get(Self.endpoint, headers: [
                "Authorization": "Bearer \(creds.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
        } catch .unauthorized {
            throw .expired(hint: renewHint)
        }
        return try ClaudeUsageParser.parse(data, credentials: creds)
    }
}

enum ClaudeUsageParser {
    private struct Response: Decodable {
        struct Window: Decodable { let utilization: Double?; let resetsAt: String? }
        struct Limit: Decodable {
            let kind: String
            let group: String?
            let percent: Double
            let resetsAt: String?
        }
        struct ExtraUsage: Decodable {
            let isEnabled: Bool?
            let monthlyLimit: Double?
            let usedCredits: Double?
            let currency: String?
            let decimalPlaces: Int?
            let creditsEverEnabled: Bool?
        }
        struct Breakdown: Decodable {
            struct Row: Decodable { let displayName: String; let percent: Double }
            let rows: [Row]
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let limits: [Limit]?
        let extraUsage: ExtraUsage?
        let sevenDayBreakdown: Breakdown?
    }

    static func parse(_ data: Data, credentials: ClaudeCredentials?, now: Date = .now) throws(ProviderError) -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let r: Response
        do { r = try decoder.decode(Response.self, from: data) } catch {
            throw .decoding(String(describing: error))
        }

        var windows: [LimitWindow]
        if let limits = r.limits, !limits.isEmpty {
            // `limits[]` es la lista normalizada; incluye ventanas nuevas sin cambiar el parser.
            windows = limits.map { limit in
                let (kind, label) = describe(kind: limit.kind, group: limit.group)
                return LimitWindow(id: limit.kind, kind: kind, label: label,
                                   usedPercent: limit.percent, resetsAt: ISODate.parse(limit.resetsAt))
            }
        } else {
            let legacy: [(String, WindowKind, String, Response.Window?)] = [
                ("five_hour", .session, "Sesión (5h)", r.fiveHour),
                ("seven_day", .weekly, "Semanal", r.sevenDay),
                ("seven_day_opus", .weekly, "Semanal · Opus", r.sevenDayOpus),
                ("seven_day_sonnet", .weekly, "Semanal · Sonnet", r.sevenDaySonnet),
            ]
            windows = legacy.compactMap { id, kind, label, window in
                guard let window, let used = window.utilization else { return nil }
                return LimitWindow(id: id, kind: kind, label: label, usedPercent: used, resetsAt: ISODate.parse(window.resetsAt))
            }
        }

        var details: [DetailRow] = []
        if let extra = r.extraUsage, extra.isEnabled == true || extra.creditsEverEnabled == true,
           let used = extra.usedCredits, let limit = extra.monthlyLimit {
            let scale = pow(10, Double(extra.decimalPlaces ?? 2))
            let style = FloatingPointFormatStyle<Double>.Currency(code: extra.currency ?? "USD")
            let state = extra.isEnabled == true ? "" : " (desactivados)"
            details.append(DetailRow(label: "Créditos extra\(state)",
                                     value: "\((used / scale).formatted(style)) / \((limit / scale).formatted(style))"))
        }
        for row in r.sevenDayBreakdown?.rows ?? [] where row.percent > 0 {
            details.append(DetailRow(label: "Semanal · \(row.displayName)", value: "\(Int(row.percent))%"))
        }

        return UsageSnapshot(provider: .claude, planName: credentials.flatMap(planName),
                             windows: windows, details: details, fetchedAt: now)
    }

    static func describe(kind: String, group: String?) -> (WindowKind, String) {
        switch group ?? kind {
        case "session": return (.session, "Sesión (5h)")
        case "daily": return (.daily, "Diario")
        case "weekly":
            let scope = kind.replacingOccurrences(of: "weekly_", with: "")
            return (.weekly, scope == "all" || scope == kind ? "Semanal" : "Semanal · \(scope.capitalized)")
        default:
            return (.other, kind.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    static func planName(_ creds: ClaudeCredentials) -> String? {
        let tier = creds.rateLimitTier ?? ""
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        return creds.subscriptionType?.capitalized
    }
}
