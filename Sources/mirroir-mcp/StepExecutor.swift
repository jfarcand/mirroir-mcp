// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Executes individual skill steps against real subsystems via protocol abstractions.
// ABOUTME: Maps each SkillStep to the appropriate subsystem call (OCR, input, capture).

import Foundation
import HelperLib

/// Result of executing a single step.
struct StepResult {
    let step: SkillStep
    let status: StepStatus
    let message: String?
    let durationSeconds: Double

    enum StepStatus: String, Equatable {
        case passed = "PASS"
        case failed = "FAIL"
        case skipped = "SKIP"
    }
}

/// Configuration for step execution.
struct StepExecutorConfig {
    /// Timeout in seconds for wait_for steps.
    let waitForTimeoutSeconds: Int
    /// Milliseconds to wait between steps for UI settling.
    let settlingDelayMs: UInt32
    /// Directory to save failure screenshots.
    let screenshotDir: String
    /// Whether to actually execute steps (false = dry run).
    let dryRun: Bool

    static let `default` = StepExecutorConfig(
        waitForTimeoutSeconds: EnvConfig.waitForTimeoutSeconds,
        settlingDelayMs: EnvConfig.stepSettlingDelayMs,
        screenshotDir: "./mirroir-test-results",
        dryRun: false
    )
}

/// Executes skill steps against system subsystems via protocol abstractions.
///
/// **Threading contract**: StepExecutor is designed for single-threaded,
/// sequential step execution. All calls to `execute()` must happen on the
/// same thread. The mutable subsystem references are swapped during
/// `switch_target` steps and are not synchronized for concurrent access.
final class StepExecutor {
    /// Mutable subsystem references that change when `switch_target` is executed.
    private struct Subsystems {
        var bridge: any WindowBridging
        var input: any InputProviding
        var describer: any ScreenDescribing
        var capture: any ScreenCapturing
    }

    private var subsystems: Subsystems
    let config: StepExecutorConfig
    let registry: TargetRegistry?

    init(bridge: any WindowBridging,
         input: InputProviding,
         describer: ScreenDescribing,
         capture: ScreenCapturing,
         config: StepExecutorConfig = .default,
         registry: TargetRegistry? = nil) {
        self.subsystems = Subsystems(
            bridge: bridge,
            input: input,
            describer: describer,
            capture: capture
        )
        self.config = config
        self.registry = registry
    }

    var bridge: any WindowBridging { subsystems.bridge }
    var input: any InputProviding { subsystems.input }
    var describer: any ScreenDescribing { subsystems.describer }
    var capture: any ScreenCapturing { subsystems.capture }

    /// Swap subsystem references when switching targets.
    func switchSubsystems(bridge: any WindowBridging, input: any InputProviding,
                          describer: any ScreenDescribing, capture: any ScreenCapturing) {
        subsystems = Subsystems(bridge: bridge, input: input,
                                describer: describer, capture: capture)
    }

    /// Execute a single step and return the result.
    func execute(step: SkillStep, stepIndex: Int, skillName: String) -> StepResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        if config.dryRun {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            return StepResult(step: step, status: .passed,
                              message: "dry run", durationSeconds: duration)
        }

        let result: StepResult

        switch step {
        case .launch(let appName):
            result = executeLaunch(appName: appName, startTime: startTime)
        case .tap(let label):
            result = executeTap(label: label, startTime: startTime)
        case .type(let text):
            result = executeType(text: text, startTime: startTime)
        case .pressKey(let keyName, let modifiers):
            result = executePressKey(keyName: keyName, modifiers: modifiers,
                                     startTime: startTime)
        case .swipe(let direction):
            result = executeSwipe(direction: direction, startTime: startTime)
        case .waitFor(let label, let timeout):
            result = executeWaitFor(label: label,
                                    timeoutSeconds: timeout ?? config.waitForTimeoutSeconds,
                                    startTime: startTime)
        case .assertVisible(let label):
            result = executeAssertVisible(label: label, startTime: startTime)
        case .assertNotVisible(let label):
            result = executeAssertNotVisible(label: label, startTime: startTime)
        case .screenshot(let label):
            result = executeScreenshot(label: label, skillName: skillName,
                                       startTime: startTime)
        case .home:
            result = executeHome(startTime: startTime)
        case .openURL(let url):
            result = executeOpenURL(url: url, startTime: startTime)
        case .shake:
            result = executeShake(startTime: startTime)
        case .longPress(let label, let durationMs):
            result = executeLongPress(label: label, durationMs: durationMs,
                                       startTime: startTime)
        case .drag(let fromLabel, let toLabel):
            result = executeDrag(fromLabel: fromLabel, toLabel: toLabel,
                                  startTime: startTime)
        case .scrollTo(let label, let direction, let maxScrolls):
            result = executeScrollTo(label: label, direction: direction,
                                      maxScrolls: maxScrolls, startTime: startTime)
        case .resetApp(let appName):
            result = executeResetApp(appName: appName, startTime: startTime)
        case .setNetwork(let mode):
            result = executeSetNetwork(mode: mode, startTime: startTime)
        case .measure(let name, let action, let until, let maxSeconds):
            result = executeMeasure(name: name, action: action, until: until,
                                     maxSeconds: maxSeconds, stepIndex: stepIndex,
                                     skillName: skillName, startTime: startTime)
        case .switchTarget(let name):
            result = executeSwitchTarget(name: name, startTime: startTime)
        case .skipped(let stepType, let reason):
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            result = StepResult(step: step, status: .skipped,
                                message: "\(stepType): \(reason)",
                                durationSeconds: duration)
        }

