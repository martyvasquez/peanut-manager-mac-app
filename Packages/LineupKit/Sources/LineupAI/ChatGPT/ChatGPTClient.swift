import Foundation
import LineupKit

/// Runs requests on the coach's ChatGPT plan through the public Responses API (Sign in with ChatGPT).
/// The route requires `stream: true` and `store: false` and rejects `max_output_tokens` and `temperature`.
public struct ChatGPTClient: LLMClient {
    public static let defaultModel = "gpt-5.6-sol"

    public var session: ChatGPTSession
    /// `low`…`max`; nil uses the model's default.
    public var reasoningEffort: String?
    public var urlSession: URLSession
    public var baseURL = URL(string: ChatGPTAuth.resource)!

    public init(session: ChatGPTSession, reasoningEffort: String? = nil, urlSession: URLSession = .shared) {
        self.session = session
        self.reasoningEffort = reasoningEffort
        self.urlSession = urlSession
    }

    public enum ClientError: Error, LocalizedError, Equatable {
        case planUsageOff
        case usageLimit
        case notEligible
        case unavailable(String)
        case rejected(status: Int, code: String?, message: String)
        case incomplete(String)
        case failed(code: String?, message: String)
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .planUsageOff: "Peanut Manager isn't allowed to use your ChatGPT plan. Turn it on in Settings."
            case .usageLimit: "You've reached your ChatGPT usage limit. Check Manage Usage in Settings, or try again later."
            case .notEligible: "This ChatGPT account can't use its plan in other apps. ChatGPT Plus or Pro is required."
            case .unavailable(let message): "ChatGPT is temporarily unavailable\(message.isEmpty ? "" : " (\(message))"). Try again in a moment."
            case .rejected(let status, let code, let message): "ChatGPT error \(status)\(code.map { " (\($0))" } ?? ""): \(message)"
            case .incomplete(let reason): "The model stopped before finishing (\(reason)). Try again."
            case .failed(let code, let message): "The model failed\(code.map { " (\($0))" } ?? ""): \(message)"
            case .emptyReply: "The model returned an empty reply. Try again or pick another model."
            }
        }

        /// A retry won't help; stop the run.
        public var isFatal: Bool {
            switch self {
            case .planUsageOff, .usageLimit, .notEligible: true
            case .rejected(let status, _, _): (400..<500).contains(status) && status != 408 && status != 429
            default: false
            }
        }

        /// Usually clears up by itself.
        public var isTransient: Bool {
            switch self {
            case .unavailable, .incomplete, .emptyReply: true
            case .failed(let code, _): code == nil || code == "server_error"
            case .rejected(let status, _, _): status >= 500 || status == 408 || status == 429
            default: false
            }
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        do {
            return try await send(request, token: try await session.accessToken())
        } catch ClientError.rejected(status: 401, _, _) {
            // The token may have been revoked or rotated early: renew once, then give up.
            do {
                return try await send(request, token: try await session.accessToken(forceRefresh: true))
            } catch ClientError.rejected(status: 401, _, _) {
                throw ChatGPTAuth.AuthError.signInAgain
            }
        }
    }

    func body(for request: LLMRequest) throws -> Data {
        struct Message: Encodable { var role: String; var content: String }
        struct Reasoning: Encodable { var effort: String }
        struct Body: Encodable {
            var model: String
            var instructions: String
            var input: [Message]
            var store = false
            var stream = true
            var reasoning: Reasoning?
        }
        let body = Body(model: request.model, instructions: request.system,
                        input: request.messages.map { Message(role: $0.role.rawValue, content: $0.content) },
                        reasoning: reasoningEffort.map(Reasoning.init))
        return try JSONEncoder().encode(body)
    }

    private func send(_ request: LLMRequest, token: String) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600 // reasoning models can think for minutes before the first byte
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        var stream = ResponsesStream()
        for try await line in bytes.lines {
            if try stream.consume(line) { break }
        }
        return try stream.result(model: request.model)
    }

    /// Maps a non-2xx reply. Admission errors can be `{"detail": "..."}` rather than the usual `error` object.
    static func error(status: Int, data: Data) -> ClientError {
        struct Body: Decodable {
            struct E: Decodable { var code: String?; var message: String?; var param: String? }
            var error: E?
            var detail: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let code = body?.error?.code
        let message = body?.error?.message ?? body?.detail ?? String(decoding: data.prefix(300), as: UTF8.self)
        if let coded = mapped(code: code, message: message) { return coded }
        if status == 503 { return .unavailable(message) }
        return .rejected(status: status, code: code, message: message)
    }

    static func mapped(code: String?, message: String) -> ClientError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": .usageLimit
        case "subscription_sharing_user_not_eligible": .notEligible
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": .unavailable(message)
        default: nil
        }
    }

    // MARK: - Models

    /// A model the signed-in account can use.
    public struct ModelInfo: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var summary: String?
        public var defaultEffort: String?
        public var efforts: [String]
    }

    /// The account's model list, in the server's order, keeping only models meant for display.
    public func models() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [ModelInfo] {
        struct Body: Decodable {
            struct Level: Decodable { var effort: String? }
            struct Model: Decodable {
                var slug: String
                var display_name: String?
                var description: String?
                var visibility: String?
                var default_reasoning_level: String?
                var supported_reasoning_levels: [Level]?
            }
            var models: [Model]
        }
        return try JSONDecoder().decode(Body.self, from: data).models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .map { ModelInfo(id: $0.slug, name: $0.display_name ?? $0.slug, summary: $0.description,
                             defaultEffort: $0.default_reasoning_level, efforts: ($0.supported_reasoning_levels ?? []).compactMap(\.effort)) }
    }
}

