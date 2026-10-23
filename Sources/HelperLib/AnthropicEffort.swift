// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The Anthropic Messages API `output_config.effort` levels, parsed from the anthropicEffort setting.
// ABOUTME: An unknown setting value resolves to the default level with a single stderr warning per value.

import Foundation

/// Thinking depth sent as `output_config.effort` on Anthropic Messages API calls.
/// The API rejects any other value with HTTP 400, so the setting is parsed into this
/// enum before it reaches a request body.
public enum AnthropicEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    /// Parse a setting value. Surrounding whitespace and letter case are ignored, so
    /// `" Low "` is `.low`. An empty value means unset and resolves to `fallback`
    /// silently; any other unknown value resolves to `fallback` and calls `warn` with
    /// the message to print.
    public static func resolve(
        _ raw: String,
        fallback: AnthropicEffort = TimingConstants.anthropicEffort,
        warn: (String) -> Void
    ) -> AnthropicEffort {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return fallback }
        if let effort = AnthropicEffort(rawValue: normalized) { return effort }
        let accepted = allCases.map(\.rawValue).joined(separator: ", ")
        warn("Warning: anthropicEffort '\(raw)' is not one of \(accepted); "
            + "using '\(fallback.rawValue)'\n")
        return fallback
    }
}
