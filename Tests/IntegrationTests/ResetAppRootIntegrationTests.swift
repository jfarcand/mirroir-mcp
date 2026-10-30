// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration test proving reset_app before launch returns FakeMirroring's Clock to its root screen.
// ABOUTME: The shape every emitted scenario opens with; a warm launch alone resumes where the app was left.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Every emitted `.ios.yaml` flow opens `reset_app: App` then `launch: App`,
/// because a launch of a running app resumes wherever it was left and the
/// flow was recorded from the app's root. This drives that pair against the
/// Clock pack: leave Clock on World Clock, show a plain relaunch resumes
/// there, then show reset_app + launch lands back on the Alarms root.
final class ResetAppRootIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var executor: StepExecutor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        let capture = ScreenCapture(bridge: bridge)
        // launch confirms Spotlight by reading the screen, as TestRunner wires it.
        let describer = ScreenDescriber(bridge: bridge, capture: capture)
        executor = StepExecutor(
            bridge: bridge, input: InputSimulation(bridge: bridge, pasteVerifier: describer),
            describer: describer, capture: capture,
            config: StepExecutorConfig(
                waitForTimeoutSeconds: 10,
                settlingDelayMs: 500,
                screenshotDir: NSTemporaryDirectory() + "mirroir-reset-app-root",
                dryRun: false))
        // A cold Clock, on its Alarms root.
        IntegrationTestHelper.resetScenario(bridge: bridge, to: "Clock")
        usleep(800_000)
    }

    override func tearDown() {
        if let bridge = bridge {
            IntegrationTestHelper.resetScenario(bridge: bridge, to: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    func testResetAppBeforeLaunchReturnsTheAppToItsRoot() throws {
        let yaml = """
        name: reset-app-root
        steps:
          - assert_visible: "Sleep | Wake Up"
          - tap: "World Clock"
          - wait_for: "Cupertino"
          - home:
          - launch: "Clock"
          - assert_visible: "Cupertino"
          - reset_app: "Clock"
          - launch: "Clock"
          - wait_for: "Sleep | Wake Up"
          - assert_not_visible: "Cupertino"
        """
        let skill = SkillParser.parse(content: yaml, filePath: "/tmp/reset-app-root.yaml")
        XCTAssertNil(InvalidStepGate.refuse(skills: [skill]))
        // The own-app reset right before its launch needs no --confirm-destructive.
        XCTAssertNil(DestructiveStepGate.refuse(skills: [skill], dryRun: false, confirmed: false))

        for (index, step) in skill.steps.enumerated() {
            let result = executor.execute(step: step, stepIndex: index, skillName: skill.name)
            XCTAssertEqual(
                result.status, .passed,
                "step \(index + 1) \(step.displayName): \(result.message ?? "")")
            guard result.status == .passed else { return }
        }
    }
}
