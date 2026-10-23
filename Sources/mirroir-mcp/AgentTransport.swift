// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides whether an agent request runs on the embedded embacle runner or over HTTP.
// ABOUTME: The one routing rule every agent caller uses, plus the dispatch that honors it.

import Foundation
import HelperLib

/// How a request reaches its agent.
///
/// The embedded embacle FFI is linked with a single runner — Copilot over ACP —
/// and does not read embacle-server's `runner:model` grammar. So it serves only
/// `embacle` agents whose model is a bare Copilot model id. Everything else
/// travels over HTTP to the agent's `baseURL`:
/// - any non-embacle provider (Anthropic, OpenAI, Ollama speak their own APIs);
/// - an embacle model holding `:` (`claude:sonnet`, `copilot:gpt-5.5`), which
///   selects an embacle-server runner the embedded FFI does not have;
/// - an embacle model that is a bare runner name (`claude`, `copilot`), which
///   embacle-server reads as "that runner's default model" and the embedded FFI
///   would send to Copilot as a model id;
/// - every request when the FFI is not linked or `agentTransport` is `"http"`.
enum AgentTransport: Equatable, Sendable {
    /// The embacle runtime linked into this binary.
    case embedded
    /// An HTTP POST to the agent's endpoint.
    case http

    /// `agentTransport` value that keeps the embedded runner off even when linked.
    static let httpSetting = "http"

    /// Separator of embacle-server's `runner:model` selector grammar.
    static let runnerSelectorSeparator: Character = ":"

    /// Whether this process runs the embedded runner: the FFI is linked and
    /// `agentTransport` does not force HTTP.
    static var embeddedRunnerEnabled: Bool {
        embeddedRunnerEnabled(ffiLinked: EmbacleFFI.isAvailable, setting: EnvConfig.agentTransport)
    }

    /// Whether the embedded runner is on for a given link state and setting.
    static func embeddedRunnerEnabled(ffiLinked: Bool, setting: String) -> Bool {
        ffiLinked && setting != httpSetting
    }

    /// Runner names embacle-server accepts, alone or before `:`. Mirrors
    /// `parse_runner_type` in embacle's `src/factory.rs` (which
    /// `crates/embacle-server/src/provider_resolver.rs` calls), feature-gated
    /// runners included; embacle matches them case-insensitively.
    static let embacleRunnerNames: Set<String> = [
        "claude_code", "claude", "claudecode",
        "copilot",
        "cursor_agent", "cursoragent", "cursor-agent",
        "opencode", "open_code",
        "gemini", "gemini_cli", "geminicli", "gemini-cli",
        "codex", "codex_cli", "codexcli", "codex-cli",
        "goose", "goose_cli", "goosecli", "goose-cli",
        "cline", "cline_cli", "clinecli", "cline-cli",
        "continue", "continue_cli", "continuecli", "continue-cli", "cn",
        "warp", "warp_cli", "warpcli", "warp-cli", "oz",
        "kiro", "kiro_cli", "kirocli", "kiro-cli",
        "kilo", "kilo_cli", "kilocli", "kilo-cli", "kilocode",
        "copilot_headless", "copilot-headless", "copilotheadless", "headless",
        "copilot_sdk", "copilot-sdk", "copilotsdk",
        "claude_web", "claude-web", "claudeweb", "web",
    ]

    /// Whether `model` selects an embacle-server runner: a `runner:model` id, or
    /// a bare runner name meaning that runner's default model.
    static func isRunnerSelector(_ model: String) -> Bool {
        model.contains(runnerSelectorSeparator) || embacleRunnerNames.contains(model.lowercased())
    }

    /// The transport for a request to `provider` naming `model`.
    static func resolve(
        provider: ProviderType?,
        model: String,
        embeddedRunnerEnabled: Bool = AgentTransport.embeddedRunnerEnabled
    ) -> AgentTransport {
        guard provider == .embacle, embeddedRunnerEnabled, !isRunnerSelector(model) else {
            return .http
        }
        return .embedded
    }
}

extension AgentConfig {
    /// The transport for a request carrying this agent's own model.
    func transport(
        embeddedRunnerEnabled: Bool = AgentTransport.embeddedRunnerEnabled
    ) -> AgentTransport {
        AgentTransport.resolve(
            provider: provider, model: model ?? defaultAgentModel,
            embeddedRunnerEnabled: embeddedRunnerEnabled)
    }
}

/// Send an agent request over `transport` and return the response body.
/// Returns nil on error, printing a warning to stderr.
func sendAgentRequest(
    transport: AgentTransport,
    url: URL, headers: [String: String], body: Data, timeoutSeconds: Int
) -> Data? {
    switch transport {
    case .embedded:
        return EmbacleFFI.chatCompletion(requestJSON: body, timeoutSeconds: timeoutSeconds)
    case .http:
        return sendAgentHTTPRequest(
            url: url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    }
}
