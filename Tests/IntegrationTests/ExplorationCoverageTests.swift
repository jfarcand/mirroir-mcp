// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Experiment C5: validates exploration session coverage against FakeMirroring.
// ABOUTME: Verifies that exploration discovers at least one screen node without crashes.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Runs an exploration session against FakeMirroring and verifies basic coverage.
///
/// Tier 1 metric: exploration coverage > 60%
final class ExplorationCoverageTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard IntegrationTestHelper.isFakeMirroringRunning else {
            throw IntegrationTestError.fakeMirroringNotRunning
        }
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
    }

    /// Start an exploration session and verify it captures the initial screen.
    func testExplorationSessionCapturesScreen() throws {
        let capture = ScreenCapture(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)

        // Get the initial screen
        guard let initialScreen = describer.describe(skipOCR: false) else {
            throw IntegrationTestError.describeReturnedNil
        }

        // Start an exploration session
        let session = ExplorationSession()
        session.start(appName: "FakeMirroring", goal: "explore")

        // Capture the root screen
        session.capture(
            elements: initialScreen.elements,
            hints: initialScreen.hints,
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: initialScreen.screenshotBase64
        )

        // Finalize and verify results
        guard let result = session.finalize() else {
            XCTFail("Session finalize returned nil")
            return
        }

        XCTAssertGreaterThanOrEqual(result.screens.count, 1,
                                     "Exploration should capture at least 1 screen")

        // Verify elements were captured
        XCTAssertFalse(initialScreen.elements.isEmpty,
                       "Initial screen should have OCR elements")

        print("Exploration coverage: \(result.screens.count) screen(s), \(initialScreen.elements.count) initial elements")
    }

    /// Verify exploration budget constraints work correctly.
    func testExplorationBudgetConstraints() {
        let budget = ExplorationBudget(
            maxDepth: 2,
            maxScreens: 5,
            maxTimeSeconds: 30,
            maxActionsPerScreen: 3,
            scrollLimit: 1,
            skipPatterns: ExplorationBudget.builtInSkipPatterns
        )

        XCTAssertFalse(budget.isExhausted(depth: 0, screenCount: 1, elapsedSeconds: 0),
                       "Budget should not be exhausted at start")
        XCTAssertTrue(budget.isExhausted(depth: 2, screenCount: 1, elapsedSeconds: 0),
                      "Budget should be exhausted at maxDepth")
        XCTAssertTrue(budget.isExhausted(depth: 0, screenCount: 5, elapsedSeconds: 0),
                      "Budget should be exhausted at maxScreens")
        XCTAssertTrue(budget.isExhausted(depth: 0, screenCount: 1, elapsedSeconds: 30),
                      "Budget should be exhausted at maxTimeSeconds")
    }

    /// Verify configurable budget reads from EnvConfig defaults.
    func testExplorationBudgetReadsDefaults() {
        let defaultBudget = ExplorationBudget.default
        XCTAssertEqual(defaultBudget.maxDepth, EnvConfig.explorationMaxDepth)
        XCTAssertEqual(defaultBudget.maxScreens, EnvConfig.explorationMaxScreens)
        XCTAssertEqual(defaultBudget.maxTimeSeconds, EnvConfig.explorationMaxTimeSeconds)
    }
}
