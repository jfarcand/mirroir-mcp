// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AI agent provider for OpenAI's Chat Completions API.
// ABOUTME: Sends diagnostic payloads as system+user messages and parses structured JSON responses.

import Foundation
import HelperLib

/// OpenAI Chat Completions API provider for AI diagnosis.
struct OpenAIProvider: AIAgentProviding {
    let config: AgentConfig

    private static let completionsPath = "/v1/chat/completions"
    private static var timeoutSeconds: Int { EnvConfig.openAITimeoutSeconds }

    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis? {
        guard let apiKeyEnv = config.apiKeyEnvVar else {
            fputs("Warning: AI agent '\(config.name)' has no API key env var configured\n", stderr)
            return nil
        }

        guard let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv], !apiKey.isEmpty else {
            fputs("Warning: AI agent '\(config.name)' requires \(apiKeyEnv) env var\n", stderr)
            return nil
        }

        let baseURL = config.baseURL ?? "https://api.openai.com"
        guard let url = URL(string: baseURL + Self.completionsPath) else { return nil }

        let systemPrompt = config.systemPrompt ?? loadDiagnosisPrompt()

        guard let payloadJSON = try? JSONEncoder().encode(payload),
              let payloadStr = String(data: payloadJSON, encoding: .utf8) else {
            return nil
        }

        let requestBody: [String: Any] = [
            "model": config.model ?? "gpt-4o",
            "max_tokens": config.maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": payloadStr],
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        let headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)",
        ]

        guard let responseData = sendAgentHTTPRequest(
            url: url, headers: headers, body: body, timeoutSeconds: Self.timeoutSeconds
        ) else {
            return nil
        }

        // Extract the text content from OpenAI's response format
        guard let responseText = extractOpenAIText(from: responseData) else {
            return nil
        }

        return parseAIDiagnosisResponse(
            data: Data(responseText.utf8),
            modelUsed: config.model ?? config.name)
    }

    /// Extract text content from OpenAI Chat Completions response.
    /// Response format: {"choices": [{"message": {"content": "..."}}], ...}
    private func extractOpenAIText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return String(data: data, encoding: .utf8)
        }
        return content
    }
}
