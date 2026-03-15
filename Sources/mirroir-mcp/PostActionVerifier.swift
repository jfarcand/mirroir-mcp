// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Verifies the outcome of forward taps during exploration and classifies the result.
// ABOUTME: Detects dead taps, unexpected screens, and crash/escape conditions for recovery.

import Foundation
import HelperLib

/// A recovery event logged during exploration for post-hoc diagnosis.
struct RecoveryEvent: Sendable {
    /// Timestamp of the recovery event.
    let timestamp: Date
    /// Fingerprint of the screen where the event occurred.
    let screenFingerprint: String
    /// Category of the recovery event.
    let category: RecoveryCategory
    /// Human-readable description of what happened.
    let description: String
}

/// Categories of recovery events during exploration.
enum RecoveryCategory: String, Sendable {
    /// A tap had no effect — the screen didn't change.
    case deadTap
    /// An iOS system alert was detected and dismissed.
    case alertDismissed
    /// The explorer landed on an unexpected but known screen.
    case unexpectedScreen
    /// The app crashed or the explorer escaped to the home screen.
    case appEscape
    /// The app was relaunched after a crash/escape.
    case appRelaunched
}

/// Result of verifying a forward tap action.
enum TapVerification: Sendable {
    /// The tap navigated to a new or revisited screen — normal behavior.
    case navigated
    /// The tap had no visible effect — element was not interactive.
    case deadTap
    /// An alert appeared after the tap and was dismissed.
    case alertDismissed
    /// The explorer left the app (crash, external link, home screen).
    case appEscape(diagnosis: String)
}

/// Verifies the outcome of forward taps during exploration.
/// Pure transformation: analyzes before/after screen state to classify tap results.
/// Used by both BFS and DFS explorers after every forward tap.
enum PostActionVerifier {

    /// Classify the result of a forward tap by comparing before/after screen state.
    ///
    /// Classification priority:
    /// 1. **Alert**: after-screen has few elements matching alert patterns → `.alertDismissed`
    ///    (caller should already have dismissed it via `dismissAlertIfPresent`)
    /// 2. **App escape**: after-screen matches home/system screen → `.appEscape`
    /// 3. **Dead tap**: before and after screens are structurally identical → `.deadTap`
    /// 4. **Navigated**: screens differ → `.navigated`
    ///
    /// - Parameters:
    ///   - beforeElements: OCR elements from the screen before the tap.
    ///   - afterElements: OCR elements from the screen after the tap (post-alert-dismissal).
    ///   - screenHeight: Height of the target window for zone calculations.
    /// - Returns: The classified tap result.
    static func classify(
        beforeElements: [TapPoint],
        afterElements: [TapPoint],
        screenHeight: Double
    ) -> TapVerification {
        // Check for app escape (home screen, system screen)
        let diagnosis = AppContextDetector.diagnose(
            elements: afterElements, screenHeight: screenHeight
        )
        switch diagnosis {
        case .homeScreen:
            return .appEscape(diagnosis: "home screen detected")
        case .lockOrSystemScreen(let desc):
            return .appEscape(diagnosis: desc)
        case .inApp:
            break
        }

        // Check for dead tap (same screen, no change)
        if StructuralFingerprint.areEquivalentTitleAware(beforeElements, afterElements) {
            return .deadTap
        }

        return .navigated
    }

    /// Build a RecoveryEvent for logging.
    ///
    /// - Parameters:
    ///   - category: The type of recovery event.
    ///   - screenFingerprint: Fingerprint of the screen where the event occurred.
    ///   - description: Human-readable description.
    /// - Returns: A timestamped recovery event.
    static func buildEvent(
        category: RecoveryCategory,
        screenFingerprint: String,
        description: String
    ) -> RecoveryEvent {
        RecoveryEvent(
            timestamp: Date(),
            screenFingerprint: screenFingerprint,
            category: category,
            description: description
        )
    }
}
