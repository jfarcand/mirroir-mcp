// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Executes individual scenario steps against real subsystems via protocol abstractions.
// ABOUTME: Maps each ScenarioStep to the appropriate subsystem call (OCR, input, capture).

import Foundation
import HelperLib

/// Result of executing a single step.
struct StepResult {
    let step: ScenarioStep
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
        waitForTimeoutSeconds: 15,
        settlingDelayMs: 500,
        screenshotDir: "./mirroir-test-results",
        dryRun: false
    )
}

/// Executes scenario steps against system subsystems via protocol abstractions.
final class StepExecutor {
    private let bridge: MirroringBridging
    private let input: InputProviding
    private let describer: ScreenDescribing
    private let capture: ScreenCapturing
    private let config: StepExecutorConfig

    init(bridge: MirroringBridging,
         input: InputProviding,
         describer: ScreenDescribing,
         capture: ScreenCapturing,
         config: StepExecutorConfig = .default) {
        self.bridge = bridge
        self.input = input
        self.describer = describer
        self.capture = capture
        self.config = config
    }

    /// Execute a single step and return the result.
    func execute(step: ScenarioStep, stepIndex: Int, scenarioName: String) -> StepResult {
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
            result = executeScreenshot(label: label, scenarioName: scenarioName,
                                       startTime: startTime)
        case .home:
            result = executeHome(startTime: startTime)
        case .openURL(let url):
            result = executeOpenURL(url: url, startTime: startTime)
        case .shake:
            result = executeShake(startTime: startTime)
        case .skipped(let stepType, let reason):
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            result = StepResult(step: step, status: .skipped,
                                message: "\(stepType): \(reason)",
                                durationSeconds: duration)
        }

        // Save failure screenshot for debugging
        if result.status == .failed {
            captureFailureScreenshot(stepIndex: stepIndex, scenarioName: scenarioName)
        }

        // Inter-step settling delay
        if result.status != .skipped {
            usleep(config.settlingDelayMs * 1000)
        }

        return result
    }

    // MARK: - Step Implementations

    private func executeLaunch(appName: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.launch(appName: appName)
        if let error = input.launchApp(name: appName) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeTap(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.tap(label: label)

        guard let describeResult = describer.describe(skipOCR: false) else {
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
        let step = ScenarioStep.type(text: text)
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
        let step = ScenarioStep.pressKey(keyName: keyName, modifiers: modifiers)
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
        let step = ScenarioStep.swipe(direction: direction)

        // Get window size for computing swipe coordinates
        guard let windowInfo = bridge.getWindowInfo() else {
            return StepResult(step: step, status: .failed,
                              message: "Could not get window info for swipe",
                              durationSeconds: elapsed(startTime))
        }

        let centerX = Double(windowInfo.size.width) / 2.0
        let centerY = Double(windowInfo.size.height) / 2.0
        let swipeDistance = Double(windowInfo.size.height) * 0.3

        let fromX: Double, fromY: Double, toX: Double, toY: Double
        switch direction.lowercased() {
        case "up":
            fromX = centerX; fromY = centerY + swipeDistance / 2
            toX = centerX; toY = centerY - swipeDistance / 2
        case "down":
            fromX = centerX; fromY = centerY - swipeDistance / 2
            toX = centerX; toY = centerY + swipeDistance / 2
        case "left":
            fromX = centerX + swipeDistance / 2; fromY = centerY
            toX = centerX - swipeDistance / 2; toY = centerY
        case "right":
            fromX = centerX - swipeDistance / 2; fromY = centerY
            toX = centerX + swipeDistance / 2; toY = centerY
        default:
            return StepResult(step: step, status: .failed,
                              message: "Unknown swipe direction: \(direction). Use up/down/left/right.",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.swipe(fromX: fromX, fromY: fromY,
                                    toX: toX, toY: toY, durationMs: 300) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeWaitFor(label: String, timeoutSeconds: Int,
                                startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.waitFor(label: label, timeoutSeconds: timeoutSeconds)
        let pollIntervalUs: useconds_t = 1_000_000  // 1 second

        for _ in 0..<timeoutSeconds {
            if let describeResult = describer.describe(skipOCR: false),
               ElementMatcher.isVisible(label: label, in: describeResult.elements) {
                return StepResult(step: step, status: .passed, message: nil,
                                  durationSeconds: elapsed(startTime))
            }
            usleep(pollIntervalUs)
        }

        // Final check
        if let describeResult = describer.describe(skipOCR: false),
           ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed, message: nil,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .failed,
                          message: "Timed out waiting for \"\(label)\" after \(timeoutSeconds)s",
                          durationSeconds: elapsed(startTime))
    }

    private func executeAssertVisible(label: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.assertVisible(label: label)

        guard let describeResult = describer.describe(skipOCR: false) else {
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
        let step = ScenarioStep.assertNotVisible(label: label)

        guard let describeResult = describer.describe(skipOCR: false) else {
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

    private func executeScreenshot(label: String, scenarioName: String,
                                   startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.screenshot(label: label)

        guard let base64 = capture.captureBase64() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screenshot",
                              durationSeconds: elapsed(startTime))
        }

        guard let data = Data(base64Encoded: base64) else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to decode screenshot data",
                              durationSeconds: elapsed(startTime))
        }

        let dir = config.screenshotDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let safeName = scenarioName.replacingOccurrences(of: " ", with: "_")
        let safeLabel = label.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_\(safeLabel).png"
        let path = (dir as NSString).appendingPathComponent(filename)

        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return StepResult(step: step, status: .failed,
                              message: "Failed to save screenshot to \(path): \(error.localizedDescription)",
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed,
                          message: "saved to \(path)",
                          durationSeconds: elapsed(startTime))
    }

    private func executeHome(startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.home
        let success = bridge.triggerMenuAction(menu: "View", item: "Home Screen")
        if !success {
            return StepResult(step: step, status: .failed,
                              message: "Failed to trigger Home Screen menu action",
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeOpenURL(url: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.openURL(url: url)
        if let error = input.openURL(url) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }
        return StepResult(step: step, status: .passed, message: nil,
                          durationSeconds: elapsed(startTime))
    }

    private func executeShake(startTime: CFAbsoluteTime) -> StepResult {
        let step = ScenarioStep.shake
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

    private func elapsed(_ startTime: CFAbsoluteTime) -> Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }

    /// Save a screenshot for debugging when a step fails.
    private func captureFailureScreenshot(stepIndex: Int, scenarioName: String) {
        guard let base64 = capture.captureBase64(),
              let data = Data(base64Encoded: base64) else { return }

        let dir = config.screenshotDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let safeName = scenarioName.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_failure_step\(stepIndex + 1).png"
        let path = (dir as NSString).appendingPathComponent(filename)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
