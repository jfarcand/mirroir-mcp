// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Returns the iPhone to the target app's root screen, preferring tap-back over Spotlight relaunch.
// ABOUTME: Spotlight is the fallback only when in-app tap-back navigation can't reach the root fingerprint.

import CoreGraphics
import Foundation
import HelperLib

/// Navigation-to-root primitive shared by BFS recovery sites.
/// Each Spotlight relaunch costs ~3 seconds and visibly resets the app on the
/// iPhone. When the iPhone is still inside the target app, tapping the back
/// chevron a few times is faster and less disruptive — and the existing
/// `Backtracking` protocol already knows how to find the chevron via OCR.
enum AppRootNavigator {

    /// Maximum tap-back attempts before giving up and falling back to Spotlight.
    /// Three covers the common case of recovering from a depth-3 sub-screen;
    /// pushing higher just delays the inevitable Spotlight on apps that lack
    /// a chevron at root (modal sidebars, tab bars without back buttons).
    static let maxTapBackAttempts = 3

    enum ResetResult: Equatable {
        /// Reached the root fingerprint via in-app tap-back navigation.
        case navigatedInApp(tapBacks: Int)
        /// Tap-back didn't reach root (or root elements unknown) — fell back to Spotlight.
        case relaunchedViaSpotlight
    }

    /// Best-effort navigate to the app's root screen.
    /// Returns `.navigatedInApp` when in-app tap-back succeeded; otherwise
    /// performs a Spotlight relaunch and returns `.relaunchedViaSpotlight`.
    @discardableResult
    static func resetToRoot(
        appName: String,
        rootElements: [TapPoint]?,
        input: any InputProviding,
        describer: any ScreenDescribing,
        backtracker: any Backtracking,
        windowSize: CGSize,
        backButtonFallback: BackButtonFallback
    ) -> ResetResult {
        if let rootElements,
           let result = tryTapBackToRoot(
               rootElements: rootElements,
               appName: appName,
               input: input,
               describer: describer,
               backtracker: backtracker,
               windowSize: windowSize,
               backButtonFallback: backButtonFallback) {
            return result
        }
        DebugLog.log("navigate",
            "tap-back navigation unavailable or exhausted — Spotlight-relaunching '\(appName)'")
        _ = input.launchApp(name: appName)
        usleep(EnvConfig.toolSettlingDelayUs)
        return .relaunchedViaSpotlight
    }

    private static func tryTapBackToRoot(
        rootElements: [TapPoint],
        appName: String,
        input: any InputProviding,
        describer: any ScreenDescribing,
        backtracker: any Backtracking,
        windowSize: CGSize,
        backButtonFallback: BackButtonFallback
    ) -> ResetResult? {
        for attempt in 0..<maxTapBackAttempts {
            guard let result = describer.describe() else { return nil }
            let similarity = AppForegroundDetector.jaccardSimilarity(
                current: result.elements, root: rootElements)
            if similarity >= AppForegroundDetector.matchThreshold {
                DebugLog.log("navigate",
                    "reached '\(appName)' root after \(attempt) tap-back(s) " +
                    "(similarity \(String(format: "%.2f", similarity))) — skipping Spotlight")
                return .navigatedInApp(tapBacks: attempt)
            }
            _ = backtracker.tapBack(
                elements: result.elements, input: input,
                windowSize: windowSize, fallback: backButtonFallback)
            usleep(EnvConfig.toolSettlingDelayUs)
        }
        return nil
    }
}
