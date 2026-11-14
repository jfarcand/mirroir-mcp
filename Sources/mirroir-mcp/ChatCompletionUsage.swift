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
