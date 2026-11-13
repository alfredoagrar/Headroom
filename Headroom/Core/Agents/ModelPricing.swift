import Foundation

/// USD per million tokens.
struct ClaudeRates: Sendable, Hashable {
    let input: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double
    let output: Double
}

struct ClaudeModelPrice: Sendable, Hashable {
    let standard: ClaudeRates
    /// Fast-mode input/output; cache rates keep the model's multipliers on top.
    let fastInput: Double?
    let fastOutput: Double?
    /// Haiku 5.5 prices prompts over 100K tokens at a higher row.
    let longContext: ClaudeRates?
    let longContextThreshold: Int?
    /// US-only inference costs 1.1× on Claude 4.6 and later.
    let usInferenceMultiplier: Bool
}

/// USD per million tokens.
struct OpenAIRates: Sendable, Hashable {
    let input: Double
    let cachedInput: Double
    let output: Double
}

enum ModelID {
    /// Strips date suffixes (`-20251001`) and bracketed variants (`[1m]`).
    static func normalizedClaude(_ id: String) -> String {
        var model = id.lowercased()
        if let bracket = model.firstIndex(of: "[") { model = String(model[..<bracket]) }
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) { model.removeSubrange(range) }
        return model
    }
}

/// Public API list prices, from platform.claude.com/docs/en/about-claude/pricing and
/// developers.openai.com/api/docs/pricing. Update `asOf` with any change.
enum ModelPricing {
    static let asOf = "2026-11-12"
    static let webSearchUSDPerRequest = 0.01
    static let usInferenceFactor = 1.1

    static func claude(_ model: String) -> ClaudeModelPrice? { claudeTable[ModelID.normalizedClaude(model)] }
    static func openAI(_ model: String) -> OpenAIRates? { openAITable[model.lowercased()] }

    private static func rates(_ input: Double, _ write5m: Double, _ write1h: Double, _ read: Double, _ output: Double) -> ClaudeRates {
        ClaudeRates(input: input, cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: read, output: output)
    }

    private static func price(_ standard: ClaudeRates, fast: (Double, Double)? = nil, modern: Bool = true) -> ClaudeModelPrice {
        ClaudeModelPrice(standard: standard, fastInput: fast?.0, fastOutput: fast?.1,
                         longContext: nil, longContextThreshold: nil, usInferenceMultiplier: modern)
    }

    private static let claudeTable: [String: ClaudeModelPrice] = {
        let fable52 = price(rates(8, 10, 16, 0.20, 40), fast: (16, 80))
        let fable51 = price(rates(10, 12.50, 20, 0.25, 50))
        let opus5 = price(rates(5, 6.25, 10, 0.50, 25), fast: (10, 50))
        let opus4x = price(rates(5, 6.25, 10, 0.50, 25))
        let opus4Legacy = price(rates(15, 18.75, 30, 1.50, 75), modern: false)
        let sonnet4x = price(rates(3, 3.75, 6, 0.30, 15))
        let sonnet4Legacy = price(rates(3, 3.75, 6, 0.30, 15), modern: false)
        let haiku55 = ClaudeModelPrice(standard: rates(0.10, 0.125, 0.20, 0.01, 0.50), fastInput: nil, fastOutput: nil,
                                       longContext: rates(0.50, 0.625, 1, 0.05, 2.50), longContextThreshold: 100_000,
                                       usInferenceMultiplier: true)
        return [
            "claude-fable-5-2": fable52,
            "claude-mythos-5-2": fable52,
            "claude-fable-5-1": fable51,
            "claude-mythos-5-1": fable51,
            "claude-fable-5": price(rates(10, 12.50, 20, 1.00, 50)),
            "claude-opus-5-5": price(rates(4, 5, 8, 0.20, 20), fast: (8, 40)),
            "claude-opus-5": opus5,
            "claude-opus-4-8": opus5,
            "claude-opus-4-7": opus4x,
            "claude-opus-4-6": opus4x,
            "claude-opus-4-5": price(rates(5, 6.25, 10, 0.50, 25), modern: false),
            "claude-opus-4-1": opus4Legacy,
            "claude-opus-4": opus4Legacy,
            "claude-sonnet-5-5": price(rates(2, 2.50, 4, 0.10, 10)),
            "claude-sonnet-5": price(rates(2, 2.50, 4, 0.20, 10)),
            "claude-sonnet-4-6": sonnet4x,
            "claude-sonnet-4-5": sonnet4Legacy,
            "claude-sonnet-4": sonnet4Legacy,
            "claude-haiku-5-5": haiku55,
            "claude-haiku-4-5": price(rates(1, 1.25, 2, 0.10, 5), modern: false),
        ]
    }()

