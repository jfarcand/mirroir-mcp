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
// ABOUTME: The optional `expect` of tap, swipe and press_key: text that must show after the action.
// ABOUTME: Checked with run_steps' wait_for, so the call fails when the action did not lead there.

import Foundation
import HelperLib

/// Text an action must lead to, checked after the action the way a `wait_for` step is.
struct ActionExpectation: Equatable {
    let text: String
    let timeoutSeconds: Int?

    /// The step that checks it.
    var step: SkillStep { .waitFor(label: text, timeoutSeconds: timeoutSeconds) }

    static let properties: [String: JSONValue] = [
        "expect": .object([
            "type": .string("string"),
            "description": .string(
                "Text that must show on the screen after the action, waited for like a wait_for "
                + "step. The call fails when it never shows, so no describe_screen is needed to "
                + "check that the action worked."),
        ]),
        "expect_timeout": .object([
            "type": .string("integer"),
            "description": .string(
                "With expect, the most seconds to wait for it (default: the waitForTimeoutSeconds setting)"),
        ]),
    ]

    /// The expectation in `args`: none, one, or why the arguments do not make one.
    /// Read before the action, so a bad argument never leaves the action half-checked.
    static func parse(_ args: [String: JSONValue]) -> Result<ActionExpectation?, ExpectationRefusal> {
        let timeoutValue = args["expect_timeout"]
        guard let value = args["expect"] else {
            if timeoutValue != nil {
                return .failure(ExpectationRefusal(message: "expect_timeout applies only with expect"))
            }
            return .success(nil)
        }
        guard let text = value.asString()?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return .failure(ExpectationRefusal(message: "expect must be the text to wait for, not empty"))
        }
        var timeout: Int?
        if let timeoutValue {
            guard let seconds = timeoutValue.asInt(), seconds >= 1 else {
                return .failure(ExpectationRefusal(message: "expect_timeout must be a whole number of seconds, at least 1"))
            }
            timeout = seconds
        }
        return .success(ActionExpectation(text: text, timeoutSeconds: timeout))
    }

    /// The reply of an action that passed (`reply`), followed by the check of `expectation`.
    /// The call fails when the text never showed.
    static func check(
        _ expectation: ActionExpectation, after reply: String,
        ctx: TargetContext, registry: TargetRegistry, policy: PermissionPolicy
    ) -> MCPToolResult {
        let executor = InlineStepRunner.executor(for: ctx, registry: registry)
        let report = InlineStepRunner.run([expectation.step], executor: executor, policy: policy)
        // The check ends with the screen as it is now; the action's own read of it is older.
        let action = reply.range(of: screenNowMarker).map { String(reply[..<$0.lowerBound]) } ?? reply
        let text = action + "\n\nExpected after it:\n" + report.text
        return report.failed ? .error(text) : .text(text)
    }
}

extension ActionExpectation {
    /// Where a reply's read of the screen after the action starts.
    static let screenNowMarker = "\n\nScreen now: "
}

/// Why `expect` or `expect_timeout` was refused.
struct ExpectationRefusal: Error, Equatable {
    let message: String
}
