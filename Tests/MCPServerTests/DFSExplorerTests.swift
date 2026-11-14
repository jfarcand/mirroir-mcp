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
// ABOUTME: Core unit tests for DFSExplorer: budget exhaustion, tap/navigate, backtrack, state, OCR failure,
// ABOUTME: root-only exploration, skip patterns, backtrack fingerprint sync, and punctuation filtering.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DFSExplorerTests: XCTestCase {

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        makeExplorerElements(texts, startY: startY)
    }

    // MARK: - Budget Exhaustion

    func testExplorerFinishesWhenBudgetExhausted() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General", "About", "Privacy"])
        let rootScreen = ScreenDescriber.DescribeResult(
            elements: rootElements, screenshotBase64: "img0"
        )

        // Capture root screen in session
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Budget allows only 1 screen — explorer should finish immediately
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 1, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 3,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [rootScreen])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        if case .finished = result {
            // Expected: budget exhausted (maxScreens=1, already have 1)
        } else {
            XCTFail("Expected .finished when budget exhausted, got \(result)")
        }
    }

    func testExplorerFinishesWhenTimeExhausted() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Budget with 0 seconds — immediately exhausted
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 0,
            maxActionsPerScreen: 5, scrollLimit: 3,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        if case .finished = result {
            // Expected
        } else {
            XCTFail("Expected .finished when time exhausted, got \(result)")
        }
    }

    // MARK: - Tap and Navigate

    func testExplorerTapsUnvisitedElement() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General", "About"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 3,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let afterTapElements = makeElements(["Version Info", "Build Number"])
        let describer = MockExplorerDescriber(screens: [
            // First: OCR of current screen (root)
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            // Second: OCR after tap
            ScreenDescriber.DescribeResult(elements: afterTapElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        if case .continue(let desc) = result {
            XCTAssertTrue(desc.contains("new screen") || desc.contains("Tapped"),
                "Should describe the tap action. Got: \(desc)")
        } else {
            XCTFail("Expected .continue after tapping, got \(result)")
        }

        // Verify a tap was performed
        XCTAssertEqual(input.taps.count, 1, "Should have tapped one element")
    }

    // MARK: - Backtrack

    func testExplorerBacktracksWhenNoUnvisitedElements() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root with just one navigable element
        let rootElements = makeElements(["Settings"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Disable scrolling — this test is about backtrack behavior
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Step 1: Tap "Settings" → navigate to detail
        let detailElements = makeElements(["Version", "Build"])
        let describer1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        let step1 = explorer.step(
            describer: describer1, input: input, strategy: MobileAppStrategy.self
        )

        if case .continue = step1 {
            // Expected: tapped "Settings", reached detail screen
        } else {
            XCTFail("Expected .continue for step 1, got \(step1)")
        }

        // Step 2: Detail screen has elements but after we tap them all or
        // the graph sees all visited, it should backtrack.
        // Mark all detail elements as visited so backtrack triggers.
        let graph = session.currentGraph
        let currentFP = graph.currentFingerprint
        graph.markElementVisited(fingerprint: currentFP, elementText: "Version")
        graph.markElementVisited(fingerprint: currentFP, elementText: "Build")

        let describer2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])

        let step2 = explorer.step(
            describer: describer2, input: input, strategy: MobileAppStrategy.self
        )

        // Should backtrack since all elements on detail are visited
        if case .backtracked = step2 {
            // Expected
        } else if case .finished = step2 {
            // Also acceptable if explorer decides exploration is done
        } else {
            XCTFail("Expected .backtracked or .finished, got \(step2)")
        }
    }

    // MARK: - Completed State

    func testExplorerCompletedInitiallyFalse() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "")

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)

        XCTAssertFalse(explorer.completed, "Explorer should not be completed initially")
    }

    func testExplorerStatsTrackProgress() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let stats = explorer.stats
        XCTAssertEqual(stats.nodeCount, 1, "Should have 1 node from initial capture")
        XCTAssertEqual(stats.actionCount, 0, "No actions taken yet")
        XCTAssertGreaterThanOrEqual(stats.elapsedSeconds, 0)
    }

    // MARK: - OCR Failure

    func testExplorerPausesOnOCRFailure() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Describer that returns nil (simulating OCR failure)
        let describer = MockExplorerDescriber(screens: [])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        if case .paused(let reason) = result {
            XCTAssertTrue(reason.contains("Failed"),
                "Pause reason should mention failure. Got: \(reason)")
        } else {
            XCTFail("Expected .paused on OCR failure, got \(result)")
        }
    }

    // MARK: - Root-Only Exploration

    func testExplorerFinishesAtRootWhenAllVisited() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root screen with short elements that will be filtered by MobileAppStrategy
        // (landmarkMinLength = 3, so "Go" would be too short)
        let rootElements = makeElements(["AB"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Mark the only element as visited
        let graph = session.currentGraph
        graph.markElementVisited(fingerprint: graph.currentFingerprint, elementText: "AB")

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        // At root with no unvisited elements and stack depth 1 → finished
        if case .finished = result {
            // Expected
        } else {
            XCTFail("Expected .finished at root with all elements visited, got \(result)")
        }
    }

    // MARK: - Skip Patterns

    func testExplorerSkipsDangerousElements() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Only navigable element is "Sign Out" which should be skipped
        let rootElements = makeElements(["Sign Out"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        // "Sign Out" should be skipped, no elements to tap → backtrack at root → finished
        if case .finished = result {
            // Expected
        } else {
            XCTFail("Expected .finished when only element is skippable, got \(result)")
        }

        XCTAssertEqual(input.taps.count, 0, "Should not tap dangerous elements")
    }

    // MARK: - Backtrack Fingerprint Sync

    func testExplorerExploresParentAfterBacktracking() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        // Root has two navigable elements
        let rootElements = makeElements(["General", "Privacy"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Step 1: Tap "General" → navigate to detail
        let detailElements = makeElements(["About", "Version"])
        let desc1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()
        let step1 = explorer.step(describer: desc1, input: input, strategy: MobileAppStrategy.self)
        guard case .continue = step1 else {
            XCTFail("Expected .continue for step 1, got \(step1)")
            return
        }

        // Mark all detail elements visited to trigger backtrack
        let graph = session.currentGraph
        let detailFP = graph.currentFingerprint
        graph.markElementVisited(fingerprint: detailFP, elementText: "About")
        graph.markElementVisited(fingerprint: detailFP, elementText: "Version")

        // Step 2: All visited on detail → backtrack to root
        let desc2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
            // Backtrack verification: back at root
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let step2 = explorer.step(describer: desc2, input: input, strategy: MobileAppStrategy.self)
        guard case .backtracked = step2 else {
            XCTFail("Expected .backtracked for step 2, got \(step2)")
            return
        }

        // Step 3: After backtracking to root, explorer should tap "Privacy" (still unvisited)
        let privacyDetail = makeElements(["Location", "Tracking"])
        let desc3 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: privacyDetail, screenshotBase64: "img2"),
        ])
        let step3 = explorer.step(describer: desc3, input: input, strategy: MobileAppStrategy.self)

        // Should continue exploring, NOT finish prematurely
        if case .continue(let desc) = step3 {
            XCTAssertTrue(desc.contains("Privacy") || desc.contains("new screen"),
                "Should tap 'Privacy' on root after backtrack. Got: \(desc)")
        } else {
            XCTFail("Expected .continue after backtrack to root with unvisited elements, got \(step3)")
        }
    }

    // MARK: - Punctuation-Only Filter

    func testPunctuationOnlyElementsFiltered() {
        XCTAssertTrue(LandmarkPicker.isPunctuationOnly("..."))
        XCTAssertTrue(LandmarkPicker.isPunctuationOnly("+++"))
        XCTAssertTrue(LandmarkPicker.isPunctuationOnly("•••"))
        XCTAssertTrue(LandmarkPicker.isPunctuationOnly("→"))
        XCTAssertTrue(LandmarkPicker.isPunctuationOnly("---"))
        XCTAssertFalse(LandmarkPicker.isPunctuationOnly("OK"))
        XCTAssertFalse(LandmarkPicker.isPunctuationOnly("More..."))
        XCTAssertFalse(LandmarkPicker.isPunctuationOnly("General"))
        XCTAssertFalse(LandmarkPicker.isPunctuationOnly("1+1"))
    }

    // MARK: - Backtrack Verification (Bug 2 regression)

    func testBacktrackVerifiesScreenChange() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Step 1: Tap → navigate to detail
        let detailElements = makeElements(["About", "Version"])
        let desc1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()
        let step1 = explorer.step(describer: desc1, input: input, strategy: MobileAppStrategy.self)
        guard case .continue = step1 else {
            XCTFail("Expected .continue for step 1, got \(step1)")
            return
        }

        // Mark detail elements visited to trigger backtrack
        let graph = session.currentGraph
        let detailFP = graph.currentFingerprint
        graph.markElementVisited(fingerprint: detailFP, elementText: "About")
        graph.markElementVisited(fingerprint: detailFP, elementText: "Version")

        // Step 2: Backtrack, but first OCR returns detail screen (back tap failed).
        // Verification should retry and succeed on second attempt.
        let desc2 = MockExplorerDescriber(screens: [
            // OCR of current screen (detail)
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
            // First verification OCR: still on detail (back tap failed)
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
            // Retry verification OCR: now on root (second back tap worked)
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let step2 = explorer.step(describer: desc2, input: input, strategy: MobileAppStrategy.self)

        guard case .backtracked(_, let toFP) = step2 else {
            XCTFail("Expected .backtracked for step 2, got \(step2)")
            return
        }

        // Verify we resolved to the correct parent
        XCTAssertEqual(toFP, graph.rootFingerprint,
            "Backtrack verification should resolve to root after retry")

        // Verify the back button was tapped twice (initial + retry)
        let backTaps = input.taps.filter { $0.x < 60 && $0.y < 140 }
        XCTAssertEqual(backTaps.count, 2,
            "Should tap back button twice: once for backtrack + once for retry")
    }
}
