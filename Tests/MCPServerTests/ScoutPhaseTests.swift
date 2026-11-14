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
// ABOUTME: Unit tests for ScoutPhase: scout-then-dive decision logic for DFS exploration.
// ABOUTME: Verifies shouldScout conditions, nextScoutTarget selection, and rankForDive prioritization.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScoutPhaseTests: XCTestCase {

    // MARK: - Helpers

    private func point(_ text: String, x: Double = 205, y: Double = 200) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    private func makeNavElements(_ count: Int) -> [ClassifiedElement] {
        (0..<count).map { i in
            ClassifiedElement(
                point: point("Item \(i)", y: Double(120 + i * 80)),
                role: .navigation
            )
        }
    }

    // MARK: - shouldScout

    func testShouldNotScoutListScreen() {
        XCTAssertFalse(
            ScoutPhase.shouldScout(screenType: .list, depth: 0, navigationCount: 5),
            "List screen should not scout — chevrons already indicate navigation"
        )
    }

    func testShouldNotScoutSettingsScreen() {
        XCTAssertFalse(
            ScoutPhase.shouldScout(screenType: .settings, depth: 0, navigationCount: 6),
            "Settings screen should not scout — chevrons already indicate navigation"
        )
    }

    func testShouldScoutTabRootScreen() {
        XCTAssertTrue(
            ScoutPhase.shouldScout(screenType: .tabRoot, depth: 1, navigationCount: 4)
        )
    }

    func testShouldNotScoutDetailScreen() {
        XCTAssertFalse(
            ScoutPhase.shouldScout(screenType: .detail, depth: 0, navigationCount: 5),
            "Detail screens should not scout"
        )
    }

    func testShouldNotScoutModalScreen() {
        XCTAssertFalse(
            ScoutPhase.shouldScout(screenType: .modal, depth: 0, navigationCount: 5)
        )
    }

    func testShouldNotScoutDeepScreen() {
        XCTAssertFalse(
            ScoutPhase.shouldScout(screenType: .list, depth: 2, navigationCount: 5),
            "Depth >= 2 should not scout"
        )
    }

    func testShouldNotScoutFewElements() {
        XCTAssertFalse(
            ScoutPhase.shouldScout(screenType: .list, depth: 0, navigationCount: 3),
            "< 4 navigation elements should not scout"
        )
    }

    func testShouldScoutExactMinimum() {
        XCTAssertTrue(
            ScoutPhase.shouldScout(screenType: .tabRoot, depth: 1, navigationCount: 4),
            "Exactly 4 navigation elements at depth 1 on tabRoot should scout"
        )
    }

    // MARK: - nextScoutTarget

    func testNextScoutTargetPicksUnscouted() {
        let classified = makeNavElements(3)
        let scouted: Set<String> = ["Item 0"]

        let target = ScoutPhase.nextScoutTarget(classified: classified, scouted: scouted)
        XCTAssertEqual(target?.text, "Item 1",
            "Should pick first unscouted navigation element")
    }

    func testNextScoutTargetSkipsAlreadyScouted() {
        let classified = makeNavElements(3)
        let scouted: Set<String> = ["Item 0", "Item 1"]

        let target = ScoutPhase.nextScoutTarget(classified: classified, scouted: scouted)
        XCTAssertEqual(target?.text, "Item 2")
    }

    func testNextScoutTargetReturnsNilWhenAllScouted() {
        let classified = makeNavElements(2)
        let scouted: Set<String> = ["Item 0", "Item 1"]

        let target = ScoutPhase.nextScoutTarget(classified: classified, scouted: scouted)
        XCTAssertNil(target, "Should return nil when all navigation elements scouted")
    }

    func testNextScoutTargetSkipsNonNavigation() {
        let classified: [ClassifiedElement] = [
            ClassifiedElement(point: point("On"), role: .info),
            ClassifiedElement(point: point(">"), role: .decoration),
            ClassifiedElement(point: point("General"), role: .navigation),
        ]

        let target = ScoutPhase.nextScoutTarget(classified: classified, scouted: [])
        XCTAssertEqual(target?.text, "General",
            "Should skip non-navigation elements")
    }

    // MARK: - rankForDive

    func testRankForDivePrioritizesNavigated() {
        let classified: [ClassifiedElement] = [
            ClassifiedElement(point: point("About", y: 200), role: .navigation),
            ClassifiedElement(point: point("General", y: 300), role: .navigation),
            ClassifiedElement(point: point("Privacy", y: 400), role: .navigation),
        ]
        let scoutResults: [String: ScoutResult] = [
            "About": .noChange,
            "General": .navigated,
            "Privacy": .navigated,
        ]

        let ranked = ScoutPhase.rankForDive(
            scoutResults: scoutResults, classified: classified
        )

        XCTAssertEqual(ranked.count, 2, "Should exclude noChange elements")
        XCTAssertEqual(ranked[0].text, "General", "Navigated should come first")
        XCTAssertEqual(ranked[1].text, "Privacy", "Second navigated element")
    }

    func testRankForDiveExcludesNoChangeElements() {
        let classified: [ClassifiedElement] = [
            ClassifiedElement(point: point("Toggle Row"), role: .navigation),
        ]
        let scoutResults: [String: ScoutResult] = [
            "Toggle Row": .noChange,
        ]

        let ranked = ScoutPhase.rankForDive(
            scoutResults: scoutResults, classified: classified
        )

        XCTAssertTrue(ranked.isEmpty,
            "Elements that scouted as noChange should be excluded")
    }

    func testRankForDiveIncludesUnscoutedAsFallback() {
        let classified: [ClassifiedElement] = [
            ClassifiedElement(point: point("Scouted", y: 200), role: .navigation),
            ClassifiedElement(point: point("Unscouted", y: 300), role: .navigation),
        ]
        let scoutResults: [String: ScoutResult] = [
            "Scouted": .navigated,
        ]

        let ranked = ScoutPhase.rankForDive(
            scoutResults: scoutResults, classified: classified
        )

        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].text, "Scouted", "Navigated first")
        XCTAssertEqual(ranked[1].text, "Unscouted", "Unscouted as fallback")
    }

    func testRankForDiveIgnoresNonNavigationRoles() {
        let classified: [ClassifiedElement] = [
            ClassifiedElement(point: point("Wi-Fi"), role: .stateChange),
            ClassifiedElement(point: point("On"), role: .info),
            ClassifiedElement(point: point("General"), role: .navigation),
        ]

        let ranked = ScoutPhase.rankForDive(
            scoutResults: [:], classified: classified
        )

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].text, "General")
    }
}
