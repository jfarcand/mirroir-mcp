// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pins the compiled skill and per-step screens `mirroir test` writes to fixtures mirroir-run's drift check reads.
// ABOUTME: Regenerates them byte for byte from a stub Clock walk, so either side drifting fails a test.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// mirroir-run compares the screens a `mirroir-mcp test --capture` run reports
/// against the `.compiled.json` a passing `--compiled-out` run recorded next to
/// the scenario. The scenario, the compiled skill a stub Clock walk records from
/// it, and two reports — one whose screens match that skill, one whose step 2
/// screen drifted — are committed under `runner/tests/fixtures/compiled/`; this
/// suite regenerates them from the real writers and fails on any byte of drift.
///
/// Set `MIRROIR_REGENERATE_COMPILED_GOLDEN=1` to rewrite the fixtures after an
/// intended format change, then commit them with the change.
final class CompiledDriftContractTests: XCTestCase {

    private static let regenerateVariable = "MIRROIR_REGENERATE_COMPILED_GOLDEN"
    /// The `cross_surface` key mirroir-run always captures an iOS block under.
    private static let captureKey = "ios"
    /// The block file mirroir-run hands `mirroir-mcp test`.
    private static let blockFile = "ios-block.yaml"
    private static let compiledAt = Date(timeIntervalSince1970: 1_793_318_400)
    /// The World Clock list as a drifted build shows it after the tap: London
    /// listed where Cupertino was.
    private static let driftedWorldClock = ClockWalkDouble.worldClock.map {
        $0 == "Cupertino" ? "London" : $0
    }

    func testCompiledSkillAndReportsMatchTheRunnerGolden() throws {
        let scenario = goldenDir().appendingPathComponent("world-clock.ios.yaml")
        try assertFile(actual: ClockWalkDouble.skillYAML, golden: scenario)

        let skill = try SkillFileLoader.load(filePath: scenario.path)
        let phone = ClockWalkDouble()
        let (result, screens) = phone.run(skill)
        XCTAssertTrue(result.passed, result.failureReasons.joined(separator: "\n"))
        XCTAssertEqual(screens.afterStep.keys.sorted(), [0, 1, 2, 3])

        let compiled = CompiledRunRecord.compiledSkill(
            skill: skill, result: result, screens: screens,
            sourceSHA256: try CompiledSkillIO.sha256(of: scenario.path),
            device: try XCTUnwrap(CompileCommand.deviceInfo(of: phone.bridge)),
            compiledAt: Self.compiledAt)
        let scratch = NSTemporaryDirectory() + "compiled-golden-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try CompiledSkillIO.save(compiled, toPath: scratch)
        try assertFile(
            actual: try String(contentsOfFile: scratch, encoding: .utf8),
            golden: goldenDir().appendingPathComponent("world-clock.ios.compiled.json"))

        try assertFile(actual: try report(result, screens),
                       golden: goldenDir().appendingPathComponent("report-match.json"))

        var drifted = screens
        drifted.afterStep[2] = StructuralFingerprint.buildScreenFingerprint(
            elements: ClockWalkDouble.elements(Self.driftedWorldClock), icons: [])
        XCTAssertNotEqual(drifted.afterStep[2], screens.afterStep[2])
        try assertFile(actual: try report(result, drifted),
                       golden: goldenDir().appendingPathComponent("report-drift.json"))
    }

    // MARK: - Helpers

    /// The report `mirroir-mcp test --report-json --capture ios` writes for the
    /// walk, its duration and block path fixed so the document is reproducible.
    private func report(_ result: ConsoleReporter.SkillResult, _ screens: StepScreens) throws -> String {
        let pinned = ConsoleReporter.SkillResult(
            name: result.name, filePath: Self.blockFile,
            stepResults: result.stepResults, durationSeconds: 1)
        let finalScreen = ScenarioStepFormatter.screenText(
            elements: ClockWalkDouble.elements(ClockWalkDouble.worldClock))
        let data = try PlaywrightReportWriter.document(
            results: [pinned], screenCaptures: [0: finalScreen], captureKey: Self.captureKey,
            stepScreens: [0: screens],
            device: CompileCommand.deviceInfo(of: StubBridge()))
        return String(decoding: data, as: UTF8.self)
    }

    private func goldenDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/tests/fixtures/compiled")
    }

    private var regenerating: Bool {
        ProcessInfo.processInfo.environment[Self.regenerateVariable] == "1"
    }

    private func assertFile(actual: String, golden: URL) throws {
        if regenerating {
            try FileManager.default.createDirectory(
                at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: golden, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: golden, encoding: .utf8)
        XCTAssertEqual(actual, expected,
                       "writer output drifted from \(golden.path) — rerun with " +
                       "\(Self.regenerateVariable)=1 if the change is intended:\n\(actual)")
    }
}
