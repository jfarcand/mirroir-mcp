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
// ABOUTME: Runs the structured condition and repeat steps: read the screen, check one element, run one action.
// ABOUTME: Each action passes the caller's action guard and the executor's own checks, the same path as a top-level step.

import Foundation

extension StepExecutor {

    // MARK: - condition

    /// Run `action` when `check` holds on the screen read now. A check that
    /// does not hold passes the step without running the action.
    func executeCondition(check: ScreenCheck, action: SkillStep, stepIndex: Int,
                          skillName: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.condition(check: check, then: action)
        guard let screen = describer.describe() else {
            return StepResult(step: step, status: .failed, message: captureFailureMessage(),
                              durationSeconds: elapsed(startTime))
        }
        guard check.holds(in: screen.elements) else {
            return StepResult(step: step, status: .passed,
                              message: "\(check.displayName) did not hold: \(action.displayName) not run",
                              durationSeconds: elapsed(startTime))
        }
        let result = runAction(action, stepIndex: stepIndex, skillName: skillName)
        if result.status.isFailure {
            return StepResult(step: step, status: .failed,
                              message: "\(check.displayName) held, then \(action.displayName) failed: "
                                + (result.message ?? "no reason given"),
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed,
                          message: "\(check.displayName) held: ran \(action.displayName)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - repeat

    /// Run `body` until `check` holds, reading the screen before each run.
    /// Fails when the check still does not hold after `maxIterations` runs,
    /// when a run fails, or when the call is cancelled between runs.
    func executeRepeat(check: ScreenCheck, maxIterations: Int, body: SkillStep, stepIndex: Int,
                       skillName: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.repeatUntil(check: check, maxIterations: maxIterations, body: body)
        var runs = 0
        while true {
            guard let screen = describer.describe() else {
                return StepResult(step: step, status: .failed, message: captureFailureMessage(),
                                  durationSeconds: elapsed(startTime))
            }
            if check.holds(in: screen.elements) {
                return StepResult(step: step, status: .passed,
                                  message: "\(check.displayName) after \(runs) run(s) of \(body.displayName)",
                                  durationSeconds: elapsed(startTime))
            }
            if runs == maxIterations {
                return StepResult(step: step, status: .failed,
                                  message: "\(check.displayName) still did not hold after \(runs) "
                                    + "run(s) of \(body.displayName)",
                                  durationSeconds: elapsed(startTime))
            }
            if call.isCancelled {
                return StepResult(step: step, status: .failed, message: Self.cancelledMessage,
                                  durationSeconds: elapsed(startTime))
            }
            let result = runAction(body, stepIndex: stepIndex, skillName: skillName)
            runs += 1
            if result.status.isFailure {
                return StepResult(step: step, status: .failed,
                                  message: "run \(runs) of \(body.displayName) failed: "
                                    + (result.message ?? "no reason given"),
                                  durationSeconds: elapsed(startTime))
            }
        }
    }

    /// Run one action of a condition or repeat: the caller's guard first, then
    /// the same `execute` a top-level step goes through.
    private func runAction(_ action: SkillStep, stepIndex: Int, skillName: String) -> StepResult {
        if let stopped = actionGuard?(action) { return stopped }
        return execute(step: action, stepIndex: stepIndex, skillName: skillName)
    }
}
