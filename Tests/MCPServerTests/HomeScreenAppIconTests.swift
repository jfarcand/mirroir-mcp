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
// ABOUTME: Tests finding an app's Home Screen icon by its exact label on one page.
// ABOUTME: Pages are OCR elements as the iPhone's capture gives them: labels plus the search pill.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class HomeScreenAppIconTests: XCTestCase {

    private let height = 898.0

    private func el(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    /// A Home Screen page: its icon labels and the search pill at the bottom.
    private func page(_ labels: [String]) -> [TapPoint] {
        labels.enumerated().map { index, label in
            el(label, 60 + Double(index % 4) * 95, 140 + Double(index / 4) * 105)
        } + [el("Q Rechercher", 205, 783)]
    }

    // MARK: - The label

    func testTheLabelMustEqualTheNameIgnoringCaseAndAccents() {
        let elements = page(["Notes", "Rappels", "Réglages"])
        XCTAssertEqual(HomeScreenAppIcon.label(for: "rappels", in: elements)?.text, "Rappels")
        XCTAssertEqual(HomeScreenAppIcon.label(for: "Reglages", in: elements)?.text, "Réglages")
        XCTAssertEqual(HomeScreenAppIcon.label(for: " RÉGLAGES ", in: elements)?.text, "Réglages")
    }

    /// Never a near match: Settings must not open for another name.
    func testANearMatchIsNotTheApp() {
        let elements = page(["Réglages", "Rappels", "Calculatrice"])
        XCTAssertNil(HomeScreenAppIcon.label(for: "Réglages Wi-Fi", in: elements))
        XCTAssertNil(HomeScreenAppIcon.label(for: "Réglage", in: elements))
        XCTAssertNil(HomeScreenAppIcon.label(for: "Rappel", in: elements))
        XCTAssertNil(HomeScreenAppIcon.label(for: "Calcul", in: elements))
        XCTAssertNil(HomeScreenAppIcon.label(for: "", in: elements))
    }

    func testADetectorIconIsNotALabel() {
        let elements = [el(CoreMLElementDetector.iconLabel, 60, 120)]
        XCTAssertNil(HomeScreenAppIcon.label(for: CoreMLElementDetector.iconLabel, in: elements))
    }

    func testTheHigherOfTwoEqualLabelsWins() {
        let elements = [el("Météo", 200, 420), el("Météo", 80, 160)]
        XCTAssertEqual(HomeScreenAppIcon.label(for: "Météo", in: elements)?.tapY, 160)
    }
}
