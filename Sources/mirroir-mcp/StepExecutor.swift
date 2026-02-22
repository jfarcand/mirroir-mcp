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
    private let config: StepExecutorConfig
    private let registry: TargetRegistry?

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

    private var bridge: any WindowBridging { subsystems.bridge }
    private var input: any InputProviding { subsystems.input }
    private var describer: any ScreenDescribing { subsystems.describer }
    private var capture: any ScreenCapturing { subsystems.capture }

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
        let pollIntervalUs: useconds_t = EnvConfig.waitForPollIntervalUs

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
        let step = SkillStep.assertVisible(label: label)

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
        let step = SkillStep.assertNotVisible(label: label)

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

    private func executeScreenshot(label: String, skillName: String,
                                   startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.screenshot(label: label)

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

        let safeName = skillName.replacingOccurrences(of: " ", with: "_")
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

    // MARK: - scroll_to

    private func executeScrollTo(label: String, direction: String, maxScrolls: Int,
                                  startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.scrollTo(label: label, direction: direction,
                                          maxScrolls: maxScrolls)

        // Check if already visible
        if let describeResult = describer.describe(skipOCR: false),
           ElementMatcher.isVisible(label: label, in: describeResult.elements) {
            return StepResult(step: step, status: .passed,
                              message: "already visible",
                              durationSeconds: elapsed(startTime))
        }

        guard let windowInfo = bridge.getWindowInfo() else {
            return StepResult(step: step, status: .failed,
                              message: "Could not get window info for scroll",
                              durationSeconds: elapsed(startTime))
        }

        guard let ep = swipeEndpoints(direction: direction, windowInfo: windowInfo) else {
            return StepResult(step: step, status: .failed,
                              message: "Unknown direction: \(direction)",
                              durationSeconds: elapsed(startTime))
        }

        var previousTexts: [String] = []

        for attempt in 0..<maxScrolls {
            if let error = input.swipe(fromX: ep.fromX, fromY: ep.fromY,
                                        toX: ep.toX, toY: ep.toY, durationMs: EnvConfig.defaultSwipeDurationMs) {
                return StepResult(step: step, status: .failed,
                                  message: "Swipe failed: \(error)",
                                  durationSeconds: elapsed(startTime))
            }

            usleep(config.settlingDelayMs * 1000)

            // Check for element
            if let describeResult = describer.describe(skipOCR: false) {
                if ElementMatcher.isVisible(label: label, in: describeResult.elements) {
                    return StepResult(step: step, status: .passed,
                                      message: "found after \(attempt + 1) scroll(s)",
                                      durationSeconds: elapsed(startTime))
                }

                // Scroll exhaustion: if OCR results unchanged, list reached its end
                let currentTexts = describeResult.elements.map { $0.text }.sorted()
                if currentTexts == previousTexts {
                    return StepResult(step: step, status: .failed,
                                      message: "Scroll exhausted after \(attempt + 1) scroll(s) — content stopped changing",
                                      durationSeconds: elapsed(startTime))
                }
                previousTexts = currentTexts
            }
        }

        return StepResult(step: step, status: .failed,
                          message: "Not found after \(maxScrolls) scroll(s)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - reset_app

    private func executeResetApp(appName: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.resetApp(appName: appName)
        guard let menuBridge = self.menuBridge else {
            return StepResult(step: step, status: .failed,
                              message: "Target '\(bridge.targetName)' does not support reset_app",
                              durationSeconds: elapsed(startTime))
        }

        // Open App Switcher
        guard menuBridge.triggerMenuAction(menu: "View", item: "App Switcher") else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to open App Switcher",
                              durationSeconds: elapsed(startTime))
        }

        usleep(config.settlingDelayMs * 1000)

        // OCR to find the app card
        guard let describeResult = describer.describe(skipOCR: false) else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen in App Switcher",
                              durationSeconds: elapsed(startTime))
        }

        guard let match = ElementMatcher.findMatch(label: appName,
                                                     in: describeResult.elements) else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .passed,
                              message: "App not in switcher (already quit)",
                              durationSeconds: elapsed(startTime))
        }

        // Swipe up on the app card to force-quit.
        // OCR finds the app name label above the card preview, so offset
        // downward into the card body before swiping, and clamp toY >= 0.
        let cardX = match.element.tapX
        let cardY = match.element.tapY + EnvConfig.appSwitcherCardOffset
        let toY = max(0, cardY - EnvConfig.appSwitcherSwipeDistance)
        if let error = input.swipe(fromX: cardX, fromY: cardY,
                                    toX: cardX, toY: toY, durationMs: EnvConfig.appSwitcherSwipeDurationMs) {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "Failed to swipe app card: \(error)",
                              durationSeconds: elapsed(startTime))
        }

        usleep(config.settlingDelayMs * 1000)

        _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")

        return StepResult(step: step, status: .passed,
                          message: "Force-quit \(appName)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - set_network

    private func executeSetNetwork(mode: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.setNetwork(mode: mode)
        guard let menuBridge = self.menuBridge else {
            return StepResult(step: step, status: .failed,
                              message: "Target '\(bridge.targetName)' does not support set_network",
                              durationSeconds: elapsed(startTime))
        }

        let validModes = ["airplane_on", "airplane_off", "wifi_on", "wifi_off",
                          "cellular_on", "cellular_off"]
        guard validModes.contains(mode) else {
            return StepResult(step: step, status: .failed,
                              message: "Unknown mode: \(mode). Use: \(validModes.joined(separator: ", "))",
                              durationSeconds: elapsed(startTime))
        }

        // Launch Settings
        if let error = input.launchApp(name: "Settings") {
            return StepResult(step: step, status: .failed,
                              message: "Failed to launch Settings: \(error)",
                              durationSeconds: elapsed(startTime))
        }
        usleep(EnvConfig.settingsLoadUs)  // Wait for Settings to load

        let targetLabel: String
        switch mode {
        case "airplane_on", "airplane_off":
            targetLabel = "Airplane"
        case "wifi_on", "wifi_off":
            targetLabel = "Wi-Fi"
        case "cellular_on", "cellular_off":
            targetLabel = "Cellular"
        default:
            targetLabel = ""
        }

        // Find and tap the setting row
        guard let describeResult = describer.describe(skipOCR: false) else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture Settings screen",
                              durationSeconds: elapsed(startTime))
        }

        guard let match = ElementMatcher.findMatch(label: targetLabel,
                                                     in: describeResult.elements) else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "\"\(targetLabel)\" not found in Settings",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.tap(x: match.element.tapX, y: match.element.tapY) {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "Failed to tap \(targetLabel): \(error)",
                              durationSeconds: elapsed(startTime))
        }

        usleep(config.settlingDelayMs * 1000)

        _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")

        return StepResult(step: step, status: .passed,
                          message: "Toggled \(mode)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - measure

    private func executeMeasure(name: String, action: SkillStep, until: String,
                                 maxSeconds: Double?, stepIndex: Int,
                                 skillName: String,
                                 startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.measure(name: name, action: action,
                                         until: until, maxSeconds: maxSeconds)

        // Execute the nested action
        let actionResult = execute(step: action, stepIndex: stepIndex,
                                    skillName: skillName)
        if actionResult.status == .failed {
            return StepResult(step: step, status: .failed,
                              message: "Action failed: \(actionResult.message ?? "unknown")",
                              durationSeconds: elapsed(startTime))
        }

        // Start measuring
        let measureStart = CFAbsoluteTimeGetCurrent()
        let timeout = maxSeconds ?? Double(config.waitForTimeoutSeconds)
        let pollIntervalUs: useconds_t = EnvConfig.measurePollIntervalUs

        let maxPolls = Int(timeout * 2)  // 2 polls per second
        for _ in 0..<maxPolls {
            if let describeResult = describer.describe(skipOCR: false),
               ElementMatcher.isVisible(label: until, in: describeResult.elements) {
                let measuredSeconds = CFAbsoluteTimeGetCurrent() - measureStart
                if let max = maxSeconds, measuredSeconds > max {
                    return StepResult(step: step, status: .failed,
                                      message: "\(name): \(String(format: "%.3f", measuredSeconds))s exceeded \(String(format: "%.1f", max))s max",
                                      durationSeconds: elapsed(startTime))
                }
                return StepResult(step: step, status: .passed,
                                  message: "\(name): \(String(format: "%.3f", measuredSeconds))s",
                                  durationSeconds: elapsed(startTime))
            }
            usleep(pollIntervalUs)
        }

        let measuredSeconds = CFAbsoluteTimeGetCurrent() - measureStart
        return StepResult(step: step, status: .failed,
                          message: "\(name): timed out after \(String(format: "%.1f", measuredSeconds))s waiting for \"\(until)\"",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - switch_target

    private func executeSwitchTarget(name: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.switchTarget(name: name)

        guard let registry = registry else {
            return StepResult(step: step, status: .failed,
                              message: "No target registry — cannot switch targets",
                              durationSeconds: elapsed(startTime))
        }

        guard let ctx = registry.resolve(name) else {
            let available = registry.allTargets.map { $0.name }.joined(separator: ", ")
            return StepResult(step: step, status: .failed,
                              message: "Unknown target '\(name)'. Available: [\(available)]",
                              durationSeconds: elapsed(startTime))
        }

        subsystems = Subsystems(
            bridge: ctx.bridge,
            input: ctx.input,
            describer: ctx.describer,
            capture: ctx.capture
        )

        return StepResult(step: step, status: .passed,
                          message: "Switched to target '\(name)'",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - Helpers

    private func elapsed(_ startTime: CFAbsoluteTime) -> Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }

    /// Convenience cast to MenuActionCapable for steps that need menu actions.
    private var menuBridge: (any MenuActionCapable)? {
        bridge as? (any MenuActionCapable)
    }

    /// Swipe endpoints computed from a direction string and window dimensions.
    struct SwipeEndpoints {
        let fromX: Double, fromY: Double, toX: Double, toY: Double
    }

    /// Compute swipe start/end coordinates from a direction and window info.
    /// Returns nil for unknown directions.
    private func swipeEndpoints(
        direction: String, windowInfo: WindowInfo
    ) -> SwipeEndpoints? {
        let centerX = Double(windowInfo.size.width) / 2.0
        let centerY = Double(windowInfo.size.height) / 2.0
        let dist = Double(windowInfo.size.height) * EnvConfig.swipeDistanceFraction
        let half = dist / 2

        switch direction.lowercased() {
        case "up":
            return SwipeEndpoints(fromX: centerX, fromY: centerY + half,
                                  toX: centerX, toY: centerY - half)
        case "down":
            return SwipeEndpoints(fromX: centerX, fromY: centerY - half,
                                  toX: centerX, toY: centerY + half)
        case "left":
            return SwipeEndpoints(fromX: centerX + half, fromY: centerY,
                                  toX: centerX - half, toY: centerY)
        case "right":
            return SwipeEndpoints(fromX: centerX - half, fromY: centerY,
                                  toX: centerX + half, toY: centerY)
        default:
            return nil
        }
    }

    /// Save a screenshot for debugging when a step fails.
    private func captureFailureScreenshot(stepIndex: Int, skillName: String) {
        guard let base64 = capture.captureBase64(),
              let data = Data(base64Encoded: base64) else { return }

        let dir = config.screenshotDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let safeName = skillName.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_failure_step\(stepIndex + 1).png"
        let path = (dir as NSString).appendingPathComponent(filename)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
