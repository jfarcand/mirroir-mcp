// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for self-re-arming obstacle (trap) detection and BFS .trapped recovery.
// ABOUTME: Covers ExplorerUtilities.persistentObstacle and BFSExplorer returning .trapped + reset to root.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ExplorerTrapRecoveryTests: XCTestCase {

    private func point(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    private let cameraObstacles = [
        ObstacleRule(trigger: "iPhone camera is not available", action: "OK"),
        ObstacleRule(trigger: "PUBLICATION STORY", action: "X"),
    ]

    // MARK: - persistentObstacle

    func testPersistentObstacleDetectsReArmingTrap() {
        // Both trigger and action element present → the obstacle was tried and
        // re-armed (a trap).
        let elements = [
            point("iPhone camera is not available", 193, 462),
            point("from Mac.", 129, 478),
            point("OK", 205, 515),
            point("PUBLICATION STORY", 148, 837),
        ]
        XCTAssertEqual(
            ExplorerUtilities.persistentObstacle(elements: elements, obstacles: cameraObstacles),
            "iPhone camera is not available")
    }

    func testPersistentObstacleIgnoresTriggerTextWithoutAction() {
        // Trigger text appears but the dismiss action ("OK") is absent — incidental
        // content, not a dismissable dialog. Must NOT be flagged as a trap.
        let elements = [
            point("iPhone camera is not available on this device", 193, 462),
            point("Learn more", 205, 515),
        ]
        XCTAssertNil(
            ExplorerUtilities.persistentObstacle(elements: elements, obstacles: cameraObstacles))
    }

    func testPersistentObstacleNilOnNormalScreen() {
        let elements = [point("Accueil", 41, 840), point("Profil", 369, 840)]
        XCTAssertNil(
            ExplorerUtilities.persistentObstacle(elements: elements, obstacles: cameraObstacles))
    }

    func testPersistentObstacleMatchesSecondObstacle() {
        // The camera dialog cleared but the Story-camera capture screen remains:
        // "PUBLICATION STORY" trigger + "X" action both present.
        let elements = [
            point("X", 42, 131),
            point("REEL EN DIR", 292, 837),
            point("PUBLICATION STORY", 148, 837),
        ]
        XCTAssertEqual(
            ExplorerUtilities.persistentObstacle(elements: elements, obstacles: cameraObstacles),
            "PUBLICATION STORY")
    }

    // MARK: - BFS .trapped recovery

    private func makeInstagramDescription() -> AppDescription {
        AppDescription(
            appName: "Instagram", schemaVersion: 1, locale: "fr_CA", archetype: nil, playable: nil,
            resetBeforeExplore: false, obstacleMode: .auto, context: "test",
            obstacles: cameraObstacles, skipElements: [], credentials: [:], hints: [],
            tabs: [], tabLayout: nil, deepTabs: [], simulator: nil)
    }

    func testBFSReturnsTrappedAndResetsToRootOnReArmingCamera() {
        let session = ExplorationSession()
        session.start(appName: "Instagram", goal: "test")
        session.setAppDescription(makeInstagramDescription())

        // Story-camera screen: trigger + action present, and >10 elements so the
        // AlertDetector treats it as a full screen and the obstacle path runs.
        let camera: [TapPoint] = [
            point("iPhone camera is not available", 193, 462),
            point("from Mac.", 129, 478),
            point("OK", 205, 515),
            point("PUBLICATION STORY", 148, 837),
            point("REEL EN DIR", 292, 837),
            point("X", 42, 131),
            point("alpha", 100, 200),
            point("beta", 150, 220),
            point("gamma", 200, 240),
            point("delta", 250, 260),
            point("epsilon", 300, 280),
            point("zeta", 120, 300),
        ]
        session.capture(
            elements: camera, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "cam")

        let explorer = BFSExplorer(session: session, budget: .default)
        explorer.markStarted()

        // The describer always returns the camera (it re-pops the dialog every
        // describe), so dismissAlertIfPresent can never clear it.
        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: camera, screenshotBase64: "cam"),
        ])
        let input = MockExplorerInput()

        let result = explorer.step(
            describer: describer, input: input, strategy: MobileAppStrategy.self)

        guard case .trapped(let reason) = result else {
            return XCTFail("Expected .trapped on a self-re-arming camera screen, got \(result)")
        }
        XCTAssertTrue(reason.lowercased().contains("camera") || reason.contains("stuck"),
            "Trap reason should name the stuck obstacle. Got: \(reason)")

        // The explorer must have reset its own position to root before returning,
        // so the loop's force-quit + relaunch resumes cleanly from the feed.
        let graph = session.currentGraph
        XCTAssertEqual(graph.currentFingerprint, graph.rootFingerprint,
            "Explorer must reset to root when trapped")
    }
}
