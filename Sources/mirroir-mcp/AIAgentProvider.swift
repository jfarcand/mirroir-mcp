// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Core infrastructure for AI-powered agent diagnosis of compiled skill failures.
// ABOUTME: Defines the protocol, config model, built-in registry, resolver, and shared HTTP helper.

import Foundation
import HelperLib

/// The mode of an AI agent: cloud API or local command.
enum AgentMode: String {
    case api
    case command
}

/// The cloud provider type for API-mode agents.
enum ProviderType: String {
    case anthropic
    case openai
    case ollama
    case embacle
}

/// Configuration for an AI agent, either from the built-in registry or a YAML profile.
struct AgentConfig {
    let name: String
    let mode: AgentMode
    let provider: ProviderType?
    let model: String?
    let apiKeyEnvVar: String?
    let baseURL: String?
    let systemPrompt: String?
    let maxTokens: Int
    let command: String?
    let args: [String]?
}

/// Result of an AI diagnosis call.
struct AIDiagnosis {
    let analysis: String
    let suggestedFixes: [AISuggestedFix]
    let confidence: String
    let modelUsed: String
}

/// A single suggested fix from the AI.
struct AISuggestedFix: Codable {
    let field: String
    let was: String
    let shouldBe: String

    enum CodingKeys: String, CodingKey {
        case field
        case was
        case shouldBe = "should_be"
    }
}

/// Registry and resolver for AI agent configurations.
enum AIAgentRegistry {

    /// Built-in agent configurations for common models.
    static let builtInAgents: [String: AgentConfig] = [
        defaultAnthropicModel: anthropicAgent(model: defaultAnthropicModel),
        "claude-sonnet-5-5": anthropicAgent(model: "claude-sonnet-5-5"),
        "claude-haiku-5-5": anthropicAgent(model: "claude-haiku-5-5"),
        "gpt-5.3": AgentConfig(
            name: "gpt-5.3", mode: .api, provider: .openai,
            model: "gpt-5.3", apiKeyEnvVar: "OPENAI_API_KEY",
            baseURL: "https://api.openai.com", systemPrompt: nil,
            maxTokens: EnvConfig.defaultAIMaxTokens, command: nil, args: nil),
        "embacle": AgentConfig(
            name: "embacle", mode: .api, provider: .embacle,
            model: defaultAgentModel, apiKeyEnvVar: nil,
            baseURL: "http://localhost:3000", systemPrompt: nil,
            maxTokens: EnvConfig.defaultAIMaxTokens, command: nil, args: nil),
        // `claude:sonnet` selects embacle-server's Claude Code runner, which
        // passes `sonnet` to `claude --model` (the runner's accepted aliases
        // are `sonnet`, `opus` and `haiku`; the CLI maps each to the current
        // model of that tier). A `runner:model` id always travels over HTTP;
        // see `AgentTransport`.
        "embacle:claude": AgentConfig(
            name: "embacle:claude", mode: .api, provider: .embacle,
            model: "claude:sonnet", apiKeyEnvVar: nil,
            baseURL: "http://localhost:3000", systemPrompt: nil,
            maxTokens: EnvConfig.defaultAIMaxTokens, command: nil, args: nil),
    ]

    /// A built-in Anthropic agent named after the Messages API model id it sends.
    private static func anthropicAgent(model: String) -> AgentConfig {
        AgentConfig(
            name: model, mode: .api, provider: .anthropic,
            model: model, apiKeyEnvVar: "ANTHROPIC_API_KEY",
            baseURL: "https://api.anthropic.com", systemPrompt: nil,
            maxTokens: EnvConfig.anthropicMaxTokens, command: nil, args: nil)
    }

    /// Token limit for an API profile that names none: Anthropic models think on every
    /// call and thinking counts toward the limit, so they get `anthropicMaxTokens`.
    private static func defaultMaxTokens(for provider: ProviderType?) -> Int {
        provider == .anthropic ? EnvConfig.anthropicMaxTokens : EnvConfig.defaultAIMaxTokens
    }

    /// Agent used when none is named in the environment.
    static let defaultAgentName = "embacle"

    /// Resolve the agent this installation is configured to use, or nil when
    /// the configured name matches nothing.
    static func resolveConfigured() -> AgentConfig? {
        resolve(name: EnvConfig.agent.isEmpty ? defaultAgentName : EnvConfig.agent)
    }

    /// Model for calls made straight to the embedded embacle runner, or nil
    /// when `config` (the configured agent by default) is not served by it
    /// under `AgentTransport`'s rule.
    static func embeddedAgentModel(
        config: AgentConfig? = resolveConfigured(),
        embeddedRunnerEnabled: Bool = AgentTransport.embeddedRunnerEnabled
    ) -> String? {
        guard let config,
              config.transport(embeddedRunnerEnabled: embeddedRunnerEnabled) == .embedded else {
            return nil
        }
        return config.model ?? defaultAgentModel
    }

