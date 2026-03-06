// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: E2E integration tests for compiled assertions and staleness detection against FakeMirroring.
// ABOUTME: Validates that compiled skills perform real OCR assertions and detect content drift.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

/// Integration tests for compiled skill assertions and staleness detection.
/// Exercises the full compiled pipeline against FakeMirroring: compile → assertion hints → real OCR.
///
/// Run with: `swift test --filter CompiledSkillIntegrationTests`
///
/// FakeMirroring must be running:
///   `swift build -c release --product FakeMirroring && ./scripts/package-fake-app.sh`
///   `open .build/release/FakeMirroring.app`
final class CompiledSkillIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var describer: ScreenDescriber!
    private var capture: ScreenCapture!
    private var input: InputSimulation!

    override func setUpWithError() throws {
        try super.setUpWithError()

        guard IntegrationTestHelper.isFakeMirroringRunning else {
            XCTFail(
                "FakeMirroring app is not running. "
                + "Launch it with: open .build/release/FakeMirroring.app"
            )
            return
        }

        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
        input = InputSimulation(bridge: bridge)

        // Ensure window is capturable before each test — heavy OCR in prior tests
        // can cause CGWindowList to transiently lose the window.
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            XCTFail("FakeMirroring window not capturable after retries")
            return
        }

        // Ensure we're on the default "Settings" scenario and window is settled
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(1_000_000)
    }

    override func tearDown() {
        // Restore default scenario and ensure window is recovered for subsequent test classes
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    // MARK: - Compiled Assertion Tests

    func testCompiledAssertionPassesWithRealOCR() {
        // Parse an inline skill with assertions
        let yaml = """
        name: assertion test
        app: FakeMirroring
        description: test

        steps:
          - wait_for: "Settings"
          - assert_visible: "General"
          - assert_not_visible: "Instagram"
        """

        let tmpPath = writeTempYAML(yaml)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Compile the skill
        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: testExecutorConfig()
        )

        let skill = SkillParser.parse(content: yaml, filePath: tmpPath)
        let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: tmpPath,
            windowWidth: windowDimensions().width,
            windowHeight: windowDimensions().height,
            orientation: "portrait"
        )

        XCTAssertNotNil(compiled, "Skill should compile successfully against FakeMirroring")
        guard let compiled = compiled else { return }

        // Verify assertion steps got .assertion hints (not .sleep)
        let assertionSteps = compiled.steps.filter {
            $0.hints?.compiledAction == .assertion
        }
        XCTAssertEqual(assertionSteps.count, 2,
                       "assert_visible and assert_not_visible should produce .assertion hints")

        // Execute compiled steps — assertions should pass with real OCR
        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: testExecutorConfig()
        )

        for compiledStep in compiled.steps {
            let step = skill.steps[compiledStep.index]
            let result = compiledExecutor.execute(
                step: step, compiledStep: compiledStep,
                stepIndex: compiledStep.index, skillName: skill.name
            )
            XCTAssertEqual(result.status, .passed,
                           "Step '\(compiledStep.type)' should pass: \(result.message ?? "")")
        }
    }

    func testCompiledAssertionFailsWhenElementMissing() {
        let step = SkillStep.assertVisible(label: "NonExistentElement")
        let compiledStep = CompiledStep(
            index: 0, type: "assert_visible",
            label: "NonExistentElement",
            hints: .assertion(delayMs: 0)
        )

        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: testExecutorConfig()
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test"
        )

        XCTAssertEqual(result.status, .failed,
                       "assert_visible for non-existent element should fail")
        XCTAssertNotNil(result.message)
        let msg = result.message?.lowercased() ?? ""
        XCTAssertTrue(msg.contains("visible") || msg.contains("not found"),
                      "Error message should mention visibility: \(result.message ?? "")")
    }

    func testCompiledAssertNotVisibleFailsWhenPresent() {
        let step = SkillStep.assertNotVisible(label: "General")
        let compiledStep = CompiledStep(
            index: 0, type: "assert_not_visible",
            label: "General",
            hints: .assertion(delayMs: 0)
        )

        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: testExecutorConfig()
        )

        let result = compiledExecutor.execute(
            step: step, compiledStep: compiledStep,
            stepIndex: 0, skillName: "test"
        )

        XCTAssertEqual(result.status, .failed,
                       "assert_not_visible for 'General' should fail (it IS visible on Settings screen)")
    }

    // MARK: - Screen Fingerprint Tests

    func testScreenFingerprintMatchesSameScreen() {
        guard let result1 = describeWithRetry() else {
            XCTFail("First describe() returned nil")
            return
        }
        guard let result2 = describeWithRetry() else {
            XCTFail("Second describe() returned nil")
            return
        }

        let fp1 = StructuralFingerprint.buildScreenFingerprint(
            elements: result1.elements, icons: result1.icons)
        let fp2 = StructuralFingerprint.buildScreenFingerprint(
            elements: result2.elements, icons: result2.icons)

        let similarity = StructuralFingerprint.screenFingerprintSimilarity(fp1, fp2)
        XCTAssertGreaterThanOrEqual(similarity, 0.8,
                                     "Same screen captured twice should have similarity >= 0.8, got \(similarity)")
    }

    func testScreenFingerprintDetectsDriftAfterScenarioSwitch() {
        // Capture fingerprint on "Settings" scenario
        guard let settingsResult = describeWithRetry() else {
            XCTFail("describe() on Settings returned nil")
            return
        }
        let settingsFP = StructuralFingerprint.buildScreenFingerprint(
            elements: settingsResult.elements, icons: settingsResult.icons)

        // Switch to "Settings (Updated)" — same header, different rows
        let switched = bridge.triggerMenuAction(menu: "Scenario", item: "Settings (Updated)")
        XCTAssertTrue(switched, "Should switch to 'Settings (Updated)' scenario via menu")
        usleep(1_000_000) // Wait 1s for redraw

        guard let updatedResult = describeWithRetry() else {
            XCTFail("describe() on Settings (Updated) returned nil")
            return
        }
        let updatedFP = StructuralFingerprint.buildScreenFingerprint(
            elements: updatedResult.elements, icons: updatedResult.icons)

        let similarity = StructuralFingerprint.screenFingerprintSimilarity(settingsFP, updatedFP)
        XCTAssertLessThan(similarity, 0.8,
                          "Settings vs Settings (Updated) should have drifted (similarity \(similarity) should be < 0.8)")
    }

    // MARK: - Full Pipeline Tests

    func testFullCompileAndTestPipeline() {
        let yaml = """
        name: pipeline test
        app: FakeMirroring
        description: test

        steps:
          - wait_for: "Settings"
          - assert_visible: "General"
          - assert_visible: "Display"
          - assert_not_visible: "NonExistent"
          - screenshot: "pipeline"
        """

        let tmpPath = writeTempYAML(yaml)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: testExecutorConfig()
        )

        let skill = SkillParser.parse(content: yaml, filePath: tmpPath)
        let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: tmpPath,
            windowWidth: windowDimensions().width,
            windowHeight: windowDimensions().height,
            orientation: "portrait"
        )

        XCTAssertNotNil(compiled, "Skill should compile successfully")
        guard let compiled = compiled else { return }

        // Verify screen fingerprint was captured
        XCTAssertNotNil(compiled.screenFingerprint,
                        "Compiled skill should have a screen fingerprint from first OCR result")

        // Verify assertion steps have .assertion action
        let assertionSteps = compiled.steps.filter {
            $0.hints?.compiledAction == .assertion
        }
        XCTAssertEqual(assertionSteps.count, 3,
                       "3 assertion steps should have .assertion action")

        // Check staleness — should be fresh
        let windowInfo = bridge.getWindowInfo()
        XCTAssertNotNil(windowInfo)
        guard let windowInfo = windowInfo else { return }

        guard let liveResult = describeWithRetry() else {
            XCTFail("Live describe() returned nil")
            return
        }
        let liveFP = StructuralFingerprint.buildScreenFingerprint(
            elements: liveResult.elements, icons: liveResult.icons)

        let staleness = CompiledSkillIO.checkStaleness(
            compiled: compiled,
            skillPath: tmpPath,
            windowWidth: Double(windowInfo.size.width),
            windowHeight: Double(windowInfo.size.height),
            liveFingerprint: liveFP
        )
        XCTAssertEqual(staleness, .fresh,
                       "Compiled skill should be fresh when nothing has changed")

        // Execute all compiled steps
        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: testExecutorConfig()
        )

        for compiledStep in compiled.steps {
            let step = skill.steps[compiledStep.index]
            let result = compiledExecutor.execute(
                step: step, compiledStep: compiledStep,
                stepIndex: compiledStep.index, skillName: skill.name
            )
            XCTAssertEqual(result.status, .passed,
                           "Compiled step '\(compiledStep.type)' should pass: \(result.message ?? "")")
        }
    }

    func testStalenessCheckReturnsDriftedAfterScenarioSwitch() {
        let yaml = """
        name: staleness test
        app: FakeMirroring
        description: test

        steps:
          - wait_for: "Settings"
          - assert_visible: "General"
        """

        let tmpPath = writeTempYAML(yaml)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Compile on "Settings" scenario
        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: testExecutorConfig()
        )

        let skill = SkillParser.parse(content: yaml, filePath: tmpPath)
        let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: tmpPath,
            windowWidth: windowDimensions().width,
            windowHeight: windowDimensions().height,
            orientation: "portrait"
        )

        XCTAssertNotNil(compiled, "Skill should compile")
        guard let compiled = compiled else { return }
        XCTAssertNotNil(compiled.screenFingerprint, "Should have baseline fingerprint")

        // Switch to "Settings (Updated)"
        let switched = bridge.triggerMenuAction(menu: "Scenario", item: "Settings (Updated)")
        XCTAssertTrue(switched, "Should switch scenario")
        usleep(1_000_000)

        // Capture live fingerprint on the updated screen
        guard let liveResult = describeWithRetry() else {
            XCTFail("Live describe() returned nil")
            return
        }
        let liveFP = StructuralFingerprint.buildScreenFingerprint(
            elements: liveResult.elements, icons: liveResult.icons)

        let staleness = CompiledSkillIO.checkStaleness(
            compiled: compiled,
            skillPath: tmpPath,
            windowWidth: windowDimensions().width,
            windowHeight: windowDimensions().height,
            liveFingerprint: liveFP
        )

        switch staleness {
        case .drifted:
            // Expected — content has drifted
            break
        default:
            XCTFail("Expected .drifted after scenario switch, got: \(staleness)")
        }
    }

    // MARK: - RecordingDescriber Tests

    func testRecordingDescriberFirstResultWithRealOCR() {
        let recordingDescriber = RecordingDescriber(wrapping: describer)

        XCTAssertNil(recordingDescriber.firstResult, "firstResult should be nil before any calls")
        XCTAssertEqual(recordingDescriber.callCount, 0)

        // First call
        let result1 = recordingDescriber.describe(skipOCR: false)
        XCTAssertNotNil(result1, "First describe() should return a result")
        XCTAssertNotNil(recordingDescriber.firstResult, "firstResult should be set after first call")
        XCTAssertEqual(recordingDescriber.callCount, 1)

        let firstTexts = Set(recordingDescriber.firstResult!.elements.map { $0.text })
        XCTAssertTrue(firstTexts.contains("Settings") || firstTexts.contains("settings"),
                      "First result should contain 'Settings' from FakeMirroring")

        // Second call
        let result2 = recordingDescriber.describe(skipOCR: false)
        XCTAssertNotNil(result2, "Second describe() should return a result")
        XCTAssertEqual(recordingDescriber.callCount, 2)

        // firstResult should still hold the first call's data
        let firstTextsAfter = Set(recordingDescriber.firstResult!.elements.map { $0.text })
        XCTAssertEqual(firstTexts, firstTextsAfter,
                       "firstResult should not be overwritten by subsequent calls")
    }

    // MARK: - Helpers

    /// Retry describe() up to 3 times with a brief pause between attempts.
    /// Screen capture can fail transiently under rapid successive OCR load.
    private func describeWithRetry(maxAttempts: Int = 3) -> ScreenDescriber.DescribeResult? {
        for attempt in 1...maxAttempts {
            if let result = describer.describe() { return result }
            if attempt < maxAttempts { usleep(500_000) }
        }
        return nil
    }

    private func windowDimensions() -> (width: Double, height: Double) {
        guard let info = bridge.getWindowInfo() else { return (410, 898) }
        return (Double(info.size.width), Double(info.size.height))
    }

    private func writeTempYAML(_ content: String) -> String {
        let tmpDir = NSTemporaryDirectory()
        let fileName = "compiled-test-\(UUID().uuidString).yaml"
        let path = (tmpDir as NSString).appendingPathComponent(fileName)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func testExecutorConfig() -> StepExecutorConfig {
        StepExecutorConfig(
            waitForTimeoutSeconds: 10,
            settlingDelayMs: 500,
            screenshotDir: NSTemporaryDirectory() + "mirroir-compiled-test",
            dryRun: false
        )
    }
}
