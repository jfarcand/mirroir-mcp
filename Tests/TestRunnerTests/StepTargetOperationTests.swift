// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Checks that a step whose operation the current target lacks fails with the tool's own refusal and sends nothing.
// ABOUTME: Covers run_steps, test and compile, which all execute steps through StepExecutor.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class StepTargetOperationTests: XCTestCase {

    private var phoneBridge: StubBridge!
    private var phoneInput: StubInput!
    private var macBridge: StubBridge!
    private var macInput: StubInput!
    private var registry: TargetRegistry!

    override func setUp() {
        super.setUp()
        phoneBridge = StubBridge()
        phoneBridge.targetName = "iphone"
        phoneInput = StubInput()
        macBridge = StubBridge()
        macBridge.targetName = "telegram"
        macInput = StubInput()
        let phone = TargetContext(
            name: "iphone", targetType: IPhoneMirroringTarget.configTypeName, bundleID: nil,
            bridge: phoneBridge, input: phoneInput,
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder())
        let mac = TargetContext(
            name: "telegram", targetType: MacOSAppTarget.configTypeName, bundleID: nil,
            bridge: macBridge, input: macInput,
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder())
        registry = TargetRegistry(targets: ["iphone": phone, "telegram": mac], defaultName: "iphone")
    }

    private func executor(on name: String) throws -> StepExecutor {
        let ctx = try XCTUnwrap(registry.resolve(name))
        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 1, settlingDelayMs: 0,
            screenshotDir: NSTemporaryDirectory() + "step-operation-\(UUID().uuidString)",
            dryRun: false)
        return StepExecutor(bridge: ctx.bridge, input: ctx.input, describer: ctx.describer,
                            capture: ctx.capture, config: config, registry: registry,
                            profile: ctx.profile)
    }

    func testAnUnsupportedStepFailsWithTheToolsRefusalAndSendsNothing() throws {
        let executor = try executor(on: "telegram")

        let shake = executor.execute(step: .shake, stepIndex: 0, skillName: "t")
        XCTAssertEqual(shake.status, .failed)
        XCTAssertEqual(shake.message, MacOSAppTarget.profile.refusal(
            of: .shake, targetName: "telegram", supportedOn: ["iphone"]))
        XCTAssertEqual(macInput.shakeCalls, 0)

        let home = executor.execute(step: .home, stepIndex: 1, skillName: "t")
        XCTAssertEqual(home.status, .failed)
        XCTAssertTrue(home.message?.hasPrefix("press_home is unsupported on target 'telegram'") ?? false)
        XCTAssertTrue(macBridge.menuActionCalls.isEmpty)

        let launch = executor.execute(step: .launch(appName: "Clock"), stepIndex: 2, skillName: "t")
        XCTAssertEqual(launch.status, .failed)
        XCTAssertEqual(macInput.launchAppCalls, [])
    }

    func testAStepEveryTargetHasStillRuns() throws {
        let executor = try executor(on: "telegram")
        let tap = executor.execute(step: .tap(label: "@10,20"), stepIndex: 0, skillName: "t")
        XCTAssertEqual(tap.status, .passed, tap.message ?? "")
    }

    /// The check follows the target across a `target:` step, in both directions.
    func testTheCheckFollowsASwitchOfTarget() throws {
        let executor = try executor(on: "iphone")
        XCTAssertEqual(executor.execute(step: .shake, stepIndex: 0, skillName: "t").status, .passed)
        XCTAssertEqual(phoneInput.shakeCalls, 1)

        XCTAssertEqual(executor.execute(
            step: .switchTarget(.macos(name: "telegram")), stepIndex: 1, skillName: "t").status, .passed)
        XCTAssertEqual(executor.execute(step: .shake, stepIndex: 2, skillName: "t").status, .failed)
        XCTAssertEqual(macInput.shakeCalls, 0)

        XCTAssertEqual(executor.execute(
            step: .switchTarget(.ios(app: nil)), stepIndex: 3, skillName: "t").status, .passed)
        XCTAssertEqual(executor.execute(step: .shake, stepIndex: 4, skillName: "t").status, .passed)
        XCTAssertEqual(phoneInput.shakeCalls, 2)
    }

    /// Without a registry (the CLI commands), the profile alone decides.
    func testWithoutARegistryTheRefusalNamesNoOtherTarget() {
        let executor = StepExecutor(
            bridge: macBridge, input: macInput, describer: StubDescriber(), capture: StubCapture(),
            profile: MacOSAppTarget.profile)
        let result = executor.execute(step: .shake, stepIndex: 0, skillName: "t")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.hasSuffix("No configured target supports it.") ?? false)
    }
}
