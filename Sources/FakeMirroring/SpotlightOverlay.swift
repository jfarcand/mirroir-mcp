// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: iOS-Spotlight-like search overlay used by FakeMirroring to launch simulated apps.
// ABOUTME: Renders the indicator strings SpotlightDetector.swift looks for so mirroir-mcp recognizes the overlay.

import AppKit
import HelperLib

/// State for an active Spotlight search overlay.
/// Owned by FakeScreenView; the overlay's render and tap routing are handled
/// inside the view's draw/mouseUp pipeline so they live alongside the scene
/// rendering rather than in a parallel layer.
@MainActor
final class SpotlightOverlay {
    /// What the user has typed so far. Populated via FakeScreenView.keyDown.
    var query: String = ""
    /// First app whose Spotlight name matches the current query, if any.
    var topResult: AppPack?

    private let registry: AppRegistry
    /// Called when the user presses Return to launch (or Esc to dismiss).
    /// Receives the launched pack on success, or nil when the overlay was
    /// dismissed without a launch.
    let onResolve: (AppPack?) -> Void

    init(registry: AppRegistry, onResolve: @escaping (AppPack?) -> Void) {
        self.registry = registry
        self.onResolve = onResolve
    }

    /// Update the search and recompute the top result.
    func setQuery(_ q: String) {
        query = q
        topResult = registry.lookup(spotlightInput: q)
    }

    /// User pressed Return — launch the top result (or dismiss if no match).
    func commit() {
        onResolve(topResult)
    }

    /// User pressed Escape — close without launching.
    func cancel() {
        onResolve(nil)
    }

    /// Render this overlay as ScenarioData so FakeScreenView's existing draw
    /// pipeline can paint it. The indicator strings let mirroir-mcp's
    /// SpotlightDetector recognize that Spotlight is up.
    func sceneData() -> ScenarioData {
        var plainTexts: [(String, CGPoint)] = []
        // SpotlightDetector indicators — must be present verbatim. As on the iPhone,
        // only a query with an app behind it has a top hit, and the field then says
        // Return opens it; the idle page shows Siri's suggestions.
        let heading = topResult != nil ? "Top Hit" : (query.isEmpty ? "Siri Suggestions" : "Suggestions")
        plainTexts.append((heading, CGPoint(x: 20, y: 80)))
        plainTexts.append(("Search in App", CGPoint(x: 20, y: 110)))
        // Search query echo
        let displayQuery = query.isEmpty ? "Search" : query
        let field = topResult != nil ? "\(displayQuery) - Open" : displayQuery
        plainTexts.append((field, CGPoint(x: 20, y: 160)))
        // Top result line
        if let top = topResult {
            plainTexts.append((top.spec.appName, CGPoint(x: 20, y: 220)))
        }
        return ScenarioData(
            header: "",
            rows: [],
            hasTabBar: false,
            plainTexts: plainTexts,
            buttons: [],
            placeholders: [],
            hasBackChevron: false,
            cards: [],
            sliderTrack: nil,
            textFieldRects: []
        )
    }
}
