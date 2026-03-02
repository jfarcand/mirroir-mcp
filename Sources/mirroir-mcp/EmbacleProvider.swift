// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AI agent provider for embacle-server's OpenAI-compatible Chat Completions API.
// ABOUTME: Targets a local embacle-server instance with optional Bearer auth, no API key required by default.

import Foundation
import HelperLib

/// Embacle-server Chat Completions API provider for AI diagnosis.
/// Embacle-server wraps already-authenticated CLI tools (Claude Code, Copilot, etc.)
/// and exposes an OpenAI-compatible REST API, so no API keys are needed by default.
struct EmbacleProvider: AIAgentProviding {
    let config: AgentConfig

    private static let completionsPath = "/v1/chat/completions"
    private static var timeoutSeconds: Int { EnvConfig.embacleTimeoutSeconds }

    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis? {
        let baseURL = config.baseURL ?? "http://localhost:3000"
        guard let url = URL(string: baseURL + Self.completionsPath) else { return nil }

        let systemPrompt = config.systemPrompt ?? loadDiagnosisPrompt()

        guard let payloadJSON = try? JSONEncoder().encode(payload),
              let payloadStr = String(data: payloadJSON, encoding: .utf8) else {
            return nil
        }

        let requestBody: [String: Any] = [
            "model": config.model ?? "copilot",
            "max_tokens": config.maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": payloadStr],
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var headers = ["Content-Type": "application/json"]

        // Support optional auth: if apiKeyEnvVar is configured and the env var has a value, send it
        if let apiKeyEnv = config.apiKeyEnvVar,
           let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv],
           !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        guard let responseData = sendAgentHTTPRequest(
            url: url, headers: headers, body: body, timeoutSeconds: Self.timeoutSeconds
        ) else {
            return nil
        }

        // Embacle-server returns OpenAI-format responses: {"choices": [{"message": {"content": "..."}}]}
        guard let responseText = extractEmbacleText(from: responseData) else {
            return nil
        }

        return parseAIDiagnosisResponse(
            data: Data(responseText.utf8),
            modelUsed: config.model ?? config.name)
    }

    /// Extract text content from embacle-server's OpenAI-compatible response.
    /// Response format: {"choices": [{"message": {"content": "..."}}], ...}
    private func extractEmbacleText(from data: Data) -> String? {
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
