import Foundation
import LineupKit

/// Bring-your-own-key client for OpenRouter's OpenAI-compatible chat endpoint.
public struct OpenRouterClient: LLMClient {
    public static let defaultLineupModel = "anthropic/claude-sonnet-5.5"

    public var apiKey: String
    public var session: URLSession
    public var baseURL = URL(string: "https://openrouter.ai/api/v1")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public enum ClientError: Error, LocalizedError {
        case missingKey
        case invalidKey
        case outOfCredits
        case rateLimited
        case server(status: Int, message: String)
        case emptyReply(finishReason: String?, reasoningTokens: Int?)

        public var errorDescription: String? {
            switch self {
            case .missingKey: "Add your OpenRouter API key in Settings to generate lineups."
            case .invalidKey: "OpenRouter rejected the API key. Check it in Settings."
            case .outOfCredits: "Your OpenRouter account is out of credits."
            case .rateLimited: "OpenRouter is rate limiting requests. Try again in a moment."
            case .server(let status, let message): "OpenRouter error \(status): \(message)"
            case .emptyReply(let finish, let reasoning):
                if finish == "length" {
                    "The model ran out of room before answering\(reasoning.map { " (it spent \($0) tokens thinking)" } ?? ""). Try again, or pick a model that thinks less."
                } else {
                    "The model returned an empty reply\(finish.map { " (\($0))" } ?? ""). Try again or pick another model."
                }
            }
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }

        struct Message: Encodable { var role: String; var content: String }
        struct Body: Encodable {
            var model: String
            var messages: [Message]
            var max_tokens: Int
        }
        let body = Body(
            model: request.model,
            messages: [Message(role: "system", content: request.system)] + request.messages.map { Message(role: $0.role.rawValue, content: $0.content) },
            max_tokens: request.maxTokens
        )

        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600 // reasoning models can think for minutes before the first byte
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("https://peanutmgr.com", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue("Peanut Manager", forHTTPHeaderField: "X-Title")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
                var finish_reason: String?
            }
            struct Details: Decodable { var reasoning_tokens: Int? }
            struct Usage: Decodable { var prompt_tokens: Int?; var completion_tokens: Int?; var cost: Double?; var completion_tokens_details: Details? }
            var model: String?
            var choices: [Choice]
            var usage: Usage?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let text = reply.choices.first?.message.content, !text.isEmpty else {
            throw ClientError.emptyReply(finishReason: reply.choices.first?.finish_reason, reasoningTokens: reply.usage?.completion_tokens_details?.reasoning_tokens)
        }
        let usage = LLMUsage(promptTokens: reply.usage?.prompt_tokens ?? 0, completionTokens: reply.usage?.completion_tokens ?? 0, cost: reply.usage?.cost)
        return LLMResponse(text: text, model: reply.model, usage: usage)
    }

    /// One entry from OpenRouter's public model catalog.
    public struct ModelInfo: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// USD per million tokens.
        public var inputPrice: Double?
        public var outputPrice: Double?
        public var contextLength: Int?
    }

    /// OpenRouter's full, live model list. Public; no key required.
    public static func models(session: URLSession = .shared) async throws -> [ModelInfo] {
        struct Body: Decodable {
            struct Model: Decodable {
                struct Pricing: Decodable { var prompt: String?; var completion: String? }
                var id: String
                var name: String?
                var pricing: Pricing?
                var context_length: Int?
            }
            var data: [Model]
        }
        let (data, response) = try await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw error(status: status, data: data) }
        func perMillion(_ s: String?) -> Double? { s.flatMap(Double.init).flatMap { $0 >= 0 ? $0 * 1_000_000 : nil } }
        return try JSONDecoder().decode(Body.self, from: data).data.map {
            ModelInfo(id: $0.id, name: displayName($0.name ?? $0.id), inputPrice: perMillion($0.pricing?.prompt),
                      outputPrice: perMillion($0.pricing?.completion), contextLength: $0.context_length)
        }
    }

    /// "Meta: Muse Spark 1.3 Contributor" → "Muse Spark 1.3 Contributor".
    public static func displayName(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// Cheap call used by Settings → "Test Key".
    public func verifyKey() async throws {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }
        var request = URLRequest(url: baseURL.appending(path: "key"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
    }

    static func error(status: Int, data: Data) -> ClientError {
        switch status {
        case 401, 403: return .invalidKey
        case 402: return .outOfCredits
        case 429: return .rateLimited
        default:
            struct Body: Decodable { struct E: Decodable { var message: String? }; var error: E? }
            let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
            return .server(status: status, message: message)
        }
    }
}
