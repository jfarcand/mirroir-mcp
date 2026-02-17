// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Terminal output formatting for test runner results.
// ABOUTME: Prints per-step results, per-scenario summaries, and a final summary line.

import Foundation

/// Formats and prints test results to the terminal.
enum ConsoleReporter {

    /// Result of running a single scenario.
    struct ScenarioResult {
        let name: String
        let filePath: String
        let stepResults: [StepResult]
        let durationSeconds: Double
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

    /// Print a scenario header before execution starts.
    static func reportScenarioStart(name: String, filePath: String, stepCount: Int) {
        fputs("\nScenario: \(name) (\(stepCount) steps)\n", stderr)
        fputs("  File: \(filePath)\n", stderr)
    }

    /// Print a scenario summary after execution.
    static func reportScenarioEnd(result: ScenarioResult) {
        let passed = result.stepResults.filter { $0.status == .passed }.count
        let failed = result.stepResults.filter { $0.status == .failed }.count
        let skipped = result.stepResults.filter { $0.status == .skipped }.count
        let duration = String(format: "%.1fs", result.durationSeconds)

        let overallStatus: String
        if failed > 0 {
            overallStatus = "FAIL"
        } else {
            overallStatus = "PASS"
        }

        fputs("  Result: \(overallStatus) (\(duration)) — \(passed) passed, \(failed) failed, \(skipped) skipped\n", stderr)
    }

    /// Print a final summary across all scenarios.
    static func reportSummary(results: [ScenarioResult]) {
        let totalScenarios = results.count
        let passedScenarios = results.filter { scenarioResult in
            !scenarioResult.stepResults.contains { $0.status == .failed }
        }.count
        let failedScenarios = totalScenarios - passedScenarios

        let totalSteps = results.flatMap { $0.stepResults }.count
        let passedSteps = results.flatMap { $0.stepResults }.filter { $0.status == .passed }.count
        let failedSteps = results.flatMap { $0.stepResults }.filter { $0.status == .failed }.count
        let skippedSteps = results.flatMap { $0.stepResults }.filter { $0.status == .skipped }.count

        fputs("\n", stderr)
        fputs("Summary: \(totalScenarios) scenario(s), \(totalSteps) step(s)\n", stderr)
        fputs("  Scenarios — PASSED: \(passedScenarios), FAILED: \(failedScenarios)\n", stderr)
        fputs("  Steps — PASSED: \(passedSteps), FAILED: \(failedSteps), SKIPPED: \(skippedSteps)\n", stderr)

        if failedScenarios > 0 {
            fputs("\nFailed scenarios:\n", stderr)
            for result in results where result.stepResults.contains(where: { $0.status == .failed }) {
                fputs("  - \(result.name)\n", stderr)
                for stepResult in result.stepResults where stepResult.status == .failed {
                    fputs("    \(stepResult.step.displayName): \(stepResult.message ?? "unknown error")\n", stderr)
                }
            }
        }
    }

    /// Format a status as a human-readable tag.
    static func formatStatus(_ status: StepResult.StepStatus) -> String {
        status.rawValue
    }
}
