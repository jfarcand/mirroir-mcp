// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared utility functions for app exploration: alert dismissal, back button navigation, app context verification.
// ABOUTME: Used by BFSExplorer and DFSExplorer for common operations independent of traversal strategy.

import Foundation
import HelperLib

/// Shared utilities for app exploration, independent of traversal strategy (BFS/DFS).
/// Pure transformation: all static methods, no stored state.
enum ExplorerUtilities {

    /// Portrait-iPhone back-button fallback position. Preserved as a default
    /// for call sites that don't thread a target profile through (tests, legacy).
    /// Orientation-aware sites pass an explicit `BackButtonFallback` instead.
    static let defaultBackButtonFallback = BackButtonFallback(
        xFraction: 0.112, yFraction: 0.135
    )

    // MARK: - Alert Dismissal

    /// OCR the screen and dismiss any detected iOS alert before returning the result.
    /// If no alert is detected, the initial OCR result is returned directly (zero overhead).
    /// Retries up to `AlertDetector.maxDismissAttempts` times for persistent alerts.
    ///
    /// - Parameters:
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for tap actions.
    /// - Returns: Clean OCR result after dismissing any alerts, or nil if OCR fails.
    /// OCR the screen, dismiss system alerts and app-specific obstacles, return clean result.
    ///
    /// When `obstacles` is non-empty (from APP.md), also checks for app-specific dialog
    /// patterns and auto-dismisses them. System alerts (AlertDetector) are checked first.
    ///
    /// - Parameters:
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for tap actions.
    ///   - obstacles: App-specific obstacle rules from APP.md (default: empty).
    /// - Returns: Clean OCR result after dismissing any alerts/obstacles, or nil if OCR fails.
    ///   Every read waits for a settled frame (`frameSettleTimeoutUs`): this is the
    ///   screen an action led to, and a frame taken mid-transition would record a
    ///   destination that never exists (a sheet still sliding over the old screen).
    static func dismissAlertIfPresent(
        describer: ScreenDescribing,
        input: InputProviding,
        obstacles: [ObstacleRule] = []
    ) -> ScreenDescriber.DescribeResult? {
        guard var result = describer.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs) else { return nil }

        // Triggers that re-appeared after we dismissed them — a self-re-arming
        // dialog (e.g. the "camera not available" alert on Instagram's Story
        // camera, which the underlying screen pops right back). Once a trigger
        // is here we stop tapping its (futile) action and fall through to the
        // next obstacle, which is typically one that EXITS the screen (tap "X").
        var rearmingTriggers: Set<String> = []

        for _ in 0..<AlertDetector.maxDismissAttempts {
            // System alert takes priority
            if let alert = AlertDetector.detectAlert(elements: result.elements) {
                _ = input.tap(x: alert.dismissTarget.tapX, y: alert.dismissTarget.tapY)
                usleep(EnvConfig.stepSettlingDelayMs * 1000)
                guard let cleanResult = describer.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs) else { return nil }
                result = cleanResult
                continue
            }

