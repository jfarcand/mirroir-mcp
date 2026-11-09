// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Runs a list of skill steps handed over in one MCP call, through the same StepExecutor `mirroir test` uses.
// ABOUTME: Every step is checked against the permission policy before the first one runs; the run stops at the first failure.

import Foundation
import HelperLib

/// Runs skill steps that an agent has already proven, in one call, so a
/// sequence like "tap Search, type calculator, wait for Get" costs one round
/// trip instead of three. The steps use the skill grammar (`tap: Rechercher`,
/// `type: calculator`, `wait_for: Get`, `home`), parsed by `SkillParser`.
enum InlineStepRunner {

    /// What a run did: one line per step, then the text the screen shows after it.
    struct Report {
        let results: [StepResult]
        let screenText: String?

        var failed: Bool { results.contains { $0.status.isFailure } }

        /// The report as the agent reads it.
        var text: String {
            var lines = results.enumerated().map { index, result in
                let seconds = String(format: "%.1f", result.durationSeconds)
                let message = result.message.map { " — \($0)" } ?? ""
                return "\(index + 1). \(result.status.rawValue) \(result.step.displayName) (\(seconds)s)\(message)"
            }
            if let screenText {
                lines.append("")
                lines.append("Screen now: \(screenText)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Why a list of steps was refused before any of them ran.
    enum Refusal: Error, Equatable {
        case empty
        case unparsable(index: Int, raw: String, reason: String)
        case notInline(index: Int, step: String)
        case denied(index: Int, step: String, reason: String)

        var message: String {
            switch self {
            case .empty:
                return "No steps given. Pass steps such as [\"tap: @324,113\", \"type: calculator\"]."
            case .unparsable(let index, let raw, let reason):
                return "Step \(index + 1) \"\(raw)\" is not a step: \(reason). Nothing was run."
            case .notInline(let index, let step):
                return "Step \(index + 1) \(step) needs an AI client or a saved skill and cannot run "
                    + "inline. Nothing was run."
            case .denied(let index, let step, let reason):
                return "Step \(index + 1) \(step) is not allowed: \(reason) Nothing was run."
            }
        }
    }

    /// Parse every raw step and check each against `policy`. A single bad or
    /// denied step refuses the whole list, so nothing runs half way.
    static func prepare(_ rawSteps: [String], policy: PermissionPolicy) -> Result<[SkillStep], Refusal> {
        guard !rawSteps.isEmpty else { return .failure(.empty) }
        var steps: [SkillStep] = []
        for (index, raw) in rawSteps.enumerated() {
            guard let step = SkillParser.parseStep(raw) else {
                return .failure(.unparsable(index: index, raw: raw, reason: "empty step"))
            }
            switch step {
            case .invalid(_, let reason):
                return .failure(.unparsable(index: index, raw: raw, reason: reason))
            case .skipped, .scene, .measure(_, .scene, _, _):
                return .failure(.notInline(index: index, step: step.displayName))
            default:
                break
            }
            if let denial = denial(for: step, policy: policy) {
                return .failure(.denied(index: index, step: step.displayName, reason: denial))
            }
            steps.append(step)
        }
        return .success(steps)
    }

    /// Run `steps` in order on `executor`, skipping the rest after a failure,
    /// then read the screen once.
    static func run(_ steps: [SkillStep], executor: StepExecutor) -> Report {
        var results: [StepResult] = []
        for (index, step) in steps.enumerated() {
            if results.last?.status.isFailure == true {
                results.append(StepResult(step: step, status: .skipped,
                                          message: "skipped after the failure above",
                                          durationSeconds: 0))
                continue
            }
            results.append(executor.execute(step: step, stepIndex: index, skillName: runName))
        }
        // Unlabeled icons carry a placeholder name, not text the screen shows.
        let screen = executor.describer.describe()
            .map { result in
                ScenarioStepFormatter.screenText(
                    elements: result.elements.filter { $0.text != CoreMLElementDetector.iconLabel })
                .trimmingCharacters(in: .whitespacesAndNewlines) }
        return Report(results: results, screenText: screen)
    }

    /// The executor for a run on `ctx`: the target's own input and OCR, with
    /// failure screenshots kept out of the server's working directory.
    static func executor(for ctx: TargetContext, registry: TargetRegistry) -> StepExecutor {
        let defaults = StepExecutorConfig.default
        let config = StepExecutorConfig(
            waitForTimeoutSeconds: defaults.waitForTimeoutSeconds,
            settlingDelayMs: defaults.settlingDelayMs,
            screenshotDir: (NSTemporaryDirectory() as NSString).appendingPathComponent(runName),
            dryRun: false)
        return StepExecutor(bridge: ctx.bridge, input: ctx.input,
                            describer: ctx.describer, capture: ctx.capture,
                            config: config, registry: registry,
                            ocrDescriber: ctx.ocrDescriber, profile: ctx.profile)
    }

    /// The name failure screenshots are filed under.
    static let runName = "run_steps"

    /// Why `policy` refuses `step`, or nil when it may run.
    private static func denial(for step: SkillStep, policy: PermissionPolicy) -> String? {
        if case .denied(let reason) = policy.checkTool(toolName(of: step)) { return reason }
        switch step {
        case .launch(let app), .resetApp(let app):
            if case .denied(let reason) = policy.checkAppLaunch(app) { return reason }
        case .measure(_, let action, _, _):
            return denial(for: action, policy: policy)
        default:
            break
        }
        return nil
    }

    /// The MCP tool whose permission a step needs: the tool that does the same
    /// thing when the agent calls it on its own.
    static func toolName(of step: SkillStep) -> String {
        switch step {
        case .launch: return "launch_app"
        case .tap: return "tap"
        case .type: return "type_text"
        case .pressKey: return "press_key"
        case .swipe: return "swipe"
        case .waitFor, .assertVisible, .assertNotVisible: return "describe_screen"
        case .screenshot: return "screenshot"
        case .home: return "press_home"
        case .openURL: return "open_url"
        case .shake: return "shake"
        case .scrollTo: return "scroll_to"
        case .resetApp: return "reset_app"
        case .setNetwork: return "set_network"
        case .measure: return "measure"
        case .longPress: return "long_press"
        case .drag: return "drag"
        case .switchTarget: return "switch_target"
        case .scene, .skipped, .invalid: return "run_steps"
        }
    }
}
