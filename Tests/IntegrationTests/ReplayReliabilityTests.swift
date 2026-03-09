// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Experiment C2: measures compiled skill replay reliability across repeated runs.
// ABOUTME: Validates that compiled assertion skills pass consistently (>= 90% pass rate).

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Compiles an assertion skill, runs it multiple times, and measures pass rate.
///
/// Tier 1 metric: replay determinism > 90%
final class ReplayReliabilityTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard IntegrationTestHelper.isFakeMirroringRunning else {
            throw IntegrationTestError.fakeMirroringNotRunning
        }
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
    }

    /// Run a compiled assertion skill 10 times and verify >= 90% pass rate.
    func testReplayPassRate() throws {
        let capture = ScreenCapture(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)
        let recordingDescriber = RecordingDescriber(wrapping: describer)

        guard let windowInfo = bridge.getWindowInfo() else {
            throw IntegrationTestError.windowInfoUnavailable
        }

        let windowWidth = Double(windowInfo.size.width)
        let windowHeight = Double(windowInfo.size.height)
        let orientation = bridge.getOrientation()?.rawValue ?? "portrait"

        // Build a simple assertion-only skill inline
        let yaml = """
        name: replay-test
        steps:
          - assert_visible: "Settings"
        """
        let skill = SkillParser.parse(content: yaml, filePath: "<test>")

        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 5,
            settlingDelayMs: 300,
            screenshotDir: NSTemporaryDirectory() + "replay-test",
            dryRun: false
        )

        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: config
        )

        // Compile the skill
        guard let compiled = CompileCommand.compileSkill(
            skill: skill, executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: "<test>",
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            orientation: orientation
        ) else {
            XCTFail("Failed to compile assertion skill")
            return
        }

        // Run compiled skill 10 times
        let runCount = 10
        var passCount = 0

        for _ in 0..<runCount {
            // Re-ensure window is ready between runs
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)

            let compiledExecutor = CompiledStepExecutor(
                bridge: bridge, input: input,
                describer: describer, capture: capture,
                config: config
            )

            var allPassed = true
            for (index, step) in skill.steps.enumerated() {
                if index < compiled.steps.count {
                    let result = compiledExecutor.execute(
                        step: step, compiledStep: compiled.steps[index],
                        stepIndex: index, skillName: skill.name)
                    if result.status != .passed {
                        allPassed = false
                        break
                    }
                }
            }

            if allPassed { passCount += 1 }
        }

        let passRate = Double(passCount) / Double(runCount)
        print("Replay pass rate: \(passCount)/\(runCount) = \(String(format: "%.0f", passRate * 100))%")
        XCTAssertGreaterThanOrEqual(passRate, 0.9, "Replay pass rate should be >= 90%")
    }
}
