// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects Spotlight search overlay on the iPhone screen via OCR element analysis.
// ABOUTME: Used after app launch to verify the app is visible before starting exploration.

import Foundation
import HelperLib

/// Detects whether iOS Spotlight search overlay is currently visible on screen.
/// Used to verify app readiness after launch — Spotlight may linger if the app
/// takes time to open or if the Return key didn't register.
enum SpotlightDetector {

    /// Maximum poll attempts before giving up on Spotlight dismissal.
    static let maxRetries = 5

    /// Delay between poll attempts in milliseconds.
    static let retryDelayMs: UInt32 = 500

    /// Text patterns that indicate Spotlight search overlay is still visible.
    /// Covers English, French, Spanish, and German locales.
    static let indicators: [String] = [
        "Top Hit", "Meilleur résultat",
        "Search in App", "Rechercher dans l'app",
        "Siri Suggestions", "Suggestions de Siri",
        "Siri-Vorschläge", "Sugerencias de Siri",
    ]

    /// Check if the current screen shows Spotlight search overlay.
    static func isSpotlightVisible(elements: [TapPoint]) -> Bool {
        elements.contains { el in
            let lower = el.text.lowercased()
            return indicators.contains { lower.contains($0.lowercased()) }
        }
    }

    /// Poll until Spotlight is dismissed, returning the first clean screen result.
    /// Returns nil if Spotlight persists after all retries.
    static func waitForDismissal(
        describer: ScreenDescribing
    ) -> ScreenDescriber.DescribeResult? {
        for _ in 0..<maxRetries {
            usleep(retryDelayMs * 1000)
            guard let result = describer.describe() else { continue }
            if !isSpotlightVisible(elements: result.elements) {
                return result
            }
        }
        return nil
    }
}
