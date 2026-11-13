import Foundation

/// Token usage accumulated from a Claude Code transcript (`projects/*/<session>.jsonl`).
///
/// Claude Code writes one line per content block and every block line repeats the response's full
/// `usage`, so responses are keyed by `message.id` and the last line wins.
struct ClaudeTranscriptUsage: Sendable {
    private(set) var messages: [String: ClaudeMessageUsage] = [:]
    /// Model of the most recent assistant line.
    private(set) var lastModel: String?

    private static let marker = Data(#""assistant""#.utf8)

    mutating func reset() { self = ClaudeTranscriptUsage() }

    mutating func consume(_ line: Data) {
        guard line.hasMarker(Self.marker), let (key, usage) = Self.decode(line) else { return }
        messages[key] = usage
        lastModel = usage.model
    }

    var usage: ModelUsage {
        messages.values.reduce(ModelUsage()) { $0 + ModelUsage(tokens: $1.tokens, cost: $1.cost) }
    }

    var byModel: [String: ModelUsage] {
        messages.values.reduce(into: [:]) { result, message in
            result[ModelID.normalizedClaude(message.model), default: ModelUsage()] += ModelUsage(tokens: message.tokens, cost: message.cost)
        }
    }

    static func decode(_ line: Data) -> (key: String, usage: ClaudeMessageUsage)? {
        guard let entry = try? JSONDecoder().decode(Line.self, from: line), entry.type == "assistant",
              let message = entry.message, let model = message.model, model != "<synthetic>",
              let raw = message.usage, let key = message.id ?? entry.requestId ?? entry.uuid else { return nil }

        let writes = raw.cacheCreationInputTokens ?? 0
        var write5m = raw.cacheCreation?.ephemeral5m ?? 0
        let write1h = raw.cacheCreation?.ephemeral1h ?? 0
        if write5m + write1h < writes { write5m += writes - write5m - write1h }  // unsplit writes price as 5 m

        let usage = ClaudeMessageUsage(
            model: model, input: raw.inputTokens ?? 0, output: raw.outputTokens ?? 0,
            cacheRead: raw.cacheReadInputTokens ?? 0, cacheWrite5m: write5m, cacheWrite1h: write1h,
            thinking: raw.outputTokensDetails?.thinkingTokens ?? 0,
            webSearches: raw.serverToolUse?.webSearchRequests ?? 0,
            speed: raw.speed, inferenceGeo: raw.inferenceGeo)
        return (key, usage)
    }

    // Only these fields are decoded; message content is never read.
    private struct Line: Decodable {
        let type: String?
        let message: Message?
        let requestId: String?
        let uuid: String?

        enum CodingKeys: String, CodingKey { case type, message, requestId, uuid }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(.type)
            message = c.lenient(.message)
            requestId = c.lenient(.requestId)
            uuid = c.lenient(.uuid)
        }
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey { case id, model, usage }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(.id)
            model = c.lenient(.model)
            usage = c.lenient(.usage)
        }
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreation: CacheCreation?
        let outputTokensDetails: OutputDetails?
        let serverToolUse: ServerToolUse?
        let speed: String?
        let inferenceGeo: String?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens", cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation", outputTokensDetails = "output_tokens_details"
            case serverToolUse = "server_tool_use", speed, inferenceGeo = "inference_geo"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = c.lenient(.inputTokens)
            outputTokens = c.lenient(.outputTokens)
            cacheCreationInputTokens = c.lenient(.cacheCreationInputTokens)
            cacheReadInputTokens = c.lenient(.cacheReadInputTokens)
            cacheCreation = c.lenient(.cacheCreation)
            outputTokensDetails = c.lenient(.outputTokensDetails)
            serverToolUse = c.lenient(.serverToolUse)
            speed = c.lenient(.speed)
            inferenceGeo = c.lenient(.inferenceGeo)
        }
    }

    private struct CacheCreation: Decodable {
        let ephemeral5m: Int?
        let ephemeral1h: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral5m = "ephemeral_5m_input_tokens", ephemeral1h = "ephemeral_1h_input_tokens"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ephemeral5m = c.lenient(.ephemeral5m)
            ephemeral1h = c.lenient(.ephemeral1h)
        }
    }

    private struct OutputDetails: Decodable {
        let thinkingTokens: Int?
        enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
        init(from decoder: any Decoder) throws {
            thinkingTokens = try decoder.container(keyedBy: CodingKeys.self).lenient(.thinkingTokens)
        }
    }

    private struct ServerToolUse: Decodable {
        let webSearchRequests: Int?
        enum CodingKeys: String, CodingKey { case webSearchRequests = "web_search_requests" }
        init(from decoder: any Decoder) throws {
            webSearchRequests = try decoder.container(keyedBy: CodingKeys.self).lenient(.webSearchRequests)
        }
    }
}

/// `subagents/agent-<id>.meta.json`.
struct ClaudeSubagentMeta: Sendable, Hashable {
    let agentType: String?
    let description: String?

    static func parse(_ data: Data) -> ClaudeSubagentMeta? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return ClaudeSubagentMeta(agentType: raw.agentType, description: raw.description)
    }

    private struct Raw: Decodable {
        let agentType: String?
        let description: String?
        enum CodingKeys: String, CodingKey { case agentType, description }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentType = c.lenient(.agentType)
            description = c.lenient(.description)
        }
    }
}