    /// Resolve an agent name to its configuration.
    /// Resolution order: built-in → ollama prefix → local profile → global profile.
    static func resolve(name: String) -> AgentConfig? {
        // 1. Built-in registry
        if let config = builtInAgents[name] {
            return config
        }

        // 2. Ollama prefix (ollama:<model>)
        if name.hasPrefix("ollama:") {
            let modelName = String(name.dropFirst("ollama:".count))
            guard !modelName.isEmpty else { return nil }
            return AgentConfig(
                name: name, mode: .api, provider: .ollama,
                model: modelName, apiKeyEnvVar: nil,
                baseURL: "http://localhost:11434", systemPrompt: nil,
                maxTokens: EnvConfig.defaultAIMaxTokens, command: nil, args: nil)
        }

        // 3. Local profile: <cwd>/.mirroir-mcp/agents/<name>.yaml
        // 4. Global profile: ~/.mirroir-mcp/agents/<name>.yaml
        for dir in PermissionPolicy.agentDirs {
            let path = dir + "/" + name + ".yaml"
            if let config = loadYAMLProfile(path: path) {
                return config
            }
        }

        return nil
    }

    /// List all available agent names (built-in + discovered profiles).
    static func availableAgents() -> [String] {
        var names = Array(builtInAgents.keys).sorted()
        names.append("ollama:<model>")

        for dir in PermissionPolicy.agentDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for file in contents where file.hasSuffix(".yaml") {
                let name = String(file.dropLast(".yaml".count))
                if !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// Load an agent configuration from a YAML profile file.
    static func loadYAMLProfile(path: String) -> AgentConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        var dict: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Skip block scalar indicators (we handle simple key: value only)
            if trimmed == "|" || trimmed == ">" { continue }

            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIndex])
                    .trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                // Strip surrounding quotes
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty && !value.isEmpty {
                    dict[key] = value
                }
            }
        }

        let name = dict["name"] ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let modeStr = dict["mode"] ?? "api"

        guard let mode = AgentMode(rawValue: modeStr) else { return nil }

        if mode == .command {
            guard let command = dict["command"] else { return nil }
            let argsStr = dict["args"] ?? "[]"
            let args = parseYAMLArray(argsStr)
            return AgentConfig(
                name: name, mode: .command, provider: nil,
                model: nil, apiKeyEnvVar: nil, baseURL: nil,
                systemPrompt: dict["system_prompt"],
                maxTokens: Int(dict["max_tokens"] ?? "") ?? EnvConfig.defaultAIMaxTokens,
                command: command, args: args)
        }

        // API mode
        let provider = ProviderType(rawValue: dict["provider"] ?? "")
        return AgentConfig(
            name: name, mode: .api, provider: provider,
            model: dict["model"], apiKeyEnvVar: dict["api_key_env"],
            baseURL: dict["base_url"],
            systemPrompt: dict["system_prompt"],
            maxTokens: Int(dict["max_tokens"] ?? "") ?? defaultMaxTokens(for: provider),
            command: nil, args: nil)
    }

    /// Parse a simple YAML array like ["a", "b", "c"] into [String].
    static func parseYAMLArray(_ str: String) -> [String] {
        var s = str.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[") && s.hasSuffix("]") else { return [] }
        s = String(s.dropFirst().dropLast())
        return s.components(separatedBy: ",").compactMap { item in
            var v = item.trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) ||
               (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : v
        }
    }

    /// Create the appropriate provider for an agent configuration.
    static func createProvider(config: AgentConfig) -> AIAgentProviding? {
        switch config.mode {
        case .command:
            guard let command = config.command else { return nil }
            return CommandProvider(
                command: command, args: config.args ?? [],
                systemPrompt: config.systemPrompt)
        case .api:
            guard let provider = config.provider else { return nil }
            switch provider {
            case .anthropic:
                return AnthropicProvider(config: config)
            case .openai:
                return OpenAIProvider(config: config)
            case .ollama:
                return OllamaProvider(config: config)
            case .embacle:
                return EmbacleProvider(config: config)
            }
        }
    }
}

// MARK: - Shared Chat Completion

