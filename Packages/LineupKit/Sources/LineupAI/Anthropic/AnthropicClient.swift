import Foundation
import LineupKit

/// Runs requests on Claude through the Messages API with the coach's own API key (Claude Max and Team plans include
/// monthly API credits). Eval-only for now (plan, Build status item 5): it ships only if Claude beats Luna in the blind eval.
/// Streams, since thinking can run for minutes before the first byte. Thinking is adaptive (the default on current models);
/// `effort` sets its depth.
public struct AnthropicClient: LLMClient {
    /// The models the eval compares by default, roughly cheapest first.
    public static let evalModels = ["claude-haiku-5-5", "claude-sonnet-5-5"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public var apiKey: String
    /// `low`…`max`; nil uses the model's default.
    public var effort: String?
    public var urlSession: URLSession
    public var baseURL = URL(string: "https://api.anthropic.com/v1")!

    public init(apiKey: String, effort: String? = nil, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.effort = effort
        self.urlSession = urlSession
    }

    public enum ClientError: Error, LocalizedError, Equatable {
        case invalidKey
        case outOfCredits
        case unavailable(String)
        case rejected(status: Int, type: String?, message: String)
        case refused(String?)
        case incomplete(String)
        case failed(type: String?, message: String)
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .invalidKey: "The Anthropic API key was rejected. Check it in the Claude Console."
            case .outOfCredits: "The Anthropic account is out of credits. Add credits or link your Claude plan in the Claude Console."
            case .unavailable(let message): "Claude is temporarily unavailable\(message.isEmpty ? "" : " (\(message))"). Try again in a moment."
            case .rejected(let status, let type, let message): "Claude error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
            case .refused(let category): "Claude declined this request\(category.map { " (\($0))" } ?? "")."
            case .incomplete(let reason): "The model stopped before finishing (\(reason)). Try again."
            case .failed(let type, let message): "The model failed\(type.map { " (\($0))" } ?? ""): \(message)"
            case .emptyReply: "The model returned an empty reply. Try again or pick another model."
            }
        }

        /// A retry won't help; stop the run.
        public var isFatal: Bool {
            switch self {
            case .invalidKey, .outOfCredits: true
            case .rejected(let status, _, _): (400..<500).contains(status) && status != 408 && status != 429
            default: false
            }
        }

        /// Usually clears up by itself.
        public var isTransient: Bool {
            switch self {
            case .unavailable, .incomplete, .emptyReply: true
            case .failed(let type, _): type == nil || type == "overloaded_error" || type == "api_error"
            case .rejected(let status, _, _): status >= 500 || status == 408 || status == 429
            default: false
            }
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: baseURL.appending(path: "messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try body(for: request)

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 4096 { break } }
            throw Self.error(status: status, data: data)
        }
        var stream = MessagesStream()
        for try await line in bytes.lines {
            if try stream.consume(line) { break }
        }
        return try stream.result(model: request.model)
    }

    func body(for request: LLMRequest) throws -> Data {
        struct Message: Encodable { var role: String; var content: String }
        struct OutputConfig: Encodable { var effort: String }
        struct CacheControl: Encodable { var type = "ephemeral" }
        struct Body: Encodable {
            var model: String
            var max_tokens: Int
            var system: String
            var messages: [Message]
            var stream = true
            var output_config: OutputConfig?
            // Revise rounds resend the whole conversation; this caches its prefix.
            var cache_control = CacheControl()
        }
        // Thinking shares the token cap, so leave room above the answer the engine asked for.
        let body = Body(model: request.model, max_tokens: max(request.maxTokens, 32_000), system: request.system,
                        messages: request.messages.map { Message(role: $0.role.rawValue, content: $0.content) },
                        output_config: effort.map(OutputConfig.init))
        return try JSONEncoder().encode(body)
    }

    /// Maps a non-2xx reply (`{"type":"error","error":{"type":…,"message":…}}`).
    static func error(status: Int, data: Data) -> ClientError {
        struct Body: Decodable {
            struct E: Decodable { var type: String?; var message: String? }
            var error: E?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let type = body?.error?.type
        let message = body?.error?.message ?? String(decoding: data.prefix(300), as: UTF8.self)
        if status == 401 || type == "authentication_error" { return .invalidKey }
        if message.localizedCaseInsensitiveContains("credit balance") { return .outOfCredits }
        if status == 529 || type == "overloaded_error" { return .unavailable(message) }
        return .rejected(status: status, type: type, message: message)
    }

    /// USD per million tokens (input, output), for the eval's cost column. Cache writes cost 1.25× input, reads 0.1×.
    static let prices: [String: (input: Double, output: Double)] = [
        "claude-opus-5-5": (4, 20),
        "claude-sonnet-5-5": (2, 10),
        "claude-haiku-5-5": (0.10, 0.50),
    ]
}

/// Reads a Messages API server-sent event stream. Success only on `message_stop`.
struct MessagesStream {
    private(set) var text = ""
    private var model: String?
    private var usage = Usage()
    private var stopReason: String?
    private var refusalCategory: String?
    private var stopped = false

    struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?
    }

    private struct Event: Decodable {
        struct Message: Decodable { var model: String?; var usage: Usage? }
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stop_reason: String?
            var stop_details: StopDetails?
        }
        struct StopDetails: Decodable { var category: String? }
        struct E: Decodable { var type: String?; var message: String? }
        var type: String
        var message: Message?
        var delta: Delta?
        var usage: Usage?
        var stop_details: StopDetails?
        var error: E?
    }

    /// Feeds one line; returns true once the stream is finished.
    mutating func consume(_ line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else { return false }
        switch event.type {
        case "message_start":
            model = event.message?.model
            if let start = event.message?.usage { usage = start }
        case "content_block_delta":
            // Thinking arrives as its own deltas; only the answer's text counts.
            if event.delta?.type == "text_delta" { text += event.delta?.text ?? "" }
        case "message_delta":
            stopReason = event.delta?.stop_reason ?? stopReason
            refusalCategory = event.delta?.stop_details?.category ?? event.stop_details?.category ?? refusalCategory
            if let output = event.usage?.output_tokens { usage.output_tokens = output }
        case "message_stop":
            stopped = true
            return true
        case "error":
            let type = event.error?.type
            let message = event.error?.message ?? "no details"
            throw type == "overloaded_error" ? AnthropicClient.ClientError.unavailable(message) : .failed(type: type, message: message)
        default:
            break
        }
        return false
    }

    func result(model requested: String) throws -> LLMResponse {
        guard stopped else { throw AnthropicClient.ClientError.incomplete("the connection closed early") }
        if stopReason == "refusal" { throw AnthropicClient.ClientError.refused(refusalCategory) }
        if stopReason == "max_tokens" { throw AnthropicClient.ClientError.incomplete("max_tokens") }
        guard !text.isEmpty else { throw AnthropicClient.ClientError.emptyReply }
        let served = model ?? requested
        let written = usage.cache_creation_input_tokens ?? 0, read = usage.cache_read_input_tokens ?? 0
        let input = (usage.input_tokens ?? 0) + written + read
        let output = usage.output_tokens ?? 0
        let cost = AnthropicClient.prices[served].map { price in
            (Double(usage.input_tokens ?? 0) + 1.25 * Double(written) + 0.1 * Double(read)) * price.input / 1e6
                + Double(output) * price.output / 1e6
        }
        return LLMResponse(text: text, model: served, usage: LLMUsage(promptTokens: input, completionTokens: output, cost: cost))
    }
}
