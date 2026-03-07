// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration tests for compiled skill tap execution against interactive FakeMirroring.
// ABOUTME: Validates that compiled taps with cached coordinates produce correct navigation results.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Tests that compiled tap skills execute correctly against FakeMirroring with interactive navigation.
/// Compiles a multi-step tap+assert skill, then replays it and verifies each step succeeds.
///
/// This validates the full compiled pipeline: compile coordinates → replay taps → verify navigation.
final class CompiledTapFlowTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var input: InputSimulation!
    private var describer: ScreenDescriber!
    private var capture: ScreenCapture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard IntegrationTestHelper.isFakeMirroringRunning else {
            throw XCTSkip("FakeMirroring not running")
        }
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw XCTSkip("FakeMirroring window not capturable")
        }
        capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
        input = InputSimulation(bridge: bridge)

        // Start on Settings
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(1_000_000)
    }

    override func tearDown() {
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    /// Compile a tap+assert skill against Settings, then replay it.
    /// Tap "General" → lands on Detail → assert "About" visible on Detail screen.
    func testCompiledTapNavigatesAndAsserts() throws {
        let yaml = """
        name: tap-flow-test
        app: FakeMirroring
        description: test compiled tap navigation

        steps:
          - assert_visible: "General"
          - tap: "General"
          - assert_visible: "About"
        """

        let tmpPath = writeTempYAML(yaml)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let config = testConfig()
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: config
        )

        let skill = SkillParser.parse(content: yaml, filePath: tmpPath)
        let dims = windowDimensions()
        let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: tmpPath,
            windowWidth: dims.width,
            windowHeight: dims.height,
            orientation: "portrait"
        )

        XCTAssertNotNil(compiled, "Skill should compile against FakeMirroring Settings")
        guard let compiled = compiled else { return }

        // Reset to Settings before replay
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(1_000_000)

        // Replay the compiled skill
        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )

        var stepResults: [StepResult] = []
        for compiledStep in compiled.steps {
            let step = skill.steps[compiledStep.index]
            let result = compiledExecutor.execute(
                step: step, compiledStep: compiledStep,
                stepIndex: compiledStep.index, skillName: skill.name
            )
            stepResults.append(result)
        }

        // First assert_visible "General" should pass (on Settings screen)
        XCTAssertEqual(stepResults[0].status, .passed,
                       "assert_visible 'General' should pass on Settings: \(stepResults[0].message ?? "")")

        // Tap "General" should pass
        XCTAssertEqual(stepResults[1].status, .passed,
                       "tap 'General' should succeed: \(stepResults[1].message ?? "")")

        // After tap, FakeMirroring should navigate to Detail screen
        // assert_visible "About" should pass (About is a row on Detail screen)
        XCTAssertEqual(stepResults[2].status, .passed,
                       "assert_visible 'About' should pass on Detail screen after tap: \(stepResults[2].message ?? "")")

        let passCount = stepResults.filter { $0.status == .passed }.count
        let passRate = Double(passCount) / Double(stepResults.count)
        print("Compiled tap flow: \(stepResults.count) steps, \(String(format: "%.0f", passRate * 100))% pass rate")
    }

    // MARK: - Helpers

    private func windowDimensions() -> (width: Double, height: Double) {
        guard let info = bridge.getWindowInfo() else { return (410, 898) }
        return (Double(info.size.width), Double(info.size.height))
    }

    private func writeTempYAML(_ content: String) -> String {
        let tmpDir = NSTemporaryDirectory()
        let fileName = "tap-flow-\(UUID().uuidString).yaml"
        let path = (tmpDir as NSString).appendingPathComponent(fileName)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func testConfig() -> StepExecutorConfig {
        StepExecutorConfig(
            waitForTimeoutSeconds: 10,
            settlingDelayMs: 500,
            screenshotDir: NSTemporaryDirectory() + "mirroir-tap-flow",
            dryRun: false
        )
    }
}
