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
// ABOUTME: Tests for the structured condition and repeat steps: parsing, replay values and execution.
// ABOUTME: Free-text condition/repeat stay AI-only; the structured form runs one checked action, bounded by max.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ControlFlowStepTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!
    private var executor: StepExecutor!

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 1, settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory() + "control-flow-\(UUID().uuidString)", dryRun: false)
        executor = StepExecutor(bridge: StubBridge(), input: input, describer: describer,
                                capture: StubCapture(), config: config)
    }

    private func screen(_ texts: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.enumerated().map { index, text in
                TapPoint(text: text, tapX: 100, tapY: Double(100 + 50 * index), confidence: 0.95)
            },
            screenshotBase64: "")
    }

    private func run(_ raw: String) -> StepResult? {
        guard let step = SkillParser.parseStep(raw) else { return nil }
        return executor.execute(step: step, stepIndex: 0, skillName: "control-flow")
    }

    // MARK: - Parsing

    func testAStructuredConditionParsesToItsCheckAndAction() {
        let step = SkillParser.parseStep(#"condition: visible "Allow" -> tap: Allow"#)
        guard case .condition(let check, .tap(let label)) = step else {
            return XCTFail("expected a condition, got \(String(describing: step))")
        }
        XCTAssertEqual(check, ScreenCheck(label: "Allow", visible: true))
        XCTAssertEqual(label, "Allow")
    }

    func testNotVisibleNegatesTheCheck() {
        let step = SkillParser.parseStep(#"condition: not visible 'Signed in' -> tap: "Sign In""#)
        guard case .condition(let check, .tap(let label)) = step else {
            return XCTFail("expected a condition, got \(String(describing: step))")
        }
        XCTAssertEqual(check, ScreenCheck(label: "Signed in", visible: false))
        XCTAssertEqual(label, "Sign In")
    }

    func testAStructuredRepeatParsesItsBound() {
        let step = SkillParser.parseStep(#"repeat: until visible "Done", max 8 -> swipe: up"#)
        guard case .repeatUntil(let check, let max, .swipe(let direction)) = step else {
            return XCTFail("expected a repeat, got \(String(describing: step))")
        }
        XCTAssertEqual(check, ScreenCheck(label: "Done", visible: true))
        XCTAssertEqual(max, 8)
        XCTAssertEqual(direction, "up")
    }

    func testAnArrowInsideTheQuotedLabelDoesNotSplitTheStep() {
        let step = SkillParser.parseStep(#"condition: visible "A -> B" -> tap: Next"#)
        guard case .condition(let check, .tap) = step else {
            return XCTFail("expected a condition, got \(String(describing: step))")
        }
        XCTAssertEqual(check.label, "A -> B")
    }

    func testFreeTextStaysAnAIOnlyStep() {
        let condition = SkillParser.parseStep("condition: if logged out, sign in first")
        let repeated = SkillParser.parseStep("repeat: scroll until the end of the feed")
        XCTAssertEqual(condition?.aiOnlyStepType, "condition")
        XCTAssertEqual(repeated?.aiOnlyStepType, "repeat")
    }

    func testAMalformedStructuredValueIsInvalidAndNamesTheForm() {
        let missingArrow = SkillParser.parseStep(#"condition: visible "Allow" tap: Allow"#)
        let missingMax = SkillParser.parseStep(#"repeat: until visible "Done" -> swipe: up"#)
        for step in [missingArrow, missingMax] {
            guard case .invalid(_, let reason) = step else {
                return XCTFail("expected invalid, got \(String(describing: step))")
            }
            XCTAssertTrue(reason.contains("expected `"), reason)
        }
    }

    func testARepeatBoundOutsideTheLimitIsRefused() {
        for max in [0, ControlFlowSteps.maxRepeatIterations + 1] {
            let step = SkillParser.parseStep(#"repeat: until visible "Done", max \#(max) -> swipe: up"#)
            guard case .invalid(_, let reason) = step else {
                return XCTFail("expected invalid for max \(max), got \(String(describing: step))")
            }
            XCTAssertTrue(reason.contains("max must be between 1 and"), reason)
        }
    }

    func testANestedOrAIOnlyActionIsRefused() {
        let nested = SkillParser.parseStep(
            #"condition: visible "A" -> repeat: until visible "B", max 2 -> swipe: up"#)
        let aiOnly = SkillParser.parseStep(#"condition: visible "A" -> verify: it worked"#)
        guard case .invalid(_, let nestedReason) = nested,
              case .invalid(_, let aiReason) = aiOnly else {
            return XCTFail("expected both invalid: \(String(describing: nested)), \(String(describing: aiOnly))")
        }
        XCTAssertTrue(nestedReason.contains("cannot be nested"), nestedReason)
        XCTAssertTrue(aiReason.contains("needs an AI client"), aiReason)
    }

    // MARK: - Replay values

    func testControlFlowStepsRoundTripThroughTheirReplayValue() {
        let steps: [SkillStep] = [
            .condition(check: ScreenCheck(label: "Allow", visible: true), then: .tap(label: "Allow")),
            .condition(check: ScreenCheck(label: "Say \"hi\"", visible: false), then: .home),
            .condition(check: ScreenCheck(label: "Wait", visible: true),
                       then: .waitFor(label: "Ready", timeoutSeconds: 5)),
            .repeatUntil(check: ScreenCheck(label: "Done", visible: true), maxIterations: 8,
                         body: .swipe(direction: "up")),
            .repeatUntil(check: ScreenCheck(label: "Loading", visible: false), maxIterations: 3,
                         body: .pressKey(keyName: "l", modifiers: ["command"])),
        ]
        for step in steps {
            let rebuilt = SkillParser.parseStep(key: step.typeKey, rawValue: step.replayValue ?? "")
            XCTAssertEqual(String(describing: rebuilt), String(describing: step),
                           "replay value \(step.replayValue ?? "nil")")
        }
    }

    // MARK: - condition

    func testAConditionRunsItsActionWhenTheCheckHolds() {
        describer.describeResult = screen("Allow", "Don't Allow")
        let result = run(#"condition: visible "Allow" -> tap: Allow"#)
        XCTAssertEqual(result?.status, .passed, result?.message ?? "")
        XCTAssertEqual(input.tapCalls.count, 1)
    }

    func testAConditionThatDoesNotHoldPassesWithoutRunningItsAction() {
        describer.describeResult = screen("Home")
        let result = run(#"condition: visible "Allow" -> tap: Allow"#)
        XCTAssertEqual(result?.status, .passed)
        XCTAssertTrue(result?.message?.contains("not run") ?? false, result?.message ?? "")
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testAConditionFailsWhenItsActionFails() {
        describer.describeResult = screen("Allow")
        input.tapResult = "tap was dropped"
        let result = run(#"condition: visible "Allow" -> tap: Allow"#)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertTrue(result?.message?.contains("tap was dropped") ?? false, result?.message ?? "")
    }

    func testAConditionFailsWhenTheScreenCannotBeRead() {
        describer.describeResult = nil
        let result = run(#"condition: visible "Allow" -> tap: Allow"#)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testTheActionGuardStopsAConditionsAction() {
        describer.describeResult = screen("Allow")
        executor.actionGuard = { action in
            StepResult(step: action, status: .failed, message: "blocked by guard", durationSeconds: 0)
        }
        let result = run(#"condition: visible "Allow" -> tap: Allow"#)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertTrue(result?.message?.contains("blocked by guard") ?? false, result?.message ?? "")
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    // MARK: - repeat

    func testARepeatRunsItsBodyUntilTheCheckHolds() {
        describer.describeResults = [screen("Row 1"), screen("Row 2"), screen("Row 3", "Done")]
        let result = run(#"repeat: until visible "Done", max 5 -> tap: @10,20"#)
        XCTAssertEqual(result?.status, .passed, result?.message ?? "")
        XCTAssertEqual(input.tapCalls.count, 2)
        XCTAssertTrue(result?.message?.contains("after 2 run(s)") ?? false, result?.message ?? "")
    }

    func testARepeatWhoseCheckAlreadyHoldsRunsNothing() {
        describer.describeResult = screen("Done")
        let result = run(#"repeat: until visible "Done", max 5 -> tap: @10,20"#)
        XCTAssertEqual(result?.status, .passed)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    func testARepeatFailsAfterItsBoundWithoutRunningMore() {
        describer.describeResult = screen("Loading")
        let result = run(#"repeat: until not visible "Loading", max 3 -> tap: @10,20"#)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(input.tapCalls.count, 3)
        XCTAssertTrue(result?.message?.contains("after 3 run(s)") ?? false, result?.message ?? "")
    }

    func testARepeatStopsAtTheFirstFailedRun() {
        describer.describeResult = screen("Row")
        input.tapResult = "tap was dropped"
        let result = run(#"repeat: until visible "Done", max 5 -> tap: @10,20"#)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertTrue(result?.message?.contains("run 1 of") ?? false, result?.message ?? "")
    }

    func testACancelledCallEndsARepeatBetweenRuns() {
        describer.describeResult = screen("Row")
        let call = MCPCallControl()
        call.cancel(reason: "user stopped it")
        executor.call = call
        let result = run(#"repeat: until visible "Done", max 5 -> tap: @10,20"#)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(result?.message, StepExecutor.cancelledMessage)
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    // MARK: - Permissions

    func testAControlFlowStepNeedsThePermissionOfItsAction() {
        let step = SkillStep.condition(check: ScreenCheck(label: "Allow", visible: true),
                                       then: .tap(label: "Allow"))
        XCTAssertEqual(InlineStepRunner.toolName(of: step), "tap")
        let repeated = SkillStep.repeatUntil(check: ScreenCheck(label: "Done", visible: true),
                                             maxIterations: 2, body: .launch(appName: "Notes"))
        XCTAssertEqual(InlineStepRunner.toolName(of: repeated), "launch_app")
    }
}