/// Reads a Responses API server-sent event stream. Success only on `response.completed`.
struct ResponsesStream {
    private(set) var text = ""
    private var completed: Completed?

    struct Completed: Decodable {
        struct Usage: Decodable {
            struct Details: Decodable { var reasoning_tokens: Int? }
            var input_tokens: Int?
            var output_tokens: Int?
            var output_tokens_details: Details?
        }
        var model: String?
        var usage: Usage?
    }

    private struct Event: Decodable {
        struct Failure: Decodable {
            struct E: Decodable { var code: String?; var message: String? }
            struct Incomplete: Decodable { var reason: String? }
            var error: E?
            var incomplete_details: Incomplete?
        }
        var type: String
        var delta: String?
        var code: String?
        var message: String?
        var response: Failure?
    }

    /// Feeds one line; returns true once the stream is finished.
    mutating func consume(_ line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return true }
        let data = Data(payload.utf8)
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return false }
        switch event.type {
        case "response.output_text.delta":
            text += event.delta ?? ""
        case "response.completed":
            struct Wrapper: Decodable { var response: Completed }
            completed = (try? JSONDecoder().decode(Wrapper.self, from: data))?.response ?? Completed()
            return true
        case "response.incomplete":
            throw ChatGPTClient.ClientError.incomplete(event.response?.incomplete_details?.reason ?? "unknown reason")
        case "response.failed":
            let code = event.response?.error?.code
            let message = event.response?.error?.message ?? "no details"
            throw ChatGPTClient.mapped(code: code, message: message) ?? .failed(code: code, message: message)
        case "error":
            let message = event.message ?? "no details"
            throw ChatGPTClient.mapped(code: event.code, message: message) ?? .failed(code: event.code, message: message)
        default:
            break
        }
        return false
    }

    func result(model: String) throws -> LLMResponse {
        guard let completed else { throw ChatGPTClient.ClientError.incomplete("the connection closed early") }
        guard !text.isEmpty else { throw ChatGPTClient.ClientError.emptyReply }
        let usage = LLMUsage(promptTokens: completed.usage?.input_tokens ?? 0, completionTokens: completed.usage?.output_tokens ?? 0, cost: nil)
        return LLMResponse(text: text, model: completed.model ?? model, usage: usage)
    }
}
