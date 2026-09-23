// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ConsoleReporter: status formatting, summary counts, and the skill verdict.
// ABOUTME: Verifies formatting consistency across pass, fail, and skip statuses.

import XCTest
@testable import mirroir_mcp

final class ConsoleReporterTests: XCTestCase {

    // MARK: - Status Formatting

    func testFormatStatusPassed() {
        XCTAssertEqual(ConsoleReporter.formatStatus(.passed), "PASS")
    }

    func testFormatStatusFailed() {
        XCTAssertEqual(ConsoleReporter.formatStatus(.failed), "FAIL")
    }

    func testFormatStatusSkipped() {
        XCTAssertEqual(ConsoleReporter.formatStatus(.skipped), "SKIP")
    }

    // MARK: - SkillResult Counts

    func testSkillResultCountsAllPass() {
        let steps = [
            StepResult(step: .home, status: .passed, message: nil, durationSeconds: 0.1),
            StepResult(step: .shake, status: .passed, message: nil, durationSeconds: 0.2),
        ]
        let result = ConsoleReporter.SkillResult(
            name: "Test", filePath: "test.yaml",
            stepResults: steps, durationSeconds: 0.5)

        let passed = result.stepResults.filter { $0.status == .passed }.count
        let failed = result.stepResults.filter { $0.status == .failed }.count
        let skipped = result.stepResults.filter { $0.status == .skipped }.count

        XCTAssertEqual(passed, 2)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(skipped, 0)
    }

    func testSkillResultCountsMixed() {
        let steps = [
            StepResult(step: .home, status: .passed, message: nil, durationSeconds: 0.1),
            StepResult(step: .tap(label: "X"), status: .failed,
                       message: "Not found", durationSeconds: 0.2),
            StepResult(step: .skipped(stepType: "remember", reason: "AI-only"),
                       status: .skipped, message: "AI-only", durationSeconds: 0.0),
        ]
        let result = ConsoleReporter.SkillResult(
            name: "Mixed", filePath: "test.yaml",
            stepResults: steps, durationSeconds: 0.5)

        let passed = result.stepResults.filter { $0.status == .passed }.count
        let failed = result.stepResults.filter { $0.status == .failed }.count
        let skipped = result.stepResults.filter { $0.status == .skipped }.count

        XCTAssertEqual(passed, 1)
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(skipped, 1)
    }

    // MARK: - Summary Logic

    func testSummaryPassedSkillsCount() {
        let allPass = ConsoleReporter.SkillResult(
            name: "Pass", filePath: "p.yaml",
            stepResults: [StepResult(step: .home, status: .passed,
                                     message: nil, durationSeconds: 0.1)],
            durationSeconds: 0.2)
        let withFail = ConsoleReporter.SkillResult(
            name: "Fail", filePath: "f.yaml",
            stepResults: [StepResult(step: .tap(label: "X"), status: .failed,
                                     message: "err", durationSeconds: 0.1)],
            durationSeconds: 0.2)

        let results = [allPass, withFail]
        XCTAssertEqual(results.filter(\.passed).count, 1)
    }

    // MARK: - Skill Verdict

    /// A skill whose every step was skipped evaluated nothing. It used to
    /// report PASS and exit 0 — including for a scenario whose only steps were
    /// verbs the parser did not recognize.
    func testAllSkippedSkillIsNotAPass() {
        let result = ConsoleReporter.SkillResult(
            name: "Skipped", filePath: "s.yaml",
            stepResults: [
                StepResult(step: .skipped(stepType: "cross_surface", reason: "Unknown step type"),
                           status: .skipped, message: "Unknown step type", durationSeconds: 0),
                StepResult(step: .skipped(stepType: "remember", reason: "AI-only"),
                           status: .skipped, message: "AI-only", durationSeconds: 0),
            ],
            durationSeconds: 0.1)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons, ["no step executed: every step was skipped"])
    }

    func testSkillWithNoStepsIsNotAPass() {
        let result = ConsoleReporter.SkillResult(
            name: "Empty", filePath: "e.yaml", stepResults: [], durationSeconds: 0)

        XCTAssertFalse(result.passed)
    }

    /// The companion: skipped AI-only steps beside a step that ran and passed
    /// are still a pass, so the fix does not fail every skill with a skip.
    func testSkippedStepsBesideAPassedStepStillPass() {
        let result = ConsoleReporter.SkillResult(
            name: "Mixed", filePath: "m.yaml",
            stepResults: [
                StepResult(step: .home, status: .passed, message: nil, durationSeconds: 0.1),
                StepResult(step: .skipped(stepType: "remember", reason: "AI-only"),
                           status: .skipped, message: "AI-only", durationSeconds: 0),
            ],
            durationSeconds: 0.2)

        XCTAssertTrue(result.passed)
    }

    func testFailureReasonsNameTheFailedStep() {
        let result = ConsoleReporter.SkillResult(
            name: "Fail", filePath: "f.yaml",
            stepResults: [StepResult(step: .tap(label: "X"), status: .failed,
                                     message: "not found", durationSeconds: 0.1)],
            durationSeconds: 0.2)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons.count, 1)
        XCTAssertTrue(result.failureReasons[0].hasSuffix("not found"))
    }
}
