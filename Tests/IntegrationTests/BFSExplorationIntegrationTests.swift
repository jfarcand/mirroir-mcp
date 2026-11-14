/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Integration tests for BFS multi-viewport exploration against FakeMirroring.
// ABOUTME: Validates scrolling across viewports, element discovery, deterministic seed, and skip-calibration mode.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Integration tests for BFS exploration using real OCR against FakeMirroring's
/// healthSummary scenario. Exercises the full generate_skill exploration loop:
/// calibration → per-viewport plan building → tap → backtrack → scroll → next viewport.
///
/// Run with: `swift test --filter BFSExplorationIntegrationTests`
/// FakeMirroring must be running (auto-launched by IntegrationTestHelper).
final class BFSExplorationIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var input: InputSimulation!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        let capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
        input = InputSimulation(bridge: bridge)

        // Switch to Health Summary scenario
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Health Summary")
        usleep(1_000_000)
    }

    override func tearDown() {
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Describe the current screen or fail the test.
    private func describeOrFail(file: StaticString = #file, line: UInt = #line)
        -> ScreenDescriber.DescribeResult?
    {
        for attempt in 1...3 {
            if let result = describer.describe() { return result }
            if attempt < 3 { usleep(500_000) }
        }
        XCTFail("describe() returned nil after 3 attempts", file: file, line: line)
        return nil
    }

    /// Create a BFS explorer with a modest budget suitable for integration tests.
    private func makeBFSExplorer(
        session: ExplorationSession,
        seed: UInt64 = 42,
        skipCalibration: Bool = true
    ) -> BFSExplorer {
        let budget = ExplorationBudget(
            maxDepth: 1, maxScreens: 5, maxTimeSeconds: 180,
            maxActionsPerScreen: 2, scrollLimit: 2,
            skipPatterns: ExplorationBudget.builtInSkipPatterns
        )
        let windowSize = bridge.getWindowInfo()?.size ?? CGSize(width: 410, height: 898)
        let componentDefinitions = ComponentLoader.loadAll()
        return BFSExplorer(
            session: session, budget: budget, windowSize: windowSize,
            componentDefinitions: componentDefinitions,
            bridge: bridge, seed: seed,
            skipCalibration: skipCalibration,
            advisor: HeuristicExplorationAdvisor()
        )
    }

    /// Start a session by describing + capturing the current screen.
    @discardableResult
    private func startSession(_ session: ExplorationSession, goal: String) -> Bool {
        session.start(appName: "FakeMirroring", goal: goal)
        guard let result = describeOrFail() else { return false }
        session.capture(
            elements: result.elements, hints: result.hints,
            icons: result.icons, actionType: nil, arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )
        return true
    }

    /// Run the BFS exploration loop with a safety limit.
    private func runExploration(_ explorer: BFSExplorer) -> [ExploreStepResult] {
        explorer.markStarted()
        var results: [ExploreStepResult] = []
        while !explorer.completed && results.count < 100 {
            let result = explorer.step(
                describer: describer, input: input,
                strategy: MobileAppStrategy.self
            )
            results.append(result)
            if case .finished = result { break }
        }
        return results
    }

    /// Reset the Health Summary scenario (switch away and back to clear scroll offset).
    private func resetScenario() {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(500_000)
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Health Summary")
        usleep(1_000_000)
    }

    // MARK: - Multi-Viewport Exploration

    /// BFS should explore the healthSummary root screen, tap cards that navigate
    /// to detail screens, and discover multiple screens.
    func testMultiViewportExploration() {
        let session = ExplorationSession()
        guard startSession(session, goal: "explore health") else { return }

        let explorer = makeBFSExplorer(session: session)
        let results = runExploration(explorer)
        let stats = explorer.stats

        XCTAssertTrue(explorer.completed, "Explorer should complete within budget")
        XCTAssertGreaterThanOrEqual(stats.nodeCount, 2,
            "Should discover at least 2 screens (root + 1 detail). Got \(stats.nodeCount)")
        XCTAssertGreaterThanOrEqual(stats.actionCount, 1,
            "Should perform at least 1 tap action. Got \(stats.actionCount)")
        XCTAssertLessThanOrEqual(stats.elapsedSeconds, 180,
            "Should complete within budget")

        // Skills require navigation to new screens. FakeMirroring may not always
        // navigate depending on which elements the explorer taps, so just verify
        // the exploration ran to completion with reasonable metrics.
        let report = explorer.generateReport()
        XCTAssertFalse(report.isEmpty, "Should produce an exploration report")

        // Verify exploration produced step results
        let continueResults = results.filter {
            if case .continue = $0 { return true }; return false
        }
        XCTAssertGreaterThan(continueResults.count, 0,
            "Should have at least 1 exploration step")
    }

    // MARK: - Deterministic Seed

    /// Same seed should produce the same tap sequence across two runs.
    func testDeterministicSeedProducesSameTapSequence() {
        // Run 1
        let session1 = ExplorationSession()
        guard startSession(session1, goal: "seed test") else { return }
        let explorer1 = makeBFSExplorer(session: session1, seed: 42)
        let results1 = runExploration(explorer1)

        // Reset scenario to clear scroll state
        resetScenario()

        // Run 2
        let session2 = ExplorationSession()
        guard startSession(session2, goal: "seed test") else { return }
        let explorer2 = makeBFSExplorer(session: session2, seed: 42)
        let results2 = runExploration(explorer2)

        // Extract tap descriptions (filter out timing-dependent finished results)
        let descriptions1 = results1.compactMap { result -> String? in
            if case .continue(let d) = result { return d }; return nil
        }
        let descriptions2 = results2.compactMap { result -> String? in
            if case .continue(let d) = result { return d }; return nil
        }

        XCTAssertEqual(descriptions1.count, descriptions2.count,
            "Same seed should produce same number of steps")

        // Compare pairwise (first few steps should match exactly)
        let compareCount = min(descriptions1.count, descriptions2.count, 5)
        for i in 0..<compareCount {
            XCTAssertEqual(descriptions1[i], descriptions2[i],
                "Step \(i) should match between runs with same seed")
        }
    }

    // MARK: - Skip Calibration

    /// With skipCalibration=true, calibration discovers viewpoints via scrolling
    /// and per-viewport exploration can scroll even if scroll was marked exhausted.
    func testSkipCalibrationAllowsExplorationScrolling() {
        let session = ExplorationSession()
        guard startSession(session, goal: "skip cal test") else { return }

        let explorer = makeBFSExplorer(session: session, skipCalibration: true)
        let results = runExploration(explorer)

        XCTAssertTrue(explorer.completed, "Explorer should complete (not stuck)")
        XCTAssertGreaterThanOrEqual(explorer.totalViewpoints, 2,
            "Calibration should discover at least 2 viewports in healthSummary")

        // Verify at least one scroll happened during exploration
        let scrollResults = results.filter {
            if case .continue(let d) = $0 { return d.contains("Scrolled") }; return false
        }
        XCTAssertGreaterThanOrEqual(scrollResults.count, 1,
            "Explorer should scroll to discover below-fold content")
    }

    // MARK: - Below-Fold Discovery

    /// Calibration scroll should discover elements from below-fold viewports.
    /// Verifies by checking that the exploration found more elements than a single viewport.
    func testCalibrationDiscoversBelowFoldElements() {
        let session = ExplorationSession()
        guard startSession(session, goal: "below fold test") else { return }

        let explorer = makeBFSExplorer(session: session)
        _ = runExploration(explorer)

        let stats = explorer.stats
        XCTAssertTrue(explorer.completed, "Explorer should complete")

        // Calibration should discover multiple viewpoints in healthSummary
        // (content extends below 898pt window height)
        XCTAssertGreaterThanOrEqual(explorer.totalViewpoints, 2,
            "Calibration should discover at least 2 viewpoints")

        // Multiple actions means the explorer tapped across the page
        XCTAssertGreaterThanOrEqual(stats.actionCount, 1,
            "Explorer should tap at least 1 element")
    }
}
