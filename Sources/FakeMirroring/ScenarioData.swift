// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Render-time data shape consumed by FakeScreenView's draw pipeline.
// ABOUTME: Produced by SceneRenderer (AppPack-driven) and overlay sceneData() methods.

import AppKit
import HelperLib

/// A summary card for legacy Health/Santé-style scenarios.
/// Kept as a public struct because FakeScreenDrawing.swift still
/// renders cards when a scene declares them (none currently do; ready for future schema extension).
struct CardData {
    let title: String
    let value: String
    let subtitle: String
    let color: NSColor
    let rect: CGRect
}

/// Render-time payload for one screen frame.
/// Every code path that produces a drawable scene (AppPack screen, obstacle,
/// Spotlight overlay, App Switcher overlay) emits one of these.
struct ScenarioData {
    let header: String
    /// Rows with ">" disclosure chevrons (settings-style list items).
    let rows: [(String, CGPoint)]
    let hasTabBar: Bool
    /// How the tab bar renders when `hasTabBar` is true (labels vs icon-only).
    var tabBarStyle: SimulatorTabBarStyle = .labels
    /// The screen's own tab names, labelling the tab bar's first columns in
    /// declaration order; the generic labels fill the remaining columns.
    var tabLabels: [String] = []
    /// Free text labels without chevrons (captions, stats, links).
    var plainTexts: [(String, CGPoint)] = []
    /// Pill-shaped buttons with centered text.
    var buttons: [(String, CGRect)] = []
    /// Gray placeholder rectangles (simulating images in a feed).
    var placeholders: [CGRect] = []
    /// Whether to render a "<" back chevron in the top-left header zone.
    var hasBackChevron: Bool = false
    /// Card summary blocks with accent color and stats.
    var cards: [CardData] = []
    /// Horizontal slider track rect + label prefix for drag testing.
    var sliderTrack: (label: String, rect: CGRect)? = nil
    /// Text field rects that accept keyboard input on tap.
    var textFieldRects: [CGRect] = []
}
