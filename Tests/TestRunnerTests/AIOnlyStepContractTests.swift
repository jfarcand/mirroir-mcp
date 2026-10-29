// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pins the AI-only step seam between mirroir-mcp and mirroir-run to shared fixtures in runner/.
// ABOUTME: The AI-only kinds list, and the byte-exact report a skill with a not-evaluated step produces.

import XCTest
@testable import mirroir_mcp

/// mirroir-run refuses an AI-only step inside an `ios` block and reads the
/// report `mirroir-mcp test` writes. Both depend on what Swift calls AI-only
/// and how it reports one, so each is pinned to a file the Rust tests read too.
final class AIOnlyStepContractTests: XCTestCase {

    /// `SkillParser.aiOnlyStepTypes` is exactly the list the runner's
    /// `AI_ONLY_STEP_KINDS` is pinned to (runner/src/parser/surface.rs).
    func testAIOnlyStepTypesMatchTheRunnerFixture() throws {
        let data = try Data(contentsOf: runnerFixture("ai-only-step-kinds.json"))
        let kinds = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(kinds, kinds.sorted(), "fixture must stay sorted")
        XCTAssertEqual(Set(kinds), SkillParser.aiOnlyStepTypes)
        XCTAssertEqual(kinds.count, SkillParser.aiOnlyStepTypes.count)
    }

    /// A skill whose device steps pass but which holds an AI-only step reports
    /// failed, carrying the not-evaluated reason. The runner's report ingest
    /// test reads this same file and must count it as a failure.
    func testNotEvaluatedReportMatchesTheRunnerFixture() throws {
        let verify = SkillStep.skipped(
            stepType: "verify", reason: "AI-only step — requires human interpretation")
        let result = ConsoleReporter.SkillResult(
            name: "check-alarms", filePath: "check-alarms.yaml",
            stepResults: [
                StepResult(step: .launch(appName: "Clock"), status: .passed,
                           message: nil, durationSeconds: 0.5),
                .notEvaluated(verify, stepType: "verify"),
                StepResult(step: .tap(label: "Alarmes"), status: .passed,
                           message: nil, durationSeconds: 0.5),
            ],
            durationSeconds: 1)
        XCTAssertFalse(result.passed)
        let data = try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [0: "Alarmes Aucune alarme\n"], captureKey: "ios")
        let actual = String(decoding: data, as: UTF8.self)
        let expected = try String(
            contentsOf: runnerFixture("mirroir-mcp-report-not-evaluated.json"), encoding: .utf8)
        XCTAssertEqual(actual, expected, "writer output drifted from the runner fixture:\n\(actual)")
    }

    // MARK: - Helpers

    private func runnerFixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/src/target/fixtures")
            .appendingPathComponent(name)
    }
}
