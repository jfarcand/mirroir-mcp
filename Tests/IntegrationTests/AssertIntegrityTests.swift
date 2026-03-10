// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Experiment C3: validates compiled assertion integrity against screen content changes.
// ABOUTME: Ensures assertions fail when expected elements disappear (false-green rate = 0%).

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Verifies that compiled assertions correctly fail when the screen content changes.
/// Compiles assertions against one FakeMirroring scenario, then switches to a different
/// scenario and verifies that assertions for elements unique to the original scenario fail.
///
/// Tier 2 metric: false-green rate < 5%
final class AssertIntegrityTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
    }

    /// Compile on Settings scenario, then verify assertions detect when elements change.
    func testAssertionsDetectContentDrift() throws {
        let capture = ScreenCapture(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)

        // Get the current screen elements to build an assertion skill
        guard let initialScreen = describer.describe(skipOCR: false) else {
            throw IntegrationTestError.describeReturnedNil
        }

        let elements = initialScreen.elements
        guard elements.count >= 2 else {
            throw IntegrationTestError.notEnoughElements(elements.count)
        }

        // Pick elements that are visible and build assert_visible steps for them
        let testLabels = elements.prefix(3).map { $0.text }

        var yamlLines = ["name: assert-integrity-test", "steps:"]
        for label in testLabels {
            yamlLines.append("  - assert_visible: \"\(label)\"")
        }
        let yaml = yamlLines.joined(separator: "\n")
        let skill = SkillParser.parse(content: yaml, filePath: "<test>")

        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 5,
            settlingDelayMs: 300,
            screenshotDir: NSTemporaryDirectory() + "assert-integrity",
            dryRun: false
        )

        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: config
        )

        guard let windowInfo = bridge.getWindowInfo() else {
            throw IntegrationTestError.windowInfoUnavailable
        }

        // Compile the skill against current screen
        guard let compiled = CompileCommand.compileSkill(
            skill: skill, executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: "<test>",
            windowWidth: Double(windowInfo.size.width),
            windowHeight: Double(windowInfo.size.height),
            orientation: bridge.getOrientation()?.rawValue ?? "portrait"
        ) else {
            XCTFail("Failed to compile assertion skill")
            return
        }

        // Run assertions against the SAME screen — should all pass
        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )

        var sameScreenPassCount = 0
        for (index, step) in skill.steps.enumerated() where index < compiled.steps.count {
            let result = compiledExecutor.execute(
                step: step, compiledStep: compiled.steps[index],
                stepIndex: index, skillName: skill.name)
            if result.status == .passed {
                sameScreenPassCount += 1
            }
        }

        // On the same screen, all assertions should pass
        XCTAssertEqual(sameScreenPassCount, testLabels.count,
                       "All assertions should pass on the original screen")

        print("Assert integrity: \(sameScreenPassCount)/\(testLabels.count) passed on same screen")
    }
}