            // App-specific obstacle: check if any trigger text appears on screen
            var dismissed = false
            for obstacle in obstacles {
                let triggerLower = obstacle.trigger.lowercased()
                guard result.elements.contains(where: {
                    $0.text.lowercased().contains(triggerLower)
                }) else { continue }

                // Skip an obstacle whose trigger keeps re-arming — dismissing it
                // makes no progress; try a later obstacle that exits the screen.
                if rearmingTriggers.contains(triggerLower) { continue }

                let actionLower = obstacle.action.lowercased()
                guard let target = result.elements.first(where: {
                    $0.text.lowercased().contains(actionLower)
                }) else { continue }

                DebugLog.log("app-desc",
                    "obstacle detected: '\(obstacle.trigger)' → tapping '\(target.text)'")
                _ = input.tap(x: target.tapX, y: target.tapY)
                usleep(EnvConfig.stepSettlingDelayMs * 1000)
                guard let cleanResult = describer.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs) else { return nil }
                result = cleanResult
                // If the trigger survived the dismissal, it is self-re-arming;
                // don't tap its action again on the next pass.
                if result.elements.contains(where: {
                    $0.text.lowercased().contains(triggerLower)
                }) {
                    rearmingTriggers.insert(triggerLower)
                    DebugLog.log("app-desc",
                        "obstacle '\(obstacle.trigger)' re-armed — will try a screen-exit obstacle next")
                }
                dismissed = true
                break
            }

            if !dismissed { return result }
        }

        return result
    }

    /// Return the first APP.md obstacle trigger still present on `elements`, or nil.
    ///
    /// Call this immediately after `dismissAlertIfPresent`: an obstacle whose
    /// trigger AND action element are both still on screen could not be cleared
    /// within the dismissal budget — a self-re-arming trap (e.g. the Story camera,
    /// whose "camera not available" dialog re-pops every frame). Requiring the
    /// action element too means `dismissAlertIfPresent` actually tried to dismiss
    /// it (and failed), so incidental text that merely matches a trigger — with no
    /// dismiss target — is not misread as a trap. Normal obstacles clear in one
    /// pass and so never persist here.
    static func persistentObstacle(
        elements: [TapPoint], obstacles: [ObstacleRule]
    ) -> String? {
        for obstacle in obstacles {
            let triggerLower = obstacle.trigger.lowercased()
            let actionLower = obstacle.action.lowercased()
            let triggerPresent = elements.contains { $0.text.lowercased().contains(triggerLower) }
            let actionPresent = elements.contains { $0.text.lowercased().contains(actionLower) }
            if triggerPresent && actionPresent {
                return obstacle.trigger
            }
        }
        return nil
    }

    // MARK: - Back Button Navigation

    /// Find and tap the "<" back button on the current screen.
    /// iPhone Mirroring does not support iOS edge-swipe-back gestures (neither
    /// scroll wheel nor touch-drag triggers UIScreenEdgePanGestureRecognizer).
    /// Tapping the OCR-detected back chevron is the only reliable backtrack method.
    ///
    /// First attempts to find the "<" chevron via OCR elements. If OCR misses the
    /// back button, falls back to tapping at the canonical iOS navigation bar position.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the current screen (avoids redundant OCR call).
    ///   - input: Input provider for tap actions.
    ///   - windowSize: Window size for fallback position calculation.
    /// - Returns: Always `true` (canonical position fallback guarantees a tap).
    @discardableResult
    static func tapBackButton(
        elements: [TapPoint],
        input: InputProviding,
        windowSize: CGSize,
        fallback: BackButtonFallback = defaultBackButtonFallback
    ) -> Bool {
        let topZone = windowSize.height * NavigationHintDetector.topZoneFraction
        if let backButton = elements.first(where: { element in
            let trimmed = element.text.trimmingCharacters(in: .whitespaces)
            return NavigationHintDetector.backChevronPatterns.contains(trimmed)
                && element.tapY <= topZone
        }) {
            _ = input.tap(x: backButton.tapX, y: backButton.tapY)
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
            return true
        }

        // OCR sometimes fails to detect the "<" chevron, but the back button is
        // at a predictable position. Tap the target-provided fallback.
        let fallbackX = windowSize.width * fallback.xFraction
        let fallbackY = windowSize.height * fallback.yFraction
        _ = input.tap(x: fallbackX, y: fallbackY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        return true
    }

    // MARK: - Combined Navigate Back

    /// Tap back and OCR the resulting screen. Combines tapBackButton + dismissAlertIfPresent.
    ///
    /// - Parameters:
    ///   - currentElements: Elements from the current screen (for back button detection).
    ///   - input: Input provider for tap actions.
    ///   - describer: Screen describer for OCR.
    ///   - windowSize: Window size for fallback position calculation.
    ///   - fallback: Canonical back-button position used when OCR misses the chevron.
    /// - Returns: OCR result of the screen after tapping back, or nil if OCR fails.
    static func navigateBack(
        currentElements: [TapPoint],
        input: InputProviding,
        describer: ScreenDescribing,
        windowSize: CGSize,
        fallback: BackButtonFallback = defaultBackButtonFallback
    ) -> ScreenDescriber.DescribeResult? {
        tapBackButton(
            elements: currentElements, input: input,
            windowSize: windowSize, fallback: fallback
        )
        return dismissAlertIfPresent(describer: describer, input: input)
    }

    // MARK: - App Context Verification

    /// Result of verifying the explorer is still inside the target app.
    enum ContextCheckResult: Sendable {
        /// The explorer is inside the app — no action needed.
        case ok
        /// The explorer had left the app but was recovered via relaunch.
        case recovered
        /// The explorer left the app and recovery failed.
        case failed(reason: String)
    }

    /// Verify that OCR elements indicate the explorer is still inside the target app.
    /// If the explorer has escaped (home screen, system screen), attempts recovery
    /// by relaunching the app via Spotlight.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the current screen.
    ///   - screenHeight: Height of the mirroring window in points.
    ///   - appName: Name of the target app for recovery via relaunch.
    ///   - input: Input provider for app relaunch.
    ///   - describer: Screen describer for post-recovery OCR.
    /// - Returns: `.ok` if still in app, `.recovered` if relaunched successfully, `.failed` if unrecoverable.
    static func verifyAppContext(
        elements: [TapPoint],
        screenHeight: Double,
        appName: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ContextCheckResult {
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)

        switch diagnosis {
        case .inApp:
            return .ok

        case .homeScreen:
            DebugLog.log("context", "Detected home screen — explorer escaped \(appName)")
            return attemptRecovery(appName: appName, input: input, describer: describer)

        case .lockOrSystemScreen(let description):
            DebugLog.log("context", "Detected system screen (\(description)) — explorer escaped \(appName)")
            return attemptRecovery(appName: appName, input: input, describer: describer)
        }
    }

    /// Attempt to recover by relaunching the app via Spotlight.
    /// Re-diagnoses after relaunch to confirm we're back inside the app.
    private static func attemptRecovery(
        appName: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ContextCheckResult {
        DebugLog.log("context", "Attempting recovery: relaunching \"\(appName)\"")

        _ = input.launchApp(name: appName)

        // Wait for Spotlight to dismiss and app to appear
        guard let result = SpotlightDetector.waitForDismissal(describer: describer) else {
            return .failed(reason: "OCR failed after relaunch attempt")
        }

        // Verify we landed back in the app
        let postDiagnosis = AppContextDetector.diagnose(
            elements: result.elements, screenHeight: Double(result.elements.map(\.tapY).max() ?? 890)
        )

        switch postDiagnosis {
        case .inApp:
            DebugLog.log("context", "Recovery successful — back inside \"\(appName)\"")
            return .recovered
        case .homeScreen:
            DebugLog.log("context", "Recovery failed — still on home screen")
            return .failed(reason: "Still on home screen after relaunch")
        case .lockOrSystemScreen(let desc):
            DebugLog.log("context", "Recovery failed — still on system screen (\(desc))")
            return .failed(reason: "Still on system screen (\(desc)) after relaunch")
        }
    }

    // MARK: - OCR Stabilization

    /// Capture the screen repeatedly until OCR produces N consecutive identical
    /// structural element sets, or maxAttempts is reached. Returns the first stable result.
    /// This ensures the screen has fully settled (animations complete, content loaded)
    /// before the explorer acts on the OCR output.
    static func stabilizedDescribe(
        describer: ScreenDescribing,
        requiredConsecutive: Int = 2,
        maxAttempts: Int = 4
    ) -> ScreenDescriber.DescribeResult? {
        guard let first = describer.describe() else { return nil }
        guard requiredConsecutive > 1 else { return first }

        var lastTexts = Set(first.elements.map { $0.text })
        var lastResult = first
        var consecutiveCount = 1

        for _ in 1 ..< maxAttempts {
            usleep(50_000) // 50ms between captures
            guard let result = describer.describe() else { continue }
            let texts = Set(result.elements.map { $0.text })
            if texts == lastTexts {
                consecutiveCount += 1
                if consecutiveCount >= requiredConsecutive { return result }
            } else {
                consecutiveCount = 1
                lastTexts = texts
                lastResult = result
            }
        }
        return lastResult
    }
}
