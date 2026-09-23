// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for PlaywrightReportWriter — the Playwright JSON-reporter shape mirroir-run ingests.
// ABOUTME: Decodes the document the way mirroir-run's report.rs does: status, message, base64 captures.

import XCTest
@testable import mirroir_mcp

final class PlaywrightReportWriterTests: XCTestCase {

    func testPassingSkillReportsPassedWithItsCapture() throws {
        let result = skill("pass", [
            StepResult(step: .launch(appName: "Clock"), status: .passed,
                       message: nil, durationSeconds: 1.2),
        ])
        let run = try firstResult(try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [0: "Alarmes Aucune alarme\n"],
            captureKey: "3"))

        XCTAssertEqual(run["status"] as? String, "passed")
        XCTAssertNil(run["error"])
        let captures = try decodeCaptures(run)
        XCTAssertEqual((captures["cross_surface"] as? [String: String])?["3"],
                       "Alarmes Aucune alarme\n")
    }

    /// The failure message names the failing step by its index in the skill —
    /// the one piece mirroir-run needs to point back into the scenario.
    func testFailingSkillNamesTheStepIndex() throws {
        let result = skill("fail", [
            StepResult(step: .launch(appName: "Clock"), status: .passed,
                       message: nil, durationSeconds: 1),
            StepResult(step: .tap(label: "Alarmes"), status: .failed,
                       message: "not found", durationSeconds: 5),
        ])
        let run = try firstResult(try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [:], captureKey: nil))

        XCTAssertEqual(run["status"] as? String, "failed")
        let message = (run["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, "step 1 (tap: \"Alarmes\"): not found")
        XCTAssertEqual((run["errors"] as? [[String: Any]])?.count, 1)
    }

    /// A skill whose every step was skipped is a failure in the report too.
    func testAllSkippedSkillReportsFailed() throws {
        let result = skill("skipped", [
            StepResult(step: .skipped(stepType: "remember", reason: "AI-only"),
                       status: .skipped, message: nil, durationSeconds: 0),
        ])
        let run = try firstResult(try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [:], captureKey: nil))
        XCTAssertEqual(run["status"] as? String, "failed")
    }

    func testMeasureStepsBecomeMetricsInMilliseconds() throws {
        let result = skill("measure", [
            StepResult(step: .measure(name: "open-alarms", action: .tap(label: "Alarmes"),
                                      until: "Aucune alarme", maxSeconds: nil),
                       status: .passed, message: nil, durationSeconds: 0.25),
        ])
        let run = try firstResult(try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [:], captureKey: nil))
        let metrics = try decodeCaptures(run)["metrics"] as? [String: Double]
        XCTAssertEqual(metrics?["open-alarms"], 250)
    }

    func testFlagsParse() {
        let config = TestRunner.parseArguments(
            ["--report-json", "out/report.json", "--capture", "3", "flow.yaml"])
        XCTAssertEqual(config.reportJSONPath, "out/report.json")
        XCTAssertEqual(config.captureKey, "3")
        XCTAssertEqual(config.skillArgs, ["flow.yaml"])
    }

    /// The contract with mirroir-run, pinned byte for byte: this document is
    /// the fixture `runner/src/target/ios.rs` ingests with the same parser it
    /// runs on Playwright's reports. A change to the writer that the runner
    /// has not been taught fails here, on the Swift side, first.
    func testCanonicalReportMatchesTheRunnerFixture() throws {
        let result = skill("check-alarms", [
            StepResult(step: .launch(appName: "Clock"), status: .passed,
                       message: nil, durationSeconds: 1.0),
            StepResult(step: .tap(label: "Alarmes"), status: .passed,
                       message: nil, durationSeconds: 0.5),
        ])
        let data = try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [0: "Alarmes Aucune alarme\n"], captureKey: "ios")
        let actual = String(decoding: data, as: UTF8.self)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/src/target/fixtures/mirroir-mcp-report.json")
        let expected = try String(contentsOf: fixture, encoding: .utf8)
        XCTAssertEqual(actual, expected, "writer output drifted from the runner fixture:\n\(actual)")
    }

    // MARK: - Helpers

    private func skill(_ name: String, _ steps: [StepResult]) -> ConsoleReporter.SkillResult {
        ConsoleReporter.SkillResult(name: name, filePath: "\(name).yaml",
                                    stepResults: steps, durationSeconds: 1)
    }

    /// Walk suites → specs → tests → results exactly as report.rs does.
    private func firstResult(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let suite = try XCTUnwrap((root["suites"] as? [[String: Any]])?.first)
        let spec = try XCTUnwrap((suite["specs"] as? [[String: Any]])?.first)
        let test = try XCTUnwrap((spec["tests"] as? [[String: Any]])?.first)
        return try XCTUnwrap((test["results"] as? [[String: Any]])?.first)
    }

    private func decodeCaptures(_ result: [String: Any]) throws -> [String: Any] {
        let attachments = try XCTUnwrap(result["attachments"] as? [[String: Any]])
        let captures = try XCTUnwrap(attachments.first {
            $0["name"] as? String == PlaywrightReportWriter.capturesAttachment
        })
        let body = try XCTUnwrap(captures["body"] as? String)
        let raw = try XCTUnwrap(Data(base64Encoded: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }
}
