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
// ABOUTME: Extension with the visibility steps of StepExecutor: wait_for, assert_visible and assert_not_visible.
// ABOUTME: Each reads the screen through the executor's describer and matches the label with ElementMatcher.

import Foundation
import HelperLib

extension StepExecutor {

    func executeWaitFor(label: String, timeoutSeconds: Int,
                                startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.waitFor(label: label, timeoutSeconds: timeoutSeconds)
        let deadline = CFAbsoluteTimeGetCurrent() + Double(timeoutSeconds)

        // Exponential backoff: start at 200ms, double each iteration, cap at 2s
        let initialPollUs: useconds_t = 200_000
        let maxPollUs: useconds_t = 2_000_000
        var currentPollUs = initialPollUs

        while CFAbsoluteTimeGetCurrent() < deadline {
            if call.isCancelled {
                return StepResult(step: step, status: .failed, message: StepExecutor.cancelledMessage,
                                  durationSeconds: elapsed(startTime))
            }
            if let describeResult = describer.describe(),
               ElementMatcher.isVisible(label: label, in: describeResult.elements) {
                return StepResult(step: step, status: .passed, message: nil,
                                  durationSeconds: elapsed(startTime))
            }
            usleep(currentPollUs)
            currentPollUs = min(currentPollUs * 2, maxPollUs)
        }

        // Final check after deadline
        if let describeResult = describer.describe(),
           ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .failed,
                          message: "Timed out waiting for \"\(label)\" after \(timeoutSeconds)s",
                          durationSeconds: elapsed(startTime))
    }

    func executeAssertVisible(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.assertVisible(label: label)

        guard let describeResult = describer.describe() else {
            return StepResult(step: step, status: .failed,
                              message: captureFailureMessage(),
                              durationSeconds: elapsed(startTime))
        }

        if ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        let available = describeResult.elements.map { $0.text }.joined(separator: ", ")
        return StepResult(step: step, status: .failed,
                          message: "Expected \"\(label)\" to be visible. Found: [\(available)]",
                          durationSeconds: elapsed(startTime))
    }

    func executeAssertNotVisible(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.assertNotVisible(label: label)

        guard let describeResult = describer.describe() else {
            // If we can't describe the screen, we can't confirm visibility either way
            return StepResult(step: step, status: .failed,
                              message: captureFailureMessage(),
                              durationSeconds: elapsed(startTime))
        }

        if !ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .failed,
                          message: "Expected \"\(label)\" to NOT be visible, but it was found",
                          durationSeconds: elapsed(startTime))
    }
}
