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
// ABOUTME: AI agent provider for local Ollama instance (no authentication required).
// ABOUTME: Sends diagnostic payloads to localhost:11434/api/generate with streaming disabled.

import Foundation
import HelperLib

/// Ollama local API provider for AI diagnosis.
struct OllamaProvider: AIAgentProviding {
    let config: AgentConfig

    private static let generatePath = "/api/generate"
    private static var timeoutSeconds: Int { EnvConfig.ollamaTimeoutSeconds }

    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis? {
        let baseURL = config.baseURL ?? "http://localhost:11434"
        guard let url = URL(string: baseURL + Self.generatePath) else { return nil }

        let systemPrompt = config.systemPrompt ?? loadSystemPrompt()

        guard let payloadJSON = try? JSONEncoder().encode(payload),
              let payloadStr = String(data: payloadJSON, encoding: .utf8) else {
            return nil
        }

        let prompt = systemPrompt + "\n\n" + payloadStr

        let requestBody: [String: Any] = [
            "model": config.model ?? "llama3",
            "prompt": prompt,
            "stream": false,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        let headers = [
            "Content-Type": "application/json",
        ]

        guard let responseData = sendAgentRequest(
            transport: config.transport(),
            url: url, headers: headers, body: body, timeoutSeconds: Self.timeoutSeconds
        ) else {
            fputs("Warning: Cannot reach Ollama at \(baseURL)\n", stderr)
            return nil
        }

        // Extract text from Ollama's response format
        guard let responseText = extractOllamaText(from: responseData) else {
            return nil
        }

        return parseAIDiagnosisResponse(
            data: Data(responseText.utf8),
            modelUsed: config.model ?? config.name)
    }

    /// Extract text content from Ollama generate response.
    /// Response format: {"response": "...", ...}
    private func extractOllamaText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String else {
            return String(data: data, encoding: .utf8)
        }
        return response
    }
}
