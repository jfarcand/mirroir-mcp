// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Extension with multi-step action implementations for StepExecutor.
// ABOUTME: Contains scrollTo, resetApp, setNetwork, measure, switchTarget, and screenshot helpers.

import Foundation
import HelperLib

extension StepExecutor {

    // MARK: - scroll_to

    func executeScrollTo(label: String, direction: String, maxScrolls: Int,
                          startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.scrollTo(label: label, direction: direction,
                                          maxScrolls: maxScrolls)

        // Check if already visible
        if let describeResult = describer.describe(),
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
            if let describeResult = describer.describe() {
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

    // MARK: - long_press

    func executeLongPress(label: String, durationMs: Int?,
                           startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.longPress(label: label, durationMs: durationMs)

        guard let describeResult = describer.describe() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen for OCR",
                              durationSeconds: elapsed(startTime))
        }

        guard let match = ElementMatcher.findMatch(label: label, in: describeResult.elements) else {
            let available = describeResult.elements.map { $0.text }.joined(separator: ", ")
            return StepResult(step: step, status: .failed,
                              message: "Element \"\(label)\" not found. Visible: [\(available)]",
                              durationSeconds: elapsed(startTime))
        }

        let duration = durationMs ?? EnvConfig.defaultLongPressDurationMs
        if let error = input.longPress(x: match.element.tapX, y: match.element.tapY,
                                        durationMs: duration) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed,
                          message: "long press \(duration)ms via \(match.strategy.rawValue)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - drag

    func executeDrag(fromLabel: String, toLabel: String,
                      startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.drag(fromLabel: fromLabel, toLabel: toLabel)

        guard let describeResult = describer.describe() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen for OCR",
                              durationSeconds: elapsed(startTime))
        }

        guard let fromMatch = ElementMatcher.findMatch(label: fromLabel, in: describeResult.elements) else {
            return StepResult(step: step, status: .failed,
                              message: "Drag source \"\(fromLabel)\" not found",
                              durationSeconds: elapsed(startTime))
        }

        guard let toMatch = ElementMatcher.findMatch(label: toLabel, in: describeResult.elements) else {
            return StepResult(step: step, status: .failed,
                              message: "Drag target \"\(toLabel)\" not found",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.drag(fromX: fromMatch.element.tapX, fromY: fromMatch.element.tapY,
                                   toX: toMatch.element.tapX, toY: toMatch.element.tapY,
                                   durationMs: EnvConfig.defaultDragDurationMs) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed,
                          message: "dragged from \"\(fromLabel)\" to \"\(toLabel)\"",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - reset_app

    func executeResetApp(appName: String, startTime: CFAbsoluteTime) -> StepResult {
        let step = SkillStep.resetApp(appName: appName)
        guard let menuBridge = self.menuBridge else {
            return StepResult(step: step, status: .failed,
                              message: "Target '\(bridge.targetName)' does not support reset_app",
                              durationSeconds: elapsed(startTime))
        }

        // Launch the app via Spotlight. This handles localization: typing
        // "Settings" finds "Réglages" on a French iPhone, for example.
        if let error = input.launchApp(name: appName) {
            return StepResult(step: step, status: .failed,
                              message: "Failed to launch '\(appName)': \(error)",
                              durationSeconds: elapsed(startTime))
        }
        usleep(config.settlingDelayMs * 1000)

        // Open the App Switcher. The just-launched app is guaranteed
        // to be the centered (most-recently-used) card.
        guard menuBridge.triggerMenuAction(menu: "View", item: "App Switcher") else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "Failed to open App Switcher",
                              durationSeconds: elapsed(startTime))
        }
        usleep(config.settlingDelayMs * 1000)

        // Verify the App Switcher is showing cards before swiping.
        // We don't match the app name because Spotlight already
        // resolved localization (e.g. "Settings" → "Réglages") and
        // the just-launched app is guaranteed to be the centered card.
        guard let ocrResult = describer.describe() else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture App Switcher screen for verification",
                              durationSeconds: elapsed(startTime))
        }
        guard !ocrResult.elements.isEmpty else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return StepResult(step: step, status: .failed,
                              message: "App Switcher appears empty — no app cards detected",
                              durationSeconds: elapsed(startTime))
        }

        // Drag up on the centered card to dismiss it.
        let windowSize = bridge.getWindowInfo()?.size
        let cardX = (windowSize.map { Double($0.width) } ?? 410.0) * EnvConfig.appSwitcherCardXFraction
        let cardY = (windowSize.map { Double($0.height) } ?? 890.0) * EnvConfig.appSwitcherCardYFraction
        let toY = max(0, cardY - EnvConfig.appSwitcherSwipeDistance)
        if let error = input.drag(fromX: cardX, fromY: cardY,
                                   toX: cardX, toY: toY,
                                   durationMs: EnvConfig.appSwitcherSwipeDurationMs) {
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

    func executeSetNetwork(mode: String, startTime: CFAbsoluteTime) -> StepResult {
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
        guard let describeResult = describer.describe() else {
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

    func executeMeasure(name: String, action: SkillStep, until: String,
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
            if let describeResult = describer.describe(),
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

    func executeSwitchTarget(name: String, startTime: CFAbsoluteTime) -> StepResult {
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

        switchSubsystems(bridge: ctx.bridge, input: ctx.input,
                         describer: ctx.describer, capture: ctx.capture)

        return StepResult(step: step, status: .passed,
                          message: "Switched to target '\(name)'",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - Swipe Geometry

    /// Swipe endpoints computed from a direction string and window dimensions.
    struct SwipeEndpoints {
        let fromX: Double, fromY: Double, toX: Double, toY: Double
    }

    /// Compute swipe start/end coordinates from a direction and window info.
    /// Returns nil for unknown directions.
    func swipeEndpoints(
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

    // MARK: - Screenshot Helpers

    /// Capture and decode a screenshot as raw PNG data.
    /// Returns nil if capture or base64 decode fails.
    func captureScreenshotData() -> Data? {
        guard let base64 = capture.captureBase64(),
              let data = Data(base64Encoded: base64) else { return nil }
        return data
    }

    /// Write PNG data to the screenshot directory, creating it if needed.
    /// Returns the written file path, or nil on failure.
    @discardableResult
    func saveScreenshot(_ data: Data, filename: String) -> String? {
        let dir = config.screenshotDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(filename)
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    /// Save a screenshot for debugging when a step fails.
    func captureFailureScreenshot(stepIndex: Int, skillName: String) {
        guard let data = captureScreenshotData() else { return }
        let safeName = skillName.replacingOccurrences(of: " ", with: "_")
        saveScreenshot(data, filename: "\(safeName)_failure_step\(stepIndex + 1).png")
    }
}
