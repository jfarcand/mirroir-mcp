/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
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

        let systemPrompt = config.systemPrompt ?? loadSystemPrompt()

        guard let payloadJSON = try? JSONEncoder().encode(payload),
              let payloadStr = String(data: payloadJSON, encoding: .utf8) else {
            return nil
        }

        let requestBody: [String: Any] = [
            "model": config.model ?? "gpt-5.3",
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

        guard let responseData = sendAgentRequest(
            transport: config.transport(),
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
