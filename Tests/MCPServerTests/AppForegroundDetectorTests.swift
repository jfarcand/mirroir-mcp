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
// ABOUTME: Tests for AppForegroundDetector: foreground detection via persisted graph root similarity.
// ABOUTME: Covers spotlight pre-empt, missing-graph fallback, match/unmatch verdicts, and Jaccard math.

import XCTest
@testable import mirroir_mcp
@testable import HelperLib

final class AppForegroundDetectorTests: XCTestCase {

    // Use a unique app name per test so the persisted graph file doesn't
    // collide with other tests or with real exploration data on the dev box.
    private var appName: String!

    override func setUp() {
        super.setUp()
        appName = "ForegroundTest-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let appName { _ = GraphPersistence.delete(bundleID: appName) }
        super.tearDown()
    }

    // MARK: - Spotlight precedence

    func testSpotlightVisibleShortCircuitsBeforeGraphCheck() {
        // Even with a matching graph on disk, an active Spotlight overlay
        // means we're not in the app yet — caller must launch.
        persistRoot([
            tap("Bon après-midi, Cheffamille"),
            tap("Discuter avec Claude"),
        ])
        let elements = [
            tap("Top Hit"),
            tap("Bon après-midi, Cheffamille"),
        ]
        XCTAssertEqual(
            AppForegroundDetector.detect(elements: elements, appName: appName),
            .spotlightVisible
        )
    }

    // MARK: - Graph fallback

    func testNoGraphReturnsNoPersistedGraph() {
        let elements = [tap("Some App Title")]
        XCTAssertEqual(
            AppForegroundDetector.detect(elements: elements, appName: appName),
            .noPersistedGraph
        )
    }

    // MARK: - Match / unmatch

    func testHighSimilarityReturnsAlreadyForeground() {
        persistRoot([
            tap("Bon après-midi, Cheffamille"),
            tap("Discuter avec Claude"),
            tap("Opus 4.7"),
            tap("+"),
        ])
        // 3 of 4 root labels visible — easily above the 0.5 threshold.
        let elements = [
            tap("Bon après-midi, Cheffamille"),
            tap("Discuter avec Claude"),
            tap("Opus 4.7"),
            tap("icon"),
        ]
        let verdict = AppForegroundDetector.detect(elements: elements, appName: appName)
        guard case .alreadyForeground(let similarity) = verdict else {
            return XCTFail("expected alreadyForeground, got \(verdict)")
        }
        XCTAssertGreaterThanOrEqual(similarity, AppForegroundDetector.matchThreshold)
    }

    func testMatchesAnyNodeNotJustRoot() {
        // Exploration may end on a sub-screen. If the current screen matches
        // ANY persisted node, we're still inside the target app.
        persistGraph(
            rootFingerprint: "root",
            nodes: [
                ("root", 0, [tap("Bon après-midi"), tap("Discuter avec Claude")]),
                ("sub", 1, [tap("Conversations"), tap("Rechercher"), tap("Récupération après trail")]),
            ]
        )
        // Current screen mirrors the depth-1 sub-screen, not the root.
        let elements = [
            tap("Conversations"),
            tap("Rechercher"),
            tap("Récupération après trail"),
        ]
        let verdict = AppForegroundDetector.detect(elements: elements, appName: appName)
        guard case .alreadyForeground(let similarity) = verdict else {
            return XCTFail("expected alreadyForeground for sub-screen match, got \(verdict)")
        }
        XCTAssertGreaterThanOrEqual(similarity, AppForegroundDetector.matchThreshold)
    }

    func testLowSimilarityReturnsUnmatched() {
        persistRoot([
            tap("Bon après-midi, Cheffamille"),
            tap("Discuter avec Claude"),
            tap("Opus 4.7"),
            tap("+"),
        ])
        // Different screen entirely (Settings) — no overlap with Claude root.
        let elements = [
            tap("Réglages"),
            tap("Wi-Fi"),
            tap("Bluetooth"),
            tap("Batterie"),
        ]
        let verdict = AppForegroundDetector.detect(elements: elements, appName: appName)
        guard case .unmatched(let similarity) = verdict else {
            return XCTFail("expected unmatched, got \(verdict)")
        }
        XCTAssertLessThan(similarity, AppForegroundDetector.matchThreshold)
    }

    // MARK: - Foreign-app guard

