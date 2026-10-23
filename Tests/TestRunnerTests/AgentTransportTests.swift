// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the agent transport rule: which requests the embedded embacle runner serves.
// ABOUTME: Covers every provider, bare vs runner:model embacle models, and the http override.

import Testing
@testable import HelperLib
@testable import mirroir_mcp

@Suite("AgentTransport")
struct AgentTransportTests {

    @Test("Non-embacle providers always use HTTP, even with the embedded runner on")
    func nonEmbacleProvidersUseHTTP() {
        let cases: [(ProviderType?, String)] = [
            (.anthropic, defaultAnthropicModel),
            (.openai, "gpt-5.3"),
            (.ollama, "llama3"),
            (nil, defaultAgentModel),
        ]
        for (provider, model) in cases {
            #expect(AgentTransport.resolve(
                provider: provider, model: model, embeddedRunnerEnabled: true) == .http,
                "\(String(describing: provider)) \(model)")
        }
    }

    @Test("A bare embacle model runs embedded when the runner is on")
    func bareEmbacleModelRunsEmbedded() {
        #expect(AgentTransport.resolve(
            provider: .embacle, model: defaultAgentModel, embeddedRunnerEnabled: true) == .embedded)
        #expect(AgentTransport.resolve(
            provider: .embacle, model: "gpt-5.5", embeddedRunnerEnabled: true) == .embedded)
    }

    @Test("A bare embacle model uses HTTP when the runner is off")
    func bareEmbacleModelUsesHTTPWhenRunnerOff() {
        #expect(AgentTransport.resolve(
            provider: .embacle, model: defaultAgentModel, embeddedRunnerEnabled: false) == .http)
    }

    @Test("An embacle runner:model selector always uses HTTP")
    func runnerSelectorUsesHTTP() {
        for model in ["claude:sonnet", "copilot:gpt-5.5", "copilot:", "gemini:pro"] {
            #expect(AgentTransport.isRunnerSelector(model))
            #expect(AgentTransport.resolve(
                provider: .embacle, model: model, embeddedRunnerEnabled: true) == .http, "\(model)")
        }
        #expect(!AgentTransport.isRunnerSelector(defaultAgentModel))
    }

    @Test("A bare embacle runner name uses HTTP, in any letter case")
    func bareRunnerNameUsesHTTP() {
        for model in ["claude", "Claude", "copilot", "claude_code", "gemini-cli", "opencode"] {
            #expect(AgentTransport.isRunnerSelector(model), "\(model)")
            #expect(AgentTransport.resolve(
                provider: .embacle, model: model, embeddedRunnerEnabled: true) == .http, "\(model)")
        }
    }

    @Test("A Copilot model id that starts with a runner name still runs embedded")
    func runnerNamePrefixedModelRunsEmbedded() {
        for model in ["gemini-2.5-pro", "claude-opus-4.5", "gpt-5.5"] {
            #expect(!AgentTransport.isRunnerSelector(model), "\(model)")
            #expect(AgentTransport.resolve(
                provider: .embacle, model: model, embeddedRunnerEnabled: true) == .embedded,
                "\(model)")
        }
    }

    @Test("An embacle YAML profile with the bare model claude uses HTTP")
    func embacleProfileWithBareClaudeUsesHTTP() {
        let config = AgentConfig(
            name: "my-claude", mode: .api, provider: .embacle,
            model: "claude", apiKeyEnvVar: nil,
            baseURL: defaultAgentBaseURL, systemPrompt: nil,
            maxTokens: EnvConfig.defaultAIMaxTokens, command: nil, args: nil)
        #expect(config.transport(embeddedRunnerEnabled: true) == .http)
    }

    @Test("embacle:claude resolves to HTTP via the Claude Code runner selector")
    func embacleClaudeUsesHTTP() throws {
        let config = try #require(AIAgentRegistry.resolve(name: "embacle:claude"))
        #expect(config.model == "claude:sonnet")
        #expect(config.transport(embeddedRunnerEnabled: true) == .http)
    }

    @Test("Built-in embacle agent runs embedded only when the runner is on")
    func builtInEmbacleFollowsRunner() throws {
        let config = try #require(AIAgentRegistry.resolve(name: "embacle"))
        #expect(config.transport(embeddedRunnerEnabled: true) == .embedded)
        #expect(config.transport(embeddedRunnerEnabled: false) == .http)
    }

    @Test("Built-in non-embacle agents resolve to HTTP")
    func builtInAPIAgentsUseHTTP() throws {
        for name in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "gpt-5.3", "ollama:llama3"] {
            let config = try #require(AIAgentRegistry.resolve(name: name))
            #expect(config.transport(embeddedRunnerEnabled: true) == .http, "\(name)")
        }
    }

    @Test("The embedded runner is on only when linked and not forced to HTTP")
    func embeddedRunnerEnabledRule() {
        #expect(AgentTransport.embeddedRunnerEnabled(ffiLinked: true, setting: "auto"))
        #expect(!AgentTransport.embeddedRunnerEnabled(
            ffiLinked: true, setting: AgentTransport.httpSetting))
        #expect(!AgentTransport.embeddedRunnerEnabled(ffiLinked: false, setting: "auto"))
    }

    // MARK: - Vision Route

    @Test("Vision without an override sends the agent's model on its transport")
    func visionRouteWithoutOverride() throws {
        let config = try #require(AIAgentRegistry.resolve(name: "embacle"))
        let route = VisionScreenDescriber.visionRoute(
            agentConfig: config, visionModelOverride: "", embeddedRunnerEnabled: true)
        #expect(route.model == defaultAgentModel)
        #expect(route.transport == .embedded)
    }

    @Test("A visionModel runner selector moves an embedded agent's vision call to HTTP")
    func visionRouteOverrideSelectsRunner() throws {
        let config = try #require(AIAgentRegistry.resolve(name: "embacle"))
        for override in ["claude:opus", "claude"] {
            let route = VisionScreenDescriber.visionRoute(
                agentConfig: config, visionModelOverride: override, embeddedRunnerEnabled: true)
            #expect(route.model == override)
            #expect(route.transport == .http, "\(override)")
        }
    }

    @Test("A bare visionModel moves an HTTP selector agent's vision call to the embedded runner")
    func visionRouteOverrideToBareModel() throws {
        let config = try #require(AIAgentRegistry.resolve(name: "embacle:claude"))
        let route = VisionScreenDescriber.visionRoute(
            agentConfig: config, visionModelOverride: "gpt-5.5", embeddedRunnerEnabled: true)
        #expect(route.model == "gpt-5.5")
        #expect(route.transport == .embedded)
        let runnerOff = VisionScreenDescriber.visionRoute(
            agentConfig: config, visionModelOverride: "gpt-5.5", embeddedRunnerEnabled: false)
        #expect(runnerOff.transport == .http)
    }
}
