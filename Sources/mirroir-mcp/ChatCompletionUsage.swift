// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Token counts reported in an OpenAI-compatible chat-completion response's `usage` block.
// ABOUTME: Lets vision calls report their real per-frame cost instead of discarding it.

import Foundation

/// Token counts a chat-completion response reports in its `usage` block.
/// Providers that do not report usage (for example embacle's
/// `copilot_headless` runner) yield no value rather than zeros, so a missing
/// count is never mistaken for a free call.
struct ChatCompletionUsage: Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    /// Parse the `usage` block from a chat-completion response body.
    /// Returns nil when the body is not JSON, has no `usage`, or lacks the
    /// prompt/completion counts. `total_tokens` falls back to their sum when
    /// a provider omits it.
    static func parse(from data: Data) -> ChatCompletionUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int
        else { return nil }
        let total = usage["total_tokens"] as? Int ?? prompt + completion
        return ChatCompletionUsage(
            promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }
}
