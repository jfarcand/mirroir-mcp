// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: A stub iPhone that walks Home → Clock → World Clock as the stub input drives it.
// ABOUTME: Lets `mirroir test` per-step screen capture run through the real StepExecutor without a device.

import CoreGraphics
import Foundation
@testable import HelperLib
@testable import mirroir_mcp

/// Stubs the iPhone for a launch-Clock, tap-World-Clock walk: the screen shown
/// follows what `StubInput` has been asked to do, so each step the real
/// `StepExecutor` runs moves the stub to the screen a real phone would show.
/// The labels are the FakeMirroring Clock pack's.
final class ClockWalkDouble: ScreenDescribing, @unchecked Sendable {

    static let home = ["Clock", "Calendar", "Photos", "Camera", "Settings"]
    static let alarms = [
        "Edit", "Add Alarm", "Alarms", "Sleep | Wake Up", "Other",
        "World Clock", "Stopwatch", "Timers",
    ]
    static let worldClock = [
        "Edit", "World Clock", "Cupertino", "Today, +0HRS", "Alarms", "Stopwatch", "Timers",
    ]

    /// The YAML skill the walk runs, as mirroir-run renders an `ios` block.
    static let skillYAML = """
        version: 1
        name: "world-clock"
        steps:
          - target: { kind: ios, app: "Clock" }
          - launch: "Clock"
          - tap: "World Clock"
          - wait_for: "Cupertino"

        """

    let bridge = StubBridge()
    let input = StubInput()
    let capture = StubCapture()

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        let labels: [String]
        if input.launchAppCalls.isEmpty {
            labels = Self.home
        } else if input.tapCalls.isEmpty {
            labels = Self.alarms
        } else {
            labels = Self.worldClock
        }
        return ScreenDescriber.DescribeResult(elements: Self.elements(labels), screenshotBase64: "")
    }

    /// OCR elements for `labels`, one per row below the status bar.
    static func elements(_ labels: [String]) -> [TapPoint] {
        labels.enumerated().map {
            TapPoint(text: $0.element, tapX: 200, tapY: Double(120 + 50 * $0.offset), confidence: 0.95)
        }
    }

    /// An executor driving this stub, with the stub as the registry's iPhone so
    /// the walk's `target:` step resolves.
    func executor() -> StepExecutor {
        let phone = TargetContext(
            name: "iphone", targetType: IPhoneMirroringTarget.configTypeName, bundleID: nil,
            bridge: bridge, input: input, capture: capture, describer: self,
            recorder: StubRecorder(), capabilities: [])
        return StepExecutor(
            bridge: bridge, input: input, describer: self, capture: capture,
            config: StepExecutorConfig(
                waitForTimeoutSeconds: 2, settlingDelayMs: 0,
                screenshotDir: NSTemporaryDirectory() + "clock-walk-\(UUID().uuidString)",
                dryRun: false),
            registry: TargetRegistry(targets: ["iphone": phone], defaultName: "iphone"))
    }

    /// Run `skill` through the real `TestRunner.executeSkill`, recording its screens.
    func run(_ skill: SkillDefinition) -> (ConsoleReporter.SkillResult, StepScreens) {
        let executor = executor()
        let recorder = StepScreenRecorder(describer: { executor.describer })
        recorder.recordStart()
        let result = TestRunner.executeSkill(
            skill: skill, executor: executor, verbose: false, recorder: recorder)
        return (result, recorder.snapshot())
    }
}
