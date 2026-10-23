// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AI-facing EnvConfig properties (provider timeouts, component detection, agent transport, vision describer).
// ABOUTME: Split from EnvConfigFeatures.swift to stay under the 500-line limit.

import Foundation

extension EnvConfig {

    // MARK: - AI Provider

    public static var openAITimeoutSeconds: Int {
        readInt("openAITimeoutSeconds", default: TimingConstants.openAITimeoutSeconds)
    }

    public static var ollamaTimeoutSeconds: Int {
        readInt("ollamaTimeoutSeconds", default: TimingConstants.ollamaTimeoutSeconds)
    }

    /// Deadline for one non-streaming Anthropic request sending the global
    /// `anthropicMaxTokens` budget, as the built-in Anthropic agents do.
    public static var anthropicTimeoutSeconds: Int {
        anthropicTimeoutSeconds(forMaxTokens: anthropicMaxTokens)
    }

    /// Deadline for one non-streaming Anthropic request whose `max_tokens` is `maxTokens`.
    /// An explicit `anthropicTimeoutSeconds` setting wins; unset, the deadline is
    /// `plannedAnthropicTimeoutSeconds(forMaxTokens:)`, so a reply that fills its budget lands.
    public static func anthropicTimeoutSeconds(forMaxTokens maxTokens: Int) -> Int {
        readInt("anthropicTimeoutSeconds",
                default: plannedAnthropicTimeoutSeconds(forMaxTokens: maxTokens))
    }

    /// Seconds a non-streaming reply of `maxTokens` output tokens may take at the
    /// Anthropic SDKs' planning rate, never below `anthropicMinTimeoutSeconds` and never
    /// above `anthropicMaxNonStreamingSeconds`.
    public static func plannedAnthropicTimeoutSeconds(forMaxTokens maxTokens: Int) -> Int {
        let secondsPerHour = 3600
        let rate = TimingConstants.anthropicPlannedOutputTokensPerHour
        // Clamp first so a profile's `max_tokens` cannot overflow the product;
        // any budget past the cap's token count plans to the cap anyway.
        let capTokens = TimingConstants.anthropicMaxNonStreamingSeconds * rate / secondsPerHour + 1
        let tokens = Swift.min(Swift.max(maxTokens, 0), capTokens)
        let planned = (tokens * secondsPerHour + rate - 1) / rate
        return Swift.min(
            Swift.max(planned, TimingConstants.anthropicMinTimeoutSeconds),
            TimingConstants.anthropicMaxNonStreamingSeconds)
    }

    public static var embacleTimeoutSeconds: Int {
        readInt("embacleTimeoutSeconds", default: TimingConstants.embacleTimeoutSeconds)
    }

    public static var commandTimeoutSeconds: Int {
        readInt("commandTimeoutSeconds", default: TimingConstants.commandTimeoutSeconds)
    }

    public static var defaultAIMaxTokens: Int {
        readInt("defaultAIMaxTokens", default: TimingConstants.defaultAIMaxTokens)
    }

    public static var anthropicMaxTokens: Int {
        readInt("anthropicMaxTokens", default: TimingConstants.anthropicMaxTokens)
    }

    /// `output_config.effort` for Anthropic diagnosis calls. An unknown value falls
    /// back to `TimingConstants.anthropicEffort` with one warning on stderr.
    public static var anthropicEffort: AnthropicEffort {
        anthropicEffort(settings: settings, env: env, warner: .shared)
    }

    /// `anthropicEffort` read from the given settings and environment, warning through
    /// `warner`. The property passes the process-wide sources and the shared warner.
    static func anthropicEffort(
        settings: [String: Any], env: [String: String], warner: OnceWarner
    ) -> AnthropicEffort {
        AnthropicEffort.resolve(
            readString("anthropicEffort", default: "", settings: settings, env: env),
            warn: warner.warn)
    }

    public static var visionMaxTokens: Int {
        readInt("visionMaxTokens", default: TimingConstants.visionMaxTokens)
    }

    // MARK: - Component Detection

    /// Component detection mode for BFS exploration.
    /// Controls how OCR elements are grouped into UI components.
    ///
    /// Values:
    /// - `heuristic`: Phase 1 only — component.md match rules, no LLM calls.
    /// - `llm_first_screen`: (DEFAULT) LLM classifies first screen, heuristics for rest.
    /// - `llm_every_screen`: LLM classifies every new screen.
    /// - `llm_fallback`: Heuristics first, LLM when no confident match.
    public static var componentDetection: String {
        readString("componentDetection", envVar: "MIRROIR_COMPONENT_DETECTION",
                   default: "llm_first_screen")
    }

    // MARK: - Agent Transport

    /// Agent transport mode: "auto" (default) or "http".
    /// When "auto", uses embedded Rust FFI if linked, otherwise falls back to HTTP.
    /// Set to "http" to force HTTP even when the embedded runtime is available.
    public static var agentTransport: String {
        readString("agentTransport", envVar: "MIRROIR_AGENT_TRANSPORT", default: "auto")
    }

    // MARK: - Screen Describer

    /// Screen describer mode: "auto" (default), "ocr", or "vision".
    /// "auto" resolves to "ocr": the vision path places bottom-of-screen
    /// elements too high (a known Y-coordinate bias), so vision is opt-in —
    /// set "vision" explicitly.
    /// "vision" uses an AI vision model (via configured agent) to describe screens
    /// instead of local OCR + YOLO. Requires a configured agent (e.g. embacle).
    /// "ocr" forces local Vision OCR + YOLO regardless of embacle availability.
    public static var screenDescriberMode: String {
        readString("screenDescriberMode", envVar: "MIRROIR_SCREEN_DESCRIBER_MODE",
                   default: "auto")
    }

    /// Override the model name sent in vision chat completion requests.
    /// Empty string means use the provider default (e.g. "copilot_headless" for embacle).
    public static var visionModel: String {
        readString("visionModel", envVar: "MIRROIR_VISION_MODEL",
                   default: TimingConstants.visionModel)
    }

    /// Target image width (in pixels) for vision API calls. Screenshots are resized
    /// to this width before sending to the vision model to stay within payload limits.
    public static var visionImageWidth: Int {
        readInt("visionImageWidth", default: 500)
    }

    /// AI agent name for vision screen description and diagnosis.
    /// Resolved via AIAgentRegistry. Empty string means no agent configured.
    public static var agent: String {
        readString("agent", envVar: "MIRROIR_AGENT", default: "")
    }
}
