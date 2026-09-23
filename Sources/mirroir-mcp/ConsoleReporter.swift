// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Terminal output formatting for test runner results.
// ABOUTME: Prints per-step results, per-skill summaries, and a final summary line.

import Foundation

/// Formats and prints test results to the terminal.
enum ConsoleReporter {

    /// Result of running a single skill.
    struct SkillResult {
        let name: String
        let filePath: String
        let stepResults: [StepResult]
        let durationSeconds: Double

        /// A skill passes only when no step failed AND at least one step
        /// actually passed. A skill whose every step was skipped evaluated
        /// nothing, so it is not a pass.
        var passed: Bool {
            !stepResults.contains { $0.status == .failed }
                && stepResults.contains { $0.status == .passed }
        }

        /// Why a skill that did not pass failed: every failed step, named by its
        /// index in the skill, or why nothing ran.
        var failureReasons: [String] {
            let failedSteps = stepResults.enumerated().filter { $0.element.status == .failed }
            if failedSteps.isEmpty {
                return ["no step executed: every step was skipped"]
            }
            return failedSteps.map { index, result in
                "step \(index) (\(result.step.displayName)): \(result.message ?? "unknown error")"
            }
        }
    }

    /// Print a single step result during execution.
    static func reportStep(index: Int, total: Int, result: StepResult, verbose: Bool) {
        let statusTag = formatStatus(result.status)
        let duration = String(format: "%.1fs", result.durationSeconds)
        let stepName = result.step.displayName

        var line = "  [\(index + 1)/\(total)] \(stepName)  \(statusTag) (\(duration))"

        if verbose, let message = result.message, !message.isEmpty {
            line += " — \(message)"
        }

        fputs(line + "\n", stderr)
    }

    /// Print a skill header before execution starts.
    static func reportSkillStart(name: String, filePath: String, stepCount: Int) {
        fputs("\nSkill: \(name) (\(stepCount) steps)\n", stderr)
        fputs("  File: \(filePath)\n", stderr)
    }

    /// Print a skill summary after execution.
    static func reportSkillEnd(result: SkillResult) {
        let passed = result.stepResults.filter { $0.status == .passed }.count
        let failed = result.stepResults.filter { $0.status == .failed }.count
        let skipped = result.stepResults.filter { $0.status == .skipped }.count
        let duration = String(format: "%.1fs", result.durationSeconds)

        let overallStatus = result.passed ? "PASS" : "FAIL"

        fputs("  Result: \(overallStatus) (\(duration)) — \(passed) passed, \(failed) failed, \(skipped) skipped\n", stderr)
    }

    /// Print a final summary across all skills.
    static func reportSummary(results: [SkillResult]) {
        let totalSkills = results.count
        let passedSkills = results.filter(\.passed).count
        let failedSkills = totalSkills - passedSkills

        let totalSteps = results.flatMap { $0.stepResults }.count
        let passedSteps = results.flatMap { $0.stepResults }.filter { $0.status == .passed }.count
        let failedSteps = results.flatMap { $0.stepResults }.filter { $0.status == .failed }.count
        let skippedSteps = results.flatMap { $0.stepResults }.filter { $0.status == .skipped }.count

        fputs("\n", stderr)
        fputs("Summary: \(totalSkills) skill(s), \(totalSteps) step(s)\n", stderr)
        fputs("  Skills — PASSED: \(passedSkills), FAILED: \(failedSkills)\n", stderr)
        fputs("  Steps — PASSED: \(passedSteps), FAILED: \(failedSteps), SKIPPED: \(skippedSteps)\n", stderr)

        if failedSkills > 0 {
            fputs("\nFailed skills:\n", stderr)
            for result in results where !result.passed {
                fputs("  - \(result.name)\n", stderr)
                for reason in result.failureReasons {
                    fputs("    \(reason)\n", stderr)
                }
            }
        }
    }

    /// Format a status as a human-readable tag.
    static func formatStatus(_ status: StepResult.StepStatus) -> String {
        status.rawValue
    }
}
