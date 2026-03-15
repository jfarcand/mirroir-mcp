// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Classifies navigation transitions as push/modal/tab/same/dead for intelligent backtracking.
// ABOUTME: Pure transformation: analyzes source/destination elements to determine edge type.

import Foundation
import HelperLib

/// The type of navigation transition between two screens.
enum EdgeType: String, Sendable {
    /// Standard push navigation — destination has a back chevron in the top zone.
    case push
    /// Modal presentation — destination has Close/Done/Cancel/X, no back chevron.
    case modal
    /// Tab switch — tapped element was in the tab bar zone of a tabRoot screen.
    case tab
    /// No navigation occurred — source and destination are the same screen.
    case same
    /// Unreachable or destructive transition — recovery requires pressing Home.
    case dead
    /// Same screen with state change (toggle, switch) — no backtrack needed.
    case toggle
    /// Left the app entirely (Safari, App Store, etc.) — requires relaunching.
    case external
}

/// Classifies navigation transitions for intelligent backtracking.
/// Analyzes source screen context and destination elements to determine
/// how the explorer should reverse a given transition.
enum EdgeClassifier {

    /// Dismiss button text patterns recognized in the top zone of modals.
    static let dismissPatterns: Set<String> = ["Close", "Done", "Cancel", "X", "Dismiss"]

    /// Fraction of screen height that defines the bottom tab bar zone.
    static let tabBarZoneFraction: Double = 0.85

    /// Classify a navigation transition based on source context and destination content.
    ///
    /// Classification priority:
    /// 1. **tab**: source is `.tabRoot` AND tapped element is in the bottom zone
    /// 2. **modal**: destination has dismiss button in top zone AND no back chevron
    /// 3. **push**: destination hints contain back chevron (most iOS navigations)
    /// 4. **Fallback**: `.push` — safe default for most iOS navigations
    ///
    /// Note: `toggle` and `external` are not detected here — they are set by the
    /// explorer when the graph reports `.duplicate` (toggle) or context escape (external).
    ///
    /// - Parameters:
    ///   - sourceNode: The screen node the action originated from.
    ///   - destinationElements: OCR elements from the destination screen.
    ///   - destinationHints: Navigation hints from the destination screen.
    ///   - tappedElement: The element that was tapped to trigger navigation.
    ///   - screenHeight: Height of the target window for zone calculations.
    /// - Returns: The classified edge type.
    static func classify(
        sourceNode: ScreenNode,
        destinationElements: [TapPoint],
        destinationHints: [String],
        tappedElement: TapPoint,
        screenHeight: Double
    ) -> EdgeType {
        // 1. Tab switch: source is tabRoot and tapped element is in bottom zone
        if sourceNode.screenType == .tabRoot
            && tappedElement.tapY >= screenHeight * tabBarZoneFraction {
            return .tab
        }

        let topZone = screenHeight * NavigationHintDetector.topZoneFraction
        let hasBackChevron = destinationElements.contains { el in
            let trimmed = el.text.trimmingCharacters(in: .whitespaces)
            return NavigationHintDetector.backChevronPatterns.contains(trimmed)
                && el.tapY <= topZone
        }

        // 2. Modal: dismiss button in top zone, no back chevron
        let hasDismiss = destinationElements.contains { el in
            let trimmed = el.text.trimmingCharacters(in: .whitespaces)
            return dismissPatterns.contains(trimmed)
                && el.tapY <= topZone
        }

        if hasDismiss && !hasBackChevron {
            return .modal
        }

        // 3. Push: back chevron detected in destination
        if hasBackChevron {
            return .push
        }

        // 4. Fallback: assume push (safe default for most iOS navigations)
        return .push
    }

    /// Find a dismiss button (Close/Done/Cancel/X) in the top zone of the screen.
    /// Used by backtracking logic to dismiss modals.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the current screen.
    ///   - screenHeight: Height of the target window for zone calculations.
    /// - Returns: The tap point of the dismiss button, or nil if none found.
    static func findDismissTarget(
        elements: [TapPoint], screenHeight: Double
    ) -> TapPoint? {
        let topZone = screenHeight * NavigationHintDetector.topZoneFraction
        return elements.first { el in
            let trimmed = el.text.trimmingCharacters(in: .whitespaces)
            return dismissPatterns.contains(trimmed) && el.tapY <= topZone
        }
    }
}
