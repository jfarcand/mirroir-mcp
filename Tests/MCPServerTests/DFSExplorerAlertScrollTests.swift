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
// ABOUTME: DFSExplorer tests for alert recovery and scroll handling behavior.
// ABOUTME: Covers alert dismissal, scroll-before-backtrack, scroll limits, and scroll exhaustion.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DFSExplorerAlertScrollTests: XCTestCase {

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        makeExplorerElements(texts, startY: startY)
    }

    // MARK: - Alert Recovery

    func testExplorerDismissesAlertBeforeExploring() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General", "About"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // First OCR returns an alert, second returns clean screen after dismiss
        let alertElements: [TapPoint] = [
            TapPoint(text: "\"App\" would like to use your location", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "Allow", tapX: 205, tapY: 420, confidence: 0.95),
            TapPoint(text: "Don't Allow", tapX: 205, tapY: 480, confidence: 0.95),
        ]
        let afterTapElements = makeElements(["Version Info", "Build Number"])

        let describer = MockExplorerDescriber(screens: [
            // step() calls dismissAlertIfPresent: first OCR → alert
            ScreenDescriber.DescribeResult(elements: alertElements, screenshotBase64: "alert_img"),
            // After tapping dismiss → clean root screen
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            // performTap: after-tap OCR
            ScreenDescriber.DescribeResult(elements: afterTapElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        // Should have tapped "Don't Allow" to dismiss alert, then continued exploring
        if case .continue = result {
            // Expected: explored after dismissing alert
        } else {
            XCTFail("Expected .continue after dismissing alert, got \(result)")
        }

        // First tap should be the dismiss (Don't Allow), second is the exploration tap
        XCTAssertGreaterThanOrEqual(input.taps.count, 2,
            "Should tap dismiss target + exploration target")
    }

    func testExplorerAlertDoesNotCreateGraphEdge() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget.default
        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        let alertElements: [TapPoint] = [
            TapPoint(text: "Rate this app", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "Not Now", tapX: 205, tapY: 420, confidence: 0.95),
            TapPoint(text: "OK", tapX: 205, tapY: 480, confidence: 0.95),
        ]
        let afterTapElements = makeElements(["Version Info", "Build Number"])

        let describer = MockExplorerDescriber(screens: [
            // Alert detected on initial OCR
            ScreenDescriber.DescribeResult(elements: alertElements, screenshotBase64: "alert_img"),
            // After dismiss → root
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            // After exploration tap → new screen
            ScreenDescriber.DescribeResult(elements: afterTapElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        _ = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        let graph = session.currentGraph
        // The graph should have 2 nodes (root + tapped destination), not 3
        // The alert should not have been recorded as a screen
        XCTAssertLessThanOrEqual(graph.nodeCount, 2,
            "Alert should not create a graph node")
    }

    // MARK: - Scroll Handling

    func testExplorerScrollsBeforeBacktracking() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings"])
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

        // Mark root element visited so explorer would normally backtrack
        let graph = session.currentGraph
        graph.markElementVisited(fingerprint: graph.currentFingerprint, elementText: "Settings")

        // After scroll, new elements appear
        let scrolledElements = makeElements(["General", "Privacy", "About"])
        let describer = MockExplorerDescriber(screens: [
            // step() OCR: all visited on root
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            // After scroll: new elements visible
            ScreenDescriber.DescribeResult(elements: scrolledElements, screenshotBase64: "img0_scrolled"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        if case .continue(let desc) = result {
            XCTAssertTrue(desc.contains("Scrolled"), "Should describe scroll action. Got: \(desc)")
        } else {
            XCTFail("Expected .continue after scroll, got \(result)")
        }
    }

    func testExplorerRespectsScrollLimit() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        // Budget allows 0 scrolls
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Mark all visited
        let graph = session.currentGraph
        graph.markElementVisited(fingerprint: graph.currentFingerprint, elementText: "Settings")

        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self
        )

        // With scrollLimit=0 and at root, should finish (not scroll)
        if case .finished = result {
            // Expected: no scrolling, immediate finish
        } else {
            XCTFail("Expected .finished with scrollLimit=0, got \(result)")
        }
    }

    func testExplorerScrollExhaustionFallsToBacktrack() {
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")

        let rootElements = makeElements(["Settings", "General"])
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )

        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 1,
            skipPatterns: ExplorationBudget.default.skipPatterns
        )

        let explorer = DFSExplorer(session: session, budget: budget)
        explorer.markStarted()

        // Navigate to a detail screen
        let detailElements = makeElements(["Version", "Build"])
        let describer1 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0"),
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])
        let input = MockExplorerInput()

        // Step 1: Tap to get to detail screen
        _ = explorer.step(describer: describer1, input: input, strategy: MobileAppStrategy.self)

        // Mark all detail elements visited
        let graph = session.currentGraph
        let fp = graph.currentFingerprint
        graph.markElementVisited(fingerprint: fp, elementText: "Version")
        graph.markElementVisited(fingerprint: fp, elementText: "Build")

        // Scroll returns same elements (no novel ones)
        let describer2 = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
            // After scroll: same elements
            ScreenDescriber.DescribeResult(elements: detailElements, screenshotBase64: "img1"),
        ])

        let result = explorer.step(
            describer: describer2, input: input, strategy: MobileAppStrategy.self
        )

        // Should backtrack after scroll found nothing new
        if case .backtracked = result {
            // Expected
        } else if case .finished = result {
            // Also acceptable
        } else {
            XCTFail("Expected .backtracked after scroll exhaustion, got \(result)")
        }
    }

    // MARK: - Self-re-arming obstacle (camera-dialog loop)

    func testDismissEscapesSelfReArmingObstacleViaScreenExit() {
        // Instagram's Story camera pops "camera not available" again after OK,
        // so dismissing it makes no progress. The handler must fall through to
        // the screen-exit obstacle (tap "X") instead of looping forever on OK.
        // 10 elements so AlertDetector treats it as a full screen, not an alert.
        let cameraScreen: [TapPoint] = [
            TapPoint(text: "iPhone camera is not available", tapX: 193, tapY: 462, confidence: 0.95),
            TapPoint(text: "from Mac.", tapX: 129, tapY: 478, confidence: 0.9),
            TapPoint(text: "OK", tapX: 205, tapY: 515, confidence: 0.95),
            TapPoint(text: "PUBLICATION STORY REEL EN DIR", tapX: 204, tapY: 837, confidence: 0.9),
            TapPoint(text: "X", tapX: 42, tapY: 131, confidence: 0.9),
            TapPoint(text: "alpha", tapX: 100, tapY: 200, confidence: 0.9),
            TapPoint(text: "beta", tapX: 150, tapY: 220, confidence: 0.9),
            TapPoint(text: "gamma", tapX: 200, tapY: 240, confidence: 0.9),
            TapPoint(text: "delta", tapX: 250, tapY: 260, confidence: 0.9),
            TapPoint(text: "epsilon", tapX: 300, tapY: 280, confidence: 0.9),
        ]
        let cleanScreen = makeElements(["Accueil", "Recherche", "Reels", "Profil"])
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: cameraScreen, screenshotBase64: "cam"),
            ScreenDescriber.DescribeResult(elements: cameraScreen, screenshotBase64: "cam2"),
            ScreenDescriber.DescribeResult(elements: cleanScreen, screenshotBase64: "clean"),
        ])
        let input = MockExplorerInput()
        let obstacles = [
            ObstacleRule(trigger: "iPhone camera is not available", action: "OK"),
            ObstacleRule(trigger: "PUBLICATION STORY", action: "X"),
        ]

        let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input, obstacles: obstacles)

        XCTAssertNotNil(result)
        XCTAssertFalse(
            result?.elements.contains(where: { $0.text.contains("camera") }) ?? true,
            "Should escape the camera screen, not stay stuck on it")
        XCTAssertTrue(
            input.taps.contains(where: { abs($0.x - 42) < 1 && abs($0.y - 131) < 1 }),
            "Must tap the X to exit the self-re-arming screen instead of OK forever")
    }
}
