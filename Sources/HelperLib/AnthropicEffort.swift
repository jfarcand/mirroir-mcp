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
