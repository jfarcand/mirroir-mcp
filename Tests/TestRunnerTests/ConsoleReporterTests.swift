// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ConsoleReporter: status formatting and summary counts.
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
        let passedSkills = results.filter { skillResult in
            !skillResult.stepResults.contains { $0.status == .failed }
        }.count

        XCTAssertEqual(passedSkills, 1)
    }
}