    private static let openAITable: [String: OpenAIRates] = [
        "gpt-6-luna": OpenAIRates(input: 0.10, cachedInput: 0.01, output: 0.50),
        "gpt-5.6-terra": OpenAIRates(input: 2.00, cachedInput: 0.20, output: 12.00),
        "gpt-5.6-luna": OpenAIRates(input: 0.20, cachedInput: 0.02, output: 1.20),
        "gpt-5.3-codex": OpenAIRates(input: 1.75, cachedInput: 0.175, output: 14.00),
    ]
}

/// One de-duplicated Claude API response.
struct ClaudeMessageUsage: Sendable, Hashable {
    var model: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var thinking = 0
    var webSearches = 0
    var speed: String?
    var inferenceGeo: String?

    var tokens: TokenUsage {
        TokenUsage(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite5m + cacheWrite1h,
                   output: output, thinking: thinking)
    }

    var cost: CostEstimate {
        guard let price = ModelPricing.claude(model) else {
            return CostEstimate(usd: 0, hasUnpricedUsage: tokens.total > 0 || webSearches > 0)
        }
        var r = price.standard
        if let long = price.longContext, let threshold = price.longContextThreshold,
           input + cacheRead + cacheWrite5m + cacheWrite1h > threshold {
            r = long
        }
        if speed == "fast", let fastInput = price.fastInput, let fastOutput = price.fastOutput {
            let readRatio = r.cacheRead / r.input
            r = ClaudeRates(input: fastInput, cacheWrite5m: fastInput * 1.25, cacheWrite1h: fastInput * 2,
                            cacheRead: fastInput * readRatio, output: fastOutput)
        }
        var usd = (Double(input) * r.input + Double(cacheWrite5m) * r.cacheWrite5m + Double(cacheWrite1h) * r.cacheWrite1h
                   + Double(cacheRead) * r.cacheRead + Double(output) * r.output) / 1_000_000
        if inferenceGeo == "us", price.usInferenceMultiplier { usd *= ModelPricing.usInferenceFactor }
        usd += Double(webSearches) * ModelPricing.webSearchUSDPerRequest
        return CostEstimate(usd: usd)
    }
}

/// Codex cumulative counters as written by the CLI: cached and cache-write tokens are part of `input`,
/// reasoning is part of `output`.
struct CodexTokenTotals: Sendable, Hashable {
    var input = 0
    var cached = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0

    var tokens: TokenUsage {
        TokenUsage(input: max(0, input - cached - cacheWrite), cacheRead: cached, cacheWrite: cacheWrite,
                   output: output, thinking: reasoning)
    }

    func cost(model: String?) -> CostEstimate {
        guard let model, let r = ModelPricing.openAI(model) else {
            return CostEstimate(usd: 0, hasUnpricedUsage: input + output > 0)
        }
        let uncached = max(0, input - cached)
        return CostEstimate(usd: (Double(uncached) * r.input + Double(cached) * r.cachedInput + Double(output) * r.output) / 1_000_000)
    }

    /// Component-wise difference, clamped at zero.
    func delta(since previous: CodexTokenTotals) -> CodexTokenTotals {
        CodexTokenTotals(input: max(0, input - previous.input), cached: max(0, cached - previous.cached),
                         cacheWrite: max(0, cacheWrite - previous.cacheWrite), output: max(0, output - previous.output),
                         reasoning: max(0, reasoning - previous.reasoning))
    }

    static func + (lhs: CodexTokenTotals, rhs: CodexTokenTotals) -> CodexTokenTotals {
        CodexTokenTotals(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                         output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning)
    }
}
