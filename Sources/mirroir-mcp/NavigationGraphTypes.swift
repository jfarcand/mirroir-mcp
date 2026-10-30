// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Data types used by NavigationGraph — screen type, transition result, screen node, navigation edge.
// ABOUTME: Extracted from NavigationGraph.swift to keep the main graph implementation focused on behavior.

import Foundation
import HelperLib

/// Classification of a screen's role in the app navigation hierarchy.
enum ScreenType: String, Sendable {
    /// A screen with a tab bar (root-level navigation).
    case tabRoot
    /// A scrollable list of items.
    case list
    /// A detail/leaf screen showing specific content.
    case detail
    /// A modal overlay (has "Close", "Done", or "Cancel").
    case modal
    /// A settings-style screen with grouped rows.
    case settings
    /// Screen type could not be determined.
    case unknown
}

/// The result of recording a navigation transition in the graph.
enum TransitionResult: Sendable {
    /// Arrived at a screen not previously seen.
    case newScreen(fingerprint: String)
    /// Returned to a previously visited screen.
    case revisited(fingerprint: String)
    /// Screen is structurally identical to the source (action had no effect).
    case duplicate
}

/// A node in the navigation graph representing a single screen state.
struct ScreenNode: Sendable {
    /// Structural fingerprint identifying this screen.
    let fingerprint: String
    /// OCR elements visible on the screen.
    let elements: [TapPoint]
    /// Detected icon positions (tab bar, toolbar).
    let icons: [IconDetector.DetectedIcon]
    /// Navigation hints (back button detected, etc.).
    let hints: [String]
    /// DFS depth at which this screen was first discovered.
    let depth: Int
    /// Classified screen type.
    let screenType: ScreenType
    /// Base64-encoded screenshot.
    let screenshotBase64: String
    /// Set of element texts that have been tapped/visited from this screen.
    var visitedElements: Set<String>
    /// Extracted nav bar title for fast screen identity comparison.
    let navBarTitle: String?
    /// Whether this screen has infinite scroll (every scroll reveals new content).
    /// Set during calibration when scrolling never exhausts.
    var isInfiniteScroll: Bool = false
    /// Whether scroll exhaustion was reached (no new elements after scrolling).
    var scrollExhausted: Bool = false
    /// Perceptual hash of the screenshot for visual state identity.
    /// Optional for backward compatibility: nil when screenshot data is unavailable.
    var visualHash: UInt64?
    /// How many trailing entries of `elements` were merged in by scrolling after
    /// the screen was recorded. The leading `elements.count - scrolledElementCount`
    /// are the viewport the screen showed on arrival — what a replay sees the
    /// moment the action that reached it lands. Graph persistence does not carry
    /// it: a node restored from disk is never emitted as a scenario.
    var scrolledElementCount: Int = 0
}

/// A directed edge in the navigation graph representing a navigation action.
struct NavigationEdge: Sendable {
    /// Fingerprint of the source screen.
    let fromFingerprint: String
    /// Fingerprint of the destination screen.
    let toFingerprint: String
    /// Type of action that caused the transition (e.g. "tap", "swipe").
    let actionType: String
    /// The raw element text used for visited-state matching (must match what was tapped).
    let elementText: String
    /// Clean label derived from the component's LabelRule, free of OCR artifacts.
    /// Used for skill step naming and path display. Falls back to `elementText` when
    /// no component context is available.
    let displayLabel: String
    /// Classified transition type for intelligent backtracking.
    let edgeType: EdgeType
    /// Learned action-value estimate (Fastbot2 pattern). Edges that led to new screens
    /// accumulate reward; revisited screens decay; dead taps go to zero. Persisted across
    /// runs so each exploration starts smarter than the last.
    var qValue: Double

    init(fromFingerprint: String, toFingerprint: String, actionType: String,
         elementText: String, displayLabel: String, edgeType: EdgeType,
         qValue: Double = 1.0) {
        self.fromFingerprint = fromFingerprint
        self.toFingerprint = toFingerprint
        self.actionType = actionType
        self.elementText = elementText
        self.displayLabel = displayLabel
        self.edgeType = edgeType
        self.qValue = qValue
    }
}
