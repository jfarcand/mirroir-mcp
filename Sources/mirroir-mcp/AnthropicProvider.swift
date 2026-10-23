// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AI agent provider for Anthropic's Claude API (Messages endpoint).
// ABOUTME: Sends diagnostic payloads as user messages and parses structured JSON responses.

import Foundation
import HelperLib

/// Anthropic Messages API provider for AI diagnosis.
struct AnthropicProvider: AIAgentProviding {
    let config: AgentConfig

    private static let apiVersion = "2023-06-01"
    private static let messagesPath = "/v1/messages"

    /// The `AIDiagnosis` reply shape, enforced through structured outputs so the reply parses.
    private static var diagnosisSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "analysis": ["type": "string"],
                "suggested_fixes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "field": ["type": "string"],
                            "was": ["type": "string"],
                            "should_be": ["type": "string"],
                        ],
                        "required": ["field", "was", "should_be"],
                        "additionalProperties": false,
                    ],
                ],
                "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
            ],
            "required": ["analysis", "suggested_fixes", "confidence"],
            "additionalProperties": false,
        ]
    }

    /// Deadline for this agent's request, sized for the `max_tokens` it actually sends.
    var timeoutSeconds: Int { EnvConfig.anthropicTimeoutSeconds(forMaxTokens: config.maxTokens) }

    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis? {
        guard let apiKeyEnv = config.apiKeyEnvVar else {
            fputs("Warning: AI agent '\(config.name)' has no API key env var configured\n", stderr)
            return nil
        }

        guard let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv], !apiKey.isEmpty else {
            fputs("Warning: AI agent '\(config.name)' requires \(apiKeyEnv) env var\n", stderr)
            return nil
        }

        let baseURL = config.baseURL ?? "https://api.anthropic.com"
        guard let url = URL(string: baseURL + Self.messagesPath) else { return nil }

        let systemPrompt = config.systemPrompt ?? loadSystemPrompt()

        guard let payloadJSON = try? JSONEncoder().encode(payload),
              let payloadStr = String(data: payloadJSON, encoding: .utf8) else {
            return nil
        }

        let requestBody = Self.requestBody(
            model: config.model ?? defaultAnthropicModel, maxTokens: config.maxTokens,
            effort: EnvConfig.anthropicEffort, system: systemPrompt, userContent: payloadStr)

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        let headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
        ]

        guard let responseData = sendAgentRequest(
            transport: config.transport(),
            url: url, headers: headers, body: body, timeoutSeconds: timeoutSeconds
        ) else {
            return nil
        }

        let responseText: String
        switch Self.extractReplyText(from: responseData) {
        case .success(let text):
            responseText = text
        case .failure(let failure):
            fputs("Warning: AI agent '\(config.name)' \(failure.message)\n", stderr)
            return nil
        }

        return parseAIDiagnosisResponse(
            data: Data(responseText.utf8),
            modelUsed: config.model ?? config.name)
    }

    /// Build the Messages API request body for a diagnosis call.
    /// Thinking is adaptive by default on current Claude models, so the body sends no
    /// `thinking` field, no sampling parameters, and no assistant prefill: the reply shape
    /// comes from `output_config.format` and the thinking depth from `output_config.effort`.
    /// `maxTokens` must leave room for the thinking as well as the reply, since both count.
    static func requestBody(
        model: String, maxTokens: Int, effort: AnthropicEffort, system: String, userContent: String
    ) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "output_config": [
                "format": ["type": "json_schema", "schema": diagnosisSchema],
                "effort": effort.rawValue,
            ],
            "messages": [
                ["role": "user", "content": userContent],
            ],
        ]
    }

    /// Extract the reply text from a Messages API response.
    /// The response can open with `thinking` blocks, so the reply is the first block of
    /// type `text`. A refusal or a reply cut off at `max_tokens` is a failure, not a reply.
    static func extractReplyText(from data: Data) -> Result<String, AnthropicReplyFailure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformedResponse)
        }
        switch json["stop_reason"] as? String {
        case "refusal":
            let details = json["stop_details"] as? [String: Any]
            return .failure(.refusal(category: details?["category"] as? String))
        case "max_tokens":
            return .failure(.maxTokens)
        default:
            break
        }
        let content = json["content"] as? [[String: Any]] ?? []
        let textBlock = content.first { $0["type"] as? String == "text" }
        guard let text = textBlock?["text"] as? String else {
            return .failure(.noTextBlock)
        }
        return .success(text)
    }
}

/// Why a Messages API response carried no usable diagnosis reply.
enum AnthropicReplyFailure: Error, Equatable {
    /// The model declined; `category` is the API's `stop_details.category` when present.
    case refusal(category: String?)
    /// The reply hit `max_tokens` before the structured answer was complete.
    case maxTokens
    /// The response had no `text` content block.
    case noTextBlock
    /// The response body was not a JSON object.
    case malformedResponse

    /// Human-readable reason, completing "AI agent '<name>' …".
    var message: String {
        switch self {
        case .refusal(let category):
            return "refused the request (category: \(category ?? "unspecified"))"
        case .maxTokens:
            return "reply was truncated at max_tokens; raise the agent's max_tokens"
        case .noTextBlock:
            return "response contained no text block"
        case .malformedResponse:
            return "response was not a JSON object"
        }
    }
}
