// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AnthropicProvider's Messages API request body and reply extraction.
// ABOUTME: Covers the always-thinking request shape, the per-profile deadline, and refusal / max_tokens replies.

import Foundation
import Testing

@testable import HelperLib
@testable import mirroir_mcp

extension AIAgentProviderTests {

    // MARK: - Request Body

    private func diagnosisBody(effort: AnthropicEffort = .low) -> [String: Any] {
        AnthropicProvider.requestBody(
            model: defaultAnthropicModel, maxTokens: EnvConfig.anthropicMaxTokens,
            effort: effort, system: "system prompt", userContent: "{}")
    }

    @Test("The Anthropic fallback model is a built-in Anthropic agent")
    func anthropicDefaultModelIsBuiltIn() throws {
        let config = try #require(AIAgentRegistry.builtInAgents[defaultAnthropicModel])
        #expect(config.provider == .anthropic)
        #expect(config.model == defaultAnthropicModel)
    }

    @Test("Request body sends no sampling, thinking, or prefill fields")
    func anthropicRequestOmitsRejectedFields() throws {
        let body = diagnosisBody()
        for field in ["temperature", "top_p", "top_k", "thinking", "tool_choice", "tools"] {
            #expect(body[field] == nil, "unexpected field \(field)")
        }
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.allSatisfy { $0["role"] as? String == "user" })
    }

    @Test("Request body carries model, max_tokens, and the JSON schema format")
    func anthropicRequestShape() throws {
        let body = diagnosisBody()
        #expect(body["model"] as? String == defaultAnthropicModel)
        #expect(body["max_tokens"] as? Int == EnvConfig.anthropicMaxTokens)
        #expect(body["system"] as? String == "system prompt")
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] is [String: Any])
        // The body must serialize — the provider sends it as JSON.
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test("Request body sends the given effort level as output_config.effort",
          arguments: AnthropicEffort.allCases)
    func anthropicRequestSendsEffort(effort: AnthropicEffort) throws {
        let outputConfig = try #require(diagnosisBody(effort: effort)["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == effort.rawValue)
    }

    // MARK: - Timeout

    private func anthropicProvider(maxTokens: Int) -> AnthropicProvider {
        AnthropicProvider(config: AgentConfig(
            name: "my-claude", mode: .api, provider: .anthropic,
            model: defaultAnthropicModel, apiKeyEnvVar: "ANTHROPIC_API_KEY",
            baseURL: nil, systemPrompt: nil,
            maxTokens: maxTokens, command: nil, args: nil))
    }

    @Test("The request deadline follows the profile's own max_tokens, not the global setting")
    func anthropicTimeoutFollowsProfileMaxTokens() {
        let small = anthropicProvider(maxTokens: 8000)
        let large = anthropicProvider(maxTokens: 19200)
        // Compared through the resolver (not the planned value) so a local
        // `anthropicTimeoutSeconds` setting cannot fail this test.
        #expect(small.timeoutSeconds == EnvConfig.anthropicTimeoutSeconds(forMaxTokens: 8000))
        #expect(large.timeoutSeconds == EnvConfig.anthropicTimeoutSeconds(forMaxTokens: 19200))
        #expect(EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: 19200)
            > EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: 8000))
    }

    @Test("An absurd profile max_tokens plans to the cap instead of overflowing",
          arguments: [Int.max, Int.max / 3600, -1, Int.min])
    func plannedTimeoutNeverTraps(maxTokens: Int) {
        let planned = EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: maxTokens)
        #expect(planned >= TimingConstants.anthropicMinTimeoutSeconds)
        #expect(planned <= TimingConstants.anthropicMaxNonStreamingSeconds)
    }

    // MARK: - Reply Extraction

    private func reply(_ json: String) -> Result<String, AnthropicReplyFailure> {
        AnthropicProvider.extractReplyText(from: Data(json.utf8))
    }

    @Test("Reply text is the first text block, after any thinking blocks")
    func anthropicReplySkipsThinkingBlocks() {
        let result = reply("""
            {"stop_reason": "end_turn", "content": [
              {"type": "thinking", "thinking": "", "signature": "sig"},
              {"type": "text", "text": "{\\"analysis\\": \\"ok\\"}"}]}
            """)
        #expect(result == .success("{\"analysis\": \"ok\"}"))
    }

    @Test("Refusal stop_reason is a failure carrying the category")
    func anthropicReplyRefusal() {
        let result = reply("""
            {"stop_reason": "refusal", "stop_details": {"category": "cyber"}, "content": []}
            """)
        #expect(result == .failure(.refusal(category: "cyber")))
    }

    @Test("max_tokens stop_reason is a failure, not a truncated JSON parse")
    func anthropicReplyMaxTokens() {
        let result = reply("""
            {"stop_reason": "max_tokens", "content": [{"type": "text", "text": "{\\"analy"}]}
            """)
        #expect(result == .failure(.maxTokens))
    }

    @Test("Response with only thinking blocks has no text block")
    func anthropicReplyWithoutText() {
        let result = reply("""
            {"stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": ""}]}
            """)
        #expect(result == .failure(.noTextBlock))
    }

    @Test("Non-JSON response body is malformed")
    func anthropicReplyMalformed() {
        #expect(reply("not json") == .failure(.malformedResponse))
    }
}
