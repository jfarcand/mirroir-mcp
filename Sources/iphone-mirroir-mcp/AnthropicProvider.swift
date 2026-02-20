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
    private static var timeoutSeconds: Int { EnvConfig.anthropicTimeoutSeconds }

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

        let systemPrompt = config.systemPrompt ?? loadDiagnosisPrompt()

        guard let payloadJSON = try? JSONEncoder().encode(payload),
              let payloadStr = String(data: payloadJSON, encoding: .utf8) else {
            return nil
        }

        let requestBody: [String: Any] = [
            "model": config.model ?? "claude-sonnet-4-6-20250514",
            "max_tokens": config.maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": payloadStr],
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        let headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
        ]

        guard let responseData = sendAgentHTTPRequest(
            url: url, headers: headers, body: body, timeoutSeconds: Self.timeoutSeconds
        ) else {
            return nil
        }

        // Extract the text content from Anthropic's response format
        guard let responseText = extractAnthropicText(from: responseData) else {
            return nil
        }

        return parseAIDiagnosisResponse(
            data: Data(responseText.utf8),
            modelUsed: config.model ?? config.name)
    }

    /// Extract text content from Anthropic Messages API response.
    /// Response format: {"content": [{"type": "text", "text": "..."}], ...}
    private func extractAnthropicText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            return String(data: data, encoding: .utf8)
        }
        return text
    }
}
