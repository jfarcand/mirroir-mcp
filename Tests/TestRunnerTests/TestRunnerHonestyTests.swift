// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Proves `mirroir test` reports only what it checked: it never rewrites a .compiled.json,
// ABOUTME: and an AI-only step it cannot evaluate fails the skill with a distinct reason, live or compiled.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class TestRunnerHonestyTests: XCTestCase {

    private var tmpDir = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = NSTemporaryDirectory() + "runner-honesty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func write(_ name: String, _ content: String) throws -> String {
        let path = tmpDir + "/" + name
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A fresh compiled file for `skillPath` whose start-screen fingerprint matches
    /// no screen a run will see, saved at `width`x`height`.
    private func saveCompiled(for skillPath: String, width: Double, height: Double) throws {
        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: try CompiledSkillIO.sha256(of: skillPath),
                               compiledAt: "2026-10-29T00:00:00Z"),
            device: DeviceInfo(windowWidth: width, windowHeight: height, orientation: "portrait"),
            steps: [CompiledStep(index: 0, type: "home", label: nil, hints: .passthrough())],
            screenFingerprint: ScreenFingerprint(
                hash: "unrelated", structuralTexts: ["Nothing", "Like", "This"], iconCount: 9))
        try CompiledSkillIO.save(compiled, for: skillPath)
    }

    private func compiledBytes(for skillPath: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: CompiledSkillIO.compiledPath(for: skillPath)))
    }

    // MARK: - A test run never writes a compiled skill

    func testSelectingCompiledSkillsNeverWritesThem() throws {
        let fresh = try write("fresh.yaml", "name: Fresh\nsteps:\n  - home\n")
        let stale = try write("stale.yaml", "name: Stale\nsteps:\n  - home\n")
        try saveCompiled(for: fresh, width: 430, height: 942)
        try saveCompiled(for: stale, width: 320, height: 480)
        let freshBefore = CompiledSkillIO.sha256(data: try compiledBytes(for: fresh))
        let staleBefore = CompiledSkillIO.sha256(data: try compiledBytes(for: stale))

        let selected = TestRunner.freshCompiledSkills(
            for: [try SkillFileLoader.load(filePath: fresh), try SkillFileLoader.load(filePath: stale)],
            windowWidth: 430, windowHeight: 942)

        XCTAssertNotNil(selected[fresh], "a fingerprint unlike the live screen never refuses it")
        XCTAssertNil(selected[stale], "a window mismatch runs the skill on live OCR")
        XCTAssertEqual(CompiledSkillIO.sha256(data: try compiledBytes(for: fresh)), freshBefore)
        XCTAssertEqual(CompiledSkillIO.sha256(data: try compiledBytes(for: stale)), staleBefore)
    }

    func testMirroirTestRunLeavesTheCompiledFileByteForByte() throws {
        let skill = try write("flow.yaml", "name: Flow\nsteps:\n  - home\n")
        try saveCompiled(for: skill, width: 0, height: 0)
        let before = CompiledSkillIO.sha256(data: try compiledBytes(for: skill))

        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", skill]), 0)

        XCTAssertEqual(CompiledSkillIO.sha256(data: try compiledBytes(for: skill)), before)
    }

    // MARK: - AI-only steps are not evaluated, so the skill does not pass

    private func executor() -> StepExecutor {
        StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: StubDescriber(),
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: false))
    }

    func testEveryAIOnlyStepTypeIsNotEvaluatedLive() {
        for stepType in SkillParser.aiOnlyStepTypes.sorted() {
            let step = SkillParser.parseStep(key: stepType, rawValue: "the total is shown")
            let result = executor().execute(step: step, stepIndex: 0, skillName: "s")
            XCTAssertEqual(result.status, .notEvaluated, stepType)
            XCTAssertEqual(result.message, "not evaluated: \(stepType) needs an AI client")
        }
    }

    func testAIOnlyStepIsNotEvaluatedInADryRunEither() {
        let dryRun = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: StubDescriber(),
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: true))
        let result = dryRun.execute(step: SkillParser.parseStep(key: "verify", rawValue: "x"),
                                    stepIndex: 0, skillName: "s")
        XCTAssertEqual(result.status, .notEvaluated)
    }

    func testAIOnlyStepIsNotEvaluatedFromACompiledSkill() {
        let compiledExecutor = CompiledStepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: StubDescriber(),
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: false))
        let result = compiledExecutor.execute(
            step: SkillParser.parseStep(key: "remember", rawValue: "the order id"),
            compiledStep: CompiledStep(index: 0, type: "remember", label: "the order id", hints: nil),
            stepIndex: 0, skillName: "s")
        XCTAssertEqual(result.status, .notEvaluated)
        XCTAssertEqual(result.message, "not evaluated: remember needs an AI client")
    }

    /// A skill whose device steps pass but which holds a `verify:` fails, names the
    /// reason, and still runs the steps after it.
    func testSkillWithAVerifyStepFailsWithTheNotEvaluatedReason() {
        let skill = SkillDefinition(
            name: "Checkout", description: "", filePath: tmpDir + "/checkout.yaml",
            steps: [.home, SkillParser.parseStep(key: "verify", rawValue: "total is $5"), .home],
            targets: [], kind: "")

        let result = TestRunner.executeSkill(skill: skill, executor: executor(), verbose: false)

        XCTAssertEqual(result.stepResults.map(\.status), [.passed, .notEvaluated, .passed])
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failureReasons,
                       ["step 1 (verify (skipped)): not evaluated: verify needs an AI client"])
    }

    func testReportCarriesTheNotEvaluatedReasonAsAFailure() throws {
        let skill = SkillDefinition(
            name: "Checkout", description: "", filePath: "checkout.yaml",
            steps: [.home, SkillParser.parseStep(key: "remember", rawValue: "order id")],
            targets: [], kind: "")
        let result = TestRunner.executeSkill(skill: skill, executor: executor(), verbose: false)

        let data = try PlaywrightReportWriter.document(
            results: [result], screenCaptures: [:], captureKey: nil)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let suite = try XCTUnwrap((root["suites"] as? [[String: Any]])?.first)
        let spec = try XCTUnwrap((suite["specs"] as? [[String: Any]])?.first)
        let test = try XCTUnwrap((spec["tests"] as? [[String: Any]])?.first)
        let run = try XCTUnwrap((test["results"] as? [[String: Any]])?.first)

        XCTAssertEqual(spec["ok"] as? Bool, false)
        XCTAssertEqual(test["status"] as? String, "unexpected")
        XCTAssertEqual(run["status"] as? String, "failed")
        XCTAssertEqual((run["error"] as? [String: Any])?["message"] as? String,
                       "step 1 (remember (skipped)): not evaluated: remember needs an AI client")
    }

    func testJUnitCountsANotEvaluatedStepAsAFailure() {
        let skill = SkillDefinition(
            name: "Checkout", description: "", filePath: "checkout.yaml",
            steps: [.home, SkillParser.parseStep(key: "condition", rawValue: "if logged in")],
            targets: [], kind: "")
        let result = TestRunner.executeSkill(skill: skill, executor: executor(), verbose: false)

        let xml = JUnitReporter.generateXML(results: [result])

        XCTAssertTrue(xml.contains("failures=\"1\""), xml)
        XCTAssertTrue(xml.contains("<failure message=\"not evaluated: condition needs an AI client\""),
                      xml)
    }
}
