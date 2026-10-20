import Foundation
import Testing
import LineupKit
@testable import LineupAI

struct MessagesStreamTests {
    func run(_ lines: [String]) throws -> LLMResponse {
        var stream = MessagesStream()
        for line in lines { if try stream.consume(line) { break } }
        return try stream.result(model: "fallback")
    }

    @Test func collectsTextUsageAndCostThroughStop() throws {
        let response = try run([
            "event: message_start",
            #"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
            "",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"batting"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"_order\": []}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":500}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        #expect(response.text == #"{"batting_order": []}"#)
        #expect(response.model == "claude-sonnet-5-5")
        #expect(response.usage.promptTokens == 3000)
        #expect(response.usage.completionTokens == 500)
        // 1000 × $2 + 2000 × 1.25 × $2 + 500 × $10, per million.
        #expect(abs((response.usage.cost ?? 0) - 0.012) < 1e-9)
    }

    @Test func streamThatEndsEarlyIsNotASuccess() {
        #expect(throws: AnthropicClient.ClientError.incomplete("the connection closed early")) {
            try run([#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}"#])
        }
    }

    @Test func refusalIsReported() {
        #expect(throws: AnthropicClient.ClientError.refused("cyber")) {
            try run([
                #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":3}}"#,
                #"data: {"type":"message_stop"}"#,
            ])
        }
    }

    @Test func hittingTheTokenCapIsIncomplete() {
        #expect(throws: AnthropicClient.ClientError.incomplete("max_tokens")) {
            try run([
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"{"}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
                #"data: {"type":"message_stop"}"#,
            ])
        }
    }

    @Test func overloadedMidStreamIsTransient() throws {
        do {
            _ = try run([#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
            Issue.record("expected an error")
        } catch let error as AnthropicClient.ClientError {
            #expect(error == .unavailable("Overloaded") && error.isTransient && !error.isFatal)
        }
    }
}

struct AnthropicErrorTests {
    @Test func mapsDocumentedErrors() {
        let key = AnthropicClient.error(status: 401, data: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        #expect(key == .invalidKey && key.isFatal)

        let credits = AnthropicClient.error(status: 400, data: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#.utf8))
        #expect(credits == .outOfCredits && credits.isFatal)

        let rate = AnthropicClient.error(status: 429, data: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8))
        #expect(rate.isTransient && !rate.isFatal)

        let overloaded = AnthropicClient.error(status: 529, data: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        #expect(overloaded == .unavailable("Overloaded") && overloaded.isTransient)
    }

    @Test func bodyStreamsCachesAndSetsEffort() throws {
        let client = AnthropicClient(apiKey: "k", effort: "medium")
        let data = try client.body(for: LLMRequest(model: "claude-opus-5-5", system: "sys", messages: [LLMMessage(.user, "hi")], maxTokens: 4000))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 32_000)
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect((json["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(json["thinking"] == nil)
    }
}