/// Ask the configured agent a text-only question and return its reply.
///
/// Wraps the OpenAI-compatible `/v1/chat/completions` shape every provider
/// speaks, so a caller needing a one-shot completion states the prompts and
/// nothing else. The request travels over the agent's
/// `AgentConfig.transport()`.
///
/// - Returns: The assistant's text, or nil when the agent is unreachable or
///   answers in a shape with no message content.
func requestChatCompletion(
    systemPrompt: String,
    userPrompt: String,
    maxTokens: Int,
    agentConfig: AgentConfig,
    timeoutSeconds: Int
) -> String? {
    let baseURL = agentConfig.baseURL ?? defaultAgentBaseURL
    guard let url = URL(string: baseURL + "/v1/chat/completions") else { return nil }

    let requestBody: [String: Any] = [
        "model": agentConfig.model ?? defaultAgentModel,
        "max_tokens": maxTokens,
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt],
        ],
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }

    var headers = ["Content-Type": "application/json"]
    if let apiKeyEnv = agentConfig.apiKeyEnvVar,
       let apiKey = ProcessInfo.processInfo.environment[apiKeyEnv],
       !apiKey.isEmpty {
        headers["Authorization"] = "Bearer \(apiKey)"
    }

    guard let responseData = sendAgentRequest(
        transport: agentConfig.transport(),
        url: url, headers: headers, body: body, timeoutSeconds: timeoutSeconds
    ) else { return nil }

    return extractChatCompletionText(from: responseData)
}

/// Endpoint used when a target declares no `baseURL`.
let defaultAgentBaseURL = "http://localhost:3000"

/// Model used when a target declares none, and the model of the built-in
/// `embacle` agent. It must be a real Copilot model id, never a provider alias:
/// embacle maps the aliases `copilot` and `copilot_headless` to its own
/// catalog default (the top-ranked Opus) and writes that into
/// `~/.copilot/settings.json`, which is the only model input `copilot --acp`
/// obeys.
let defaultAgentModel = "claude-sonnet-5.5"

/// Messages API model id of the built-in Anthropic agent of the same name, and the
/// model `AnthropicProvider` sends when an Anthropic profile names none.
let defaultAnthropicModel = "claude-opus-5-5"

/// Pull the assistant text out of an OpenAI-compatible chat completions body.
/// Falls back to the raw body so a provider answering in another shape still
/// surfaces something the caller can parse or log.
func extractChatCompletionText(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String
    else {
        return String(data: data, encoding: .utf8)
    }
    return content
}

// MARK: - Shared HTTP Helper

/// Send a synchronous HTTP POST request and return the response body.
/// Returns nil on error, printing a warning to stderr. Agent callers go
/// through `sendAgentRequest`, which picks this or the embedded runner.
func sendAgentHTTPRequest(
    url: URL, headers: [String: String], body: Data, timeoutSeconds: Int
) -> Data? {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = TimeInterval(timeoutSeconds)
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var responseData: Data?
    nonisolated(unsafe) var responseError: Error?
    nonisolated(unsafe) var httpStatus: Int?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        responseData = data
        responseError = error
        httpStatus = (response as? HTTPURLResponse)?.statusCode
        semaphore.signal()
    }
    task.resume()

    let waitResult = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
    if waitResult == .timedOut {
        task.cancel()
        fputs("Warning: AI agent timed out after \(timeoutSeconds)s\n", stderr)
        return nil
    }

    if let error = responseError {
        fputs("Warning: AI agent request failed: \(error.localizedDescription)\n", stderr)
        return nil
    }

    if let status = httpStatus {
        switch status {
        case 200...299:
            break
        case 401, 403:
            fputs("Warning: AI agent authentication failed (HTTP \(status))\n", stderr)
            return nil
        case 429:
            fputs("Warning: AI agent rate limited (HTTP 429)\n", stderr)
            return nil
        default:
            let bodyStr = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            fputs("Warning: AI agent HTTP \(status): \(bodyStr.prefix(200))\n", stderr)
            return nil
        }
    }

    return responseData
}

/// Parse the AI response JSON into an AIDiagnosis.
func parseAIDiagnosisResponse(data: Data, modelUsed: String) -> AIDiagnosis? {
    // Try to decode the JSON response directly
    struct AIResponseJSON: Codable {
        let analysis: String?
        let suggestedFixes: [AISuggestedFix]?
        let confidence: String?

        enum CodingKeys: String, CodingKey {
            case analysis
            case suggestedFixes = "suggested_fixes"
            case confidence
        }
    }

    // The AI might return the JSON wrapped in text. Extract the JSON object.
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    // Find the outermost { ... } in the text
    guard let jsonStart = text.firstIndex(of: "{"),
          let jsonEnd = text.lastIndex(of: "}") else {
        return AIDiagnosis(
            analysis: text, suggestedFixes: [], confidence: "low", modelUsed: modelUsed)
    }

    let jsonStr = String(text[jsonStart...jsonEnd])
    guard let jsonData = jsonStr.data(using: .utf8) else { return nil }

    do {
        let decoded = try JSONDecoder().decode(AIResponseJSON.self, from: jsonData)
        return AIDiagnosis(
            analysis: decoded.analysis ?? "No analysis provided",
            suggestedFixes: decoded.suggestedFixes ?? [],
            confidence: decoded.confidence ?? "low",
            modelUsed: modelUsed)
    } catch {
        return AIDiagnosis(
            analysis: text, suggestedFixes: [], confidence: "low", modelUsed: modelUsed)
    }
}