        // Save failure screenshot for debugging
        if result.status == .failed {
            captureFailureScreenshot(stepIndex: stepIndex, skillName: skillName)
        }

        // Inter-step settling delay
        if result.status != .skipped {
            usleep(config.settlingDelayMs * 1000)
        }

        return result
    }

    // MARK: - Step Implementations

    private func executeLaunch(appName: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.launch(appName: appName)
        if let error = input.launchApp(name: appName) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeTap(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.tap(label: label)

        guard let describeResult = describer.describe() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen for OCR",
                              durationSeconds: elapsed(startTime))
        }

        guard let match = ElementMatcher.findMatch(label: label, in: describeResult.elements) else {
            let available = describeResult.elements.map { $0.text }.joined(separator: ", ")
            return StepResult(step: step, status: .failed,
                              message: "Element \"\(label)\" not found on screen. Visible: [\(available)]",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.tap(x: match.element.tapX, y: match.element.tapY) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed,
                          message: "matched via \(match.strategy.rawValue)",
                          durationSeconds: elapsed(startTime))
    }

    private func executeType(text: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.type(text: text)
        let result = input.typeText(text)
        if !result.success {
            return StepResult(step: step, status: .failed,
                              message: result.error ?? "Type failed",
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: result.warning,
                          durationSeconds: elapsed(startTime))
    }

    private func executePressKey(keyName: String, modifiers: [String],
                                 startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.pressKey(keyName: keyName, modifiers: modifiers)
        let result = input.pressKey(keyName: keyName, modifiers: modifiers)
        if !result.success {
            return StepResult(step: step, status: .failed,
                              message: result.error ?? "Press key failed",
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeSwipe(direction: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.swipe(direction: direction)

        // Get window size for computing swipe coordinates
        guard let windowInfo = bridge.getWindowInfo() else {
            return StepResult(step: step, status: .failed,
                              message: "Could not get window info for swipe",
                              durationSeconds: elapsed(startTime))
        }

        guard let ep = swipeEndpoints(direction: direction, windowInfo: windowInfo) else {
            return StepResult(step: step, status: .failed,
                              message: "Unknown swipe direction: \(direction). Use up/down/left/right.",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.swipe(fromX: ep.fromX, fromY: ep.fromY,
                                    toX: ep.toX, toY: ep.toY, durationMs: EnvConfig.defaultSwipeDurationMs) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeWaitFor(label: String, timeoutSeconds: Int,
                                startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.waitFor(label: label, timeoutSeconds: timeoutSeconds)
        let deadline = CFAbsoluteTimeGetCurrent() + Double(timeoutSeconds)

        // Exponential backoff: start at 200ms, double each iteration, cap at 2s
        let initialPollUs: useconds_t = 200_000
        let maxPollUs: useconds_t = 2_000_000
        var currentPollUs = initialPollUs

        while CFAbsoluteTimeGetCurrent() < deadline {
            if let describeResult = describer.describe(),
               ElementMatcher.isVisible(label: label, in: describeResult.elements) {
                return StepResult(step: step, status: .passed, message: nil,
                                  durationSeconds: elapsed(startTime))
            }
            usleep(currentPollUs)
            currentPollUs = min(currentPollUs * 2, maxPollUs)
        }

        // Final check after deadline
        if let describeResult = describer.describe(),
           ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .failed,
                          message: "Timed out waiting for \"\(label)\" after \(timeoutSeconds)s",
                          durationSeconds: elapsed(startTime))
    }

    private func executeAssertVisible(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.assertVisible(label: label)

        guard let describeResult = describer.describe() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen for OCR",
                              durationSeconds: elapsed(startTime))
        }

        if ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        let available = describeResult.elements.map { $0.text }.joined(separator: ", ")
        return StepResult(step: step, status: .failed,
                          message: "Expected \"\(label)\" to be visible. Found: [\(available)]",
                          durationSeconds: elapsed(startTime))
    }

    private func executeAssertNotVisible(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.assertNotVisible(label: label)

        guard let describeResult = describer.describe() else {
            // If we can't describe the screen, we can't confirm visibility either way
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen for OCR",
                              durationSeconds: elapsed(startTime))
        }

        if !ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .failed,
                          message: "Expected \"\(label)\" to NOT be visible, but it was found",
                          durationSeconds: elapsed(startTime))
    }

    private func executeScreenshot(label: String, skillName: String,
                                   startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.screenshot(label: label)

        guard let data = captureScreenshotData() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screenshot",
                              durationSeconds: elapsed(startTime))
        }

        let safeName = skillName.replacingOccurrences(of: " ", with: "_")
        let safeLabel = label.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_\(safeLabel).png"

        guard let path = saveScreenshot(data, filename: filename) else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to save screenshot",
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed,
                          message: "saved to \(path)",
                          durationSeconds: elapsed(startTime))
    }

    private func executeHome(startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.home
        guard let menuBridge = bridge as? (any MenuActionCapable) else {
            return StepResult(step: step, status: .failed,
                              message: "Target '\(bridge.targetName)' does not support the home button",
                              durationSeconds: elapsed(startTime))
        }
        let success = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
        if !success {
            return StepResult(step: step, status: .failed,
                              message: "Failed to trigger Home Screen menu action",
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeOpenURL(url: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.openURL(url: url)
        if let error = input.openURL(url) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeShake(startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.shake
        let result = input.shake()
        if !result.success {
            return StepResult(step: step, status: .failed,
                              message: result.error ?? "Shake failed",
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - Helpers

    func elapsed(_ startTime: CFAbsoluteTime) -> Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }

    /// Convenience cast to MenuActionCapable for steps that need menu actions.
    var menuBridge: (any MenuActionCapable)? {
        bridge as? (any MenuActionCapable)
    }
}