    func testForeignAppDetectedWithZeroOverlap() {
        // The incident case: a failed pre-explore reset left Mail foreground;
        // its screen shares no tokens with the target's graph — must be foreign.
        persistRoot([
            tap("Votre story"), tap("Suggestions pour vous"),
            tap("festival_de_la_poutine"), tap("Recherche"),
        ])
        let mail = [
            tap("Boîte de réception"), tap("Votre liste de visionnement"),
            tap("Se désabonner"), tap("Provient d'une liste de distribution"),
        ]
        XCTAssertTrue(
            AppForegroundDetector.looksForeign(elements: mail, appName: appName),
            "A screen with no token overlap must be treated as a foreign app")
    }

    func testChurnedFeedIsNotForeign() {
        // Feed content rotates run to run, but chrome tokens persist — a churned
        // view of the target must never be declared foreign (it would abort
        // legitimate explores).
        persistRoot([
            tap("Votre story"), tap("Suggestions pour vous"),
            tap("old_username_a"), tap("old caption text one"),
            tap("old_username_b"), tap("old caption text two"),
        ])
        let churned = [
            tap("Votre story"),  // stable chrome survives
            tap("new_username_c"), tap("completely new caption"),
            tap("new_username_d"), tap("another new caption"),
            tap("yet another post line"),
        ]
        XCTAssertFalse(
            AppForegroundDetector.looksForeign(elements: churned, appName: appName),
            "Shared chrome must keep a churned target screen above the foreign floor")
    }

    func testNoGraphIsNeverForeign() {
        let anything = [tap("Boîte de réception"), tap("Se désabonner")]
        XCTAssertFalse(
            AppForegroundDetector.looksForeign(elements: anything, appName: appName),
            "First-ever explores have no fingerprint — must not be blocked")
    }

    // MARK: - Jaccard math directly

    func testJaccardIgnoresIconPlaceholdersAndEmpty() {
        let a = [tap("Foo"), tap("icon"), tap(""), tap("Bar")]
        let b = [tap("foo"), tap("bar"), tap("ICON")]
        // Normalized text sets are {foo, bar} on both sides.
        XCTAssertEqual(
            AppForegroundDetector.jaccardSimilarity(current: a, root: b),
            1.0,
            accuracy: 0.0001
        )
    }

    func testJaccardZeroOnEmptyInput() {
        XCTAssertEqual(
            AppForegroundDetector.jaccardSimilarity(current: [], root: []),
            0.0
        )
        XCTAssertEqual(
            AppForegroundDetector.jaccardSimilarity(
                current: [tap("icon")], root: [tap("icon")]
            ),
            0.0,
            "icon-only sets normalize to empty and must not divide by zero"
        )
    }

    func testJaccardHalfOverlap() {
        let a = [tap("A"), tap("B")]
        let b = [tap("B"), tap("C")]
        // intersection = 1, union = 3 → 1/3.
        XCTAssertEqual(
            AppForegroundDetector.jaccardSimilarity(current: a, root: b),
            1.0 / 3.0,
            accuracy: 0.0001
        )
    }

    // MARK: - Helpers

    private func tap(_ text: String) -> TapPoint {
        TapPoint(text: text, tapX: 100, tapY: 100, confidence: 0.9)
    }

    /// Persist a graph with a single root node carrying the given elements.
    private func persistRoot(_ elements: [TapPoint]) {
        persistGraph(
            rootFingerprint: "test-root-fp",
            nodes: [("test-root-fp", 0, elements)]
        )
    }

    /// Persist a graph with arbitrary nodes. Each node tuple is (fingerprint, depth, elements).
    private func persistGraph(rootFingerprint: String, nodes: [(String, Int, [TapPoint])]) {
        var nodeMap: [String: ScreenNode] = [:]
        for (fingerprint, depth, elements) in nodes {
            nodeMap[fingerprint] = ScreenNode(
                fingerprint: fingerprint,
                elements: elements,
                icons: [],
                hints: [],
                depth: depth,
                screenType: .unknown,
                screenshotBase64: "",
                visitedElements: [],
                navBarTitle: nil,
                isInfiniteScroll: false,
                scrollExhausted: false,
                visualHash: nil
            )
        }
        let snapshot = GraphSnapshot(
            nodes: nodeMap,
            edges: [],
            adjacency: [:],
            rootFingerprint: rootFingerprint,
            deadEdges: [],
            recoveryEvents: []
        )
        _ = GraphPersistence.save(snapshot: snapshot, bundleID: appName)
    }
}
