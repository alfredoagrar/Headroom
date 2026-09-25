import Foundation

struct CodexCredentials: Sendable {
    let accessToken: String
    let accountID: String?
    let expiresAt: Date?

    static var authFile: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: home).appending(path: "auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    }

    static func decode(_ data: Data) -> CodexCredentials? {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String?; let account_id: String? }
            let tokens: Tokens?
        }
        guard let tokens = (try? JSONDecoder().decode(Auth.self, from: data))?.tokens,
              let token = tokens.access_token, !token.isEmpty else { return nil }
        return CodexCredentials(accessToken: token, accountID: tokens.account_id, expiresAt: JWT.expiry(of: token))
    }

    static func loadFromCodexCLI() -> CodexCredentials? {
        (try? Data(contentsOf: authFile)).flatMap(decode)
    }
}

struct CodexProvider: UsageProvider {
    let id = ProviderID.codex
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetchUsage() async throws(ProviderError) -> UsageSnapshot {
        guard let creds = CodexCredentials.loadFromCodexCLI() else {
            throw .notConfigured(hint: "Ejecuta `codex login` en la terminal.")
        }
        let renewHint = "Abre Codex o ejecuta `codex login`."
        if let expiresAt = creds.expiresAt, expiresAt < .now { throw .expired(hint: renewHint) }

        var headers = ["Authorization": "Bearer \(creds.accessToken)"]
        if let account = creds.accountID { headers["ChatGPT-Account-Id"] = account }
        let data: Data
        do {
            data = try await HTTPClient.get(Self.endpoint, headers: headers)
        } catch .unauthorized {
            throw .expired(hint: renewHint)
        }
        return try CodexUsageParser.parse(data)
    }
}

enum CodexUsageParser {
    private struct Response: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let limitWindowSeconds: Int?
            let resetAfterSeconds: Int?
            let resetAt: Double?
        }
        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
        }
        struct Credits: Decodable { let hasCredits: Bool?; let unlimited: Bool? }
        let planType: String?
        let rateLimit: RateLimit?
        let codeReviewRateLimit: RateLimit?
        let credits: Credits?
    }

    static func parse(_ data: Data, now: Date = .now) throws(ProviderError) -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let r: Response
        do { r = try decoder.decode(Response.self, from: data) } catch {
            throw .decoding(String(describing: error))
        }

        func window(_ w: Response.Window?, id: String, prefix: String = "") -> LimitWindow? {
            guard let w else { return nil }
            let seconds = w.limitWindowSeconds ?? 0
            let resetsAt = w.resetAt.map { Date(timeIntervalSince1970: $0) }
                ?? w.resetAfterSeconds.map { now.addingTimeInterval(Double($0)) }
            return LimitWindow(id: id, kind: WindowKind(seconds: seconds),
                               label: prefix + WindowKind.label(seconds: seconds),
                               usedPercent: w.usedPercent, resetsAt: resetsAt)
        }

        let windows = [
            window(r.rateLimit?.primaryWindow, id: "primary"),
            window(r.rateLimit?.secondaryWindow, id: "secondary"),
            window(r.codeReviewRateLimit?.primaryWindow, id: "code_review_primary", prefix: "Code review · "),
            window(r.codeReviewRateLimit?.secondaryWindow, id: "code_review_secondary", prefix: "Code review · "),
        ].compactMap { $0 }

        var details: [DetailRow] = []
        if r.credits?.unlimited == true {
            details.append(DetailRow(label: "Créditos", value: "Ilimitados"))
        } else if r.credits?.hasCredits == true {
            details.append(DetailRow(label: "Créditos", value: "Disponibles"))
        }

        return UsageSnapshot(provider: .codex, planName: r.planType?.capitalized,
                             windows: windows, details: details, fetchedAt: now)
    }
}
