// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TapAreaCache coordinate tracking and proximity detection.
// ABOUTME: Tests for NavigationGraph tap cache integration and ExplorationReportFormatter output.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class TapAreaCacheTests: XCTestCase {

    // MARK: - TapAreaCache Unit Tests

    func testEmptyCacheReportsNotTapped() {
        let cache = TapAreaCache()
        XCTAssertFalse(cache.wasAlreadyTapped(x: 100, y: 200))
        XCTAssertEqual(cache.count, 0)
    }

    func testRecordedTapIsDetected() {
        var cache = TapAreaCache()
        cache.record(x: 100, y: 200)
        XCTAssertTrue(cache.wasAlreadyTapped(x: 100, y: 200))
        XCTAssertEqual(cache.count, 1)
    }

    func testNearbyTapIsDetectedWithinRadius() {
        var cache = TapAreaCache()
        cache.record(x: 100, y: 200)
        // Within 30pt radius
        XCTAssertTrue(cache.wasAlreadyTapped(x: 110, y: 210))
        XCTAssertTrue(cache.wasAlreadyTapped(x: 120, y: 200))
        XCTAssertTrue(cache.wasAlreadyTapped(x: 100, y: 220))
    }

    func testDistantTapIsNotDetected() {
        var cache = TapAreaCache()
        cache.record(x: 100, y: 200)
        // Beyond 30pt radius
        XCTAssertFalse(cache.wasAlreadyTapped(x: 200, y: 200))
        XCTAssertFalse(cache.wasAlreadyTapped(x: 100, y: 300))
        XCTAssertFalse(cache.wasAlreadyTapped(x: 150, y: 250))
    }

    func testMultipleRecordedTaps() {
        var cache = TapAreaCache()
        cache.record(x: 50, y: 100)
        cache.record(x: 200, y: 400)
        cache.record(x: 350, y: 600)

        XCTAssertEqual(cache.count, 3)
        XCTAssertTrue(cache.wasAlreadyTapped(x: 55, y: 105))
        XCTAssertTrue(cache.wasAlreadyTapped(x: 205, y: 395))
        XCTAssertTrue(cache.wasAlreadyTapped(x: 345, y: 600))
        XCTAssertFalse(cache.wasAlreadyTapped(x: 125, y: 250))
    }

    func testBoundaryAtExactRadius() {
        var cache = TapAreaCache()
        cache.record(x: 100, y: 100)
        // At exactly 30pt radius: sqrt(21^2 + 21^2) ≈ 29.7 → inside
        XCTAssertTrue(cache.wasAlreadyTapped(x: 121, y: 121))
        // At exactly 30pt radius: sqrt(22^2 + 22^2) ≈ 31.1 → outside
        XCTAssertFalse(cache.wasAlreadyTapped(x: 122, y: 122))
    }

    // MARK: - NavigationGraph Tap Cache Integration

    func testNavigationGraphTapCacheRecordAndCheck() {
        let graph = NavigationGraph()
        let elements = [TapPoint(text: "Item", tapX: 200, tapY: 300, confidence: 1.0)]
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let fp = graph.rootFingerprint

        XCTAssertFalse(graph.wasAlreadyTapped(fingerprint: fp, x: 200, y: 300))
        XCTAssertEqual(graph.tapCount(for: fp), 0)

        graph.recordTap(fingerprint: fp, x: 200, y: 300)
        XCTAssertTrue(graph.wasAlreadyTapped(fingerprint: fp, x: 200, y: 300))
        XCTAssertTrue(graph.wasAlreadyTapped(fingerprint: fp, x: 210, y: 305))
        XCTAssertFalse(graph.wasAlreadyTapped(fingerprint: fp, x: 400, y: 500))
        XCTAssertEqual(graph.tapCount(for: fp), 1)
    }

    func testNavigationGraphTapCacheIsolatedPerScreen() {
        let graph = NavigationGraph()
        let elements = [TapPoint(text: "ItemA", tapX: 100, tapY: 200, confidence: 1.0)]
        graph.start(
            rootElements: elements, icons: [], hints: [],
            screenshot: "img", screenType: .tabRoot
        )
        let rootFP = graph.rootFingerprint

        graph.recordTap(fingerprint: rootFP, x: 100, y: 200)

        // A different fingerprint should not share the cache
        XCTAssertFalse(graph.wasAlreadyTapped(fingerprint: "other-fp", x: 100, y: 200))
        XCTAssertEqual(graph.tapCount(for: "other-fp"), 0)
    }

    // MARK: - ExplorationReportFormatter Tests

    func testFormatCalibrationReport() {
        let summary = ExplorationReportFormatter.CalibrationSummary(
            scrollCount: 3,
            newElementCount: 12,
            totalElements: 45,
            usedCalibrationScroller: true
        )
        let text = ExplorationReportFormatter.formatCalibration(summary)
        XCTAssertTrue(text.contains("CalibrationScroller"))
        XCTAssertTrue(text.contains("Scrolls: 3"))
        XCTAssertTrue(text.contains("New elements discovered: 12"))
        XCTAssertTrue(text.contains("Total elements on root screen: 45"))
    }

    func testFormatExplorationReport() {
        let actions = [
            ExplorationReportFormatter.ActionEntry(
                label: "General", x: 200, y: 300,
                result: "new_screen", skippedByCache: false),
            ExplorationReportFormatter.ActionEntry(
                label: "Privacy", x: 200, y: 350,
                result: "cache_skip", skippedByCache: true),
        ]

        let screens = [
            ExplorationReportFormatter.ScreenSummary(
                depth: 0, fingerprint: "abc12345",
                componentCount: 5, actionCount: 2,
                cacheHits: 1, actions: actions),
        ]

        let stats = (nodeCount: 3, edgeCount: 5, actionCount: 10, elapsedSeconds: 45)

        let text = ExplorationReportFormatter.formatExplorationReport(
            appName: "Settings",
            calibration: nil,
            screens: screens,
            stats: stats,
            tapCacheTotal: 1
        )

        XCTAssertTrue(text.contains("Settings"), "Should contain app name")
        XCTAssertTrue(text.contains("Screens discovered: 3"))
        XCTAssertTrue(text.contains("Total actions: 10"))
        XCTAssertTrue(text.contains("Duration: 45s"))
        XCTAssertTrue(text.contains("Tap cache saves: 1"))
        XCTAssertTrue(text.contains("TAP "), "Should have TAP entries")
        XCTAssertTrue(text.contains("SKIP"), "Should have SKIP entries")
        XCTAssertTrue(text.contains("General"))
        XCTAssertTrue(text.contains("Privacy"))
    }

    func testFormatReportWithCalibration() {
        let cal = ExplorationReportFormatter.CalibrationSummary(
            scrollCount: 2, newElementCount: 8,
            totalElements: 30, usedCalibrationScroller: false
        )
        let stats = (nodeCount: 1, edgeCount: 0, actionCount: 0, elapsedSeconds: 5)
        let text = ExplorationReportFormatter.formatExplorationReport(
            appName: "Health",
            calibration: cal,
            screens: [],
            stats: stats,
            tapCacheTotal: 0
        )
        XCTAssertTrue(text.contains("Calibration Report"))
        XCTAssertTrue(text.contains("Simple scroll"))
    }
}
