// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Integration tests for DFSExplorer against the FakeMirroring app.
// ABOUTME: Verifies autonomous DFS exploration produces valid skill bundles with real OCR data.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

/// Integration tests for DFSExplorer using real OCR against FakeMirroring.
///
/// Run with: `swift test --filter IntegrationTests`
///
/// FakeMirroring must be running:
///   `swift build -c release --product FakeMirroring && ./scripts/package-fake-app.sh`
///   `open .build/release/FakeMirroring.app`
final class DFSExplorerIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()

        try IntegrationTestHelper.ensureFakeMirroringRunning()

        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)

        // Ensure window is capturable — prior test classes may have exhausted screencapture
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            XCTFail("FakeMirroring window not capturable after retries")
            return
        }

        describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
    }

    // MARK: - Graph Population

    func testGraphPopulatedFromRealOCR() {
        guard let result = describer.describe(skipOCR: false) else {
            XCTFail("describe() returned nil — cannot test DFS explorer")
            return
        }

        let session = ExplorationSession()
        session.start(appName: "FakeMirroring", goal: "test graph")

        session.capture(
            elements: result.elements, hints: result.hints,
            icons: result.icons, actionType: nil, arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )

        let graph = session.currentGraph
        XCTAssertTrue(graph.started, "Graph should be started after capture")
        XCTAssertEqual(graph.nodeCount, 1, "Should have 1 node from initial capture")

        // Verify structural fingerprint produces a hash
        let fp = graph.currentFingerprint
        XCTAssertFalse(fp.isEmpty, "Fingerprint should be non-empty")
        XCTAssertGreaterThan(fp.count, 10, "Fingerprint should be a hex hash string")
    }

    func testExplorerInitializesWithRealOCR() {
        guard let result = describer.describe(skipOCR: false) else {
            XCTFail("describe() returned nil")
            return
        }

        let session = ExplorationSession()
        session.start(appName: "FakeMirroring", goal: "test init")

        session.capture(
            elements: result.elements, hints: result.hints,
            icons: result.icons, actionType: nil, arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )

        let budget = ExplorationBudget(
            maxDepth: 2, maxScreens: 5, maxTimeSeconds: 10,
            maxActionsPerScreen: 3, scrollLimit: 2,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        XCTAssertFalse(explorer.completed, "Explorer should not be completed initially")

        let stats = explorer.stats
        XCTAssertEqual(stats.nodeCount, 1)
        XCTAssertEqual(stats.actionCount, 0)
    }

    // MARK: - Strategy-Based Guidance with Real OCR

    func testStrategyGuidanceFromRealElements() {
        guard let result = describer.describe(skipOCR: false) else {
            XCTFail("describe() returned nil")
            return
        }

        let session = ExplorationSession()
        session.start(appName: "FakeMirroring", goal: "check software version")

        session.capture(
            elements: result.elements, hints: result.hints,
            icons: result.icons, actionType: nil, arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )

        // Use strategy-based guidance
        let graph = session.currentGraph
        let guidance = ExplorationGuide.analyzeWithStrategy(
            strategy: MobileAppStrategy.self,
            graph: graph,
            elements: result.elements,
            icons: result.icons,
            hints: result.hints,
            budget: .default,
            goal: "check software version"
        )

        // FakeMirroring shows Settings-like screen with navigable elements
        XCTAssertFalse(guidance.suggestions.isEmpty,
            "Strategy guidance should produce suggestions from real OCR data")
    }

    // MARK: - Structural Fingerprint Stability

    func testFingerprintStableAcrossOCRPasses() {
        guard let result1 = describer.describe(skipOCR: false) else {
            XCTFail("First describe() returned nil")
            return
        }

        guard let result2 = describer.describe(skipOCR: false) else {
            XCTFail("Second describe() returned nil")
            return
        }

        // Two OCR passes of the static FakeMirroring screen should produce
        // structurally equivalent fingerprints
        XCTAssertTrue(
            StructuralFingerprint.areEquivalent(result1.elements, result2.elements),
            "Two OCR passes of FakeMirroring should be structurally equivalent"
        )

        // The exact hash may differ slightly due to OCR noise, but structural
        // similarity should be very high
        let set1 = StructuralFingerprint.extractStructural(from: result1.elements)
        let set2 = StructuralFingerprint.extractStructural(from: result2.elements)
        let score = StructuralFingerprint.similarity(set1, set2)
        XCTAssertGreaterThanOrEqual(score, 0.9,
            "Structural similarity across OCR passes should be >= 0.9. Got \(score)")
    }
}
