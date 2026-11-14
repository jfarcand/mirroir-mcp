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
// ABOUTME: Unit tests for EdgeClassifier: transition classification and dismiss target detection.
// ABOUTME: Verifies push/modal/tab classification priority and dismiss button lookup.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class EdgeClassifierTests: XCTestCase {

    // MARK: - Test Helpers

    private let screenHeight: Double = 890

    private func makeNode(
        elements: [TapPoint],
        screenType: ScreenType = .settings,
        depth: Int = 0
    ) -> ScreenNode {
        ScreenNode(
            fingerprint: "test-fp",
            elements: elements,
            icons: [],
            hints: [],
            depth: depth,
            screenType: screenType,
            screenshotBase64: "",
            visitedElements: [],
            navBarTitle: nil
        )
    }

    private func tap(_ text: String, x: Double = 205, y: Double = 200) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Classification

    func testClassifyPush() {
        let source = makeNode(elements: [tap("Settings", y: 150)])
        // Destination has a back chevron in top zone
        let destElements = [
            tap("<", x: 40, y: 100),
            tap("General", y: 150),
            tap("About", y: 340),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("General", y: 340),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .push)
    }

    func testClassifyModal() {
        let source = makeNode(elements: [tap("Settings", y: 150)])
        // Destination has Close button in top zone, no back chevron
        let destElements = [
            tap("Close", x: 40, y: 100),
            tap("Privacy Report", y: 150),
            tap("Details", y: 340),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("Privacy", y: 420),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .modal)
    }

    func testClassifyModalWithXmark() {
        let source = makeNode(elements: [tap("Settings", y: 150)])
        // "X" in top zone, no back chevron
        let destElements = [
            tap("X", x: 370, y: 80),
            tap("Modal Content", y: 300),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("Something", y: 400),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .modal)
    }

    func testClassifyTab() {
        // Source is tabRoot, tapped element is in bottom zone (≥85% of 890 = 756.5)
        let source = makeNode(
            elements: [
                tap("Home", y: 850),
                tap("Search", y: 850),
            ],
            screenType: .tabRoot
        )

        let destElements = [
            tap("<", x: 40, y: 100),
            tap("Search Results", y: 150),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("Search", y: 850),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .tab)
    }

    func testClassifyTabForSynthesizedAnchor() {
        // Icon-only tab root: the tapped element is a geometrically synthesized
        // anchor carrying no OCR text — the tab-zone position alone classifies it.
        let source = makeNode(
            elements: [tap("Feed content", y: 300)],
            screenType: .tabRoot
        )

        let destElements = [
            tap("Search Results", y: 150),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("", x: 41, y: screenHeight * 0.95),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .tab,
            "Text-less synthesized anchor in the tab zone should classify as .tab")
    }

    func testClassifyTabRejectsNonTabRoot() {
        // Source is NOT tabRoot — bottom zone tap should still be push
        let source = makeNode(
            elements: [tap("Settings", y: 150)],
            screenType: .settings
        )

        let destElements = [
            tap("<", x: 40, y: 100),
            tap("Content", y: 300),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("Tab Item", y: 850),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .push,
            "Non-tabRoot source should classify as push even with bottom-zone tap")
    }

    func testClassifyFallbackToPush() {
        let source = makeNode(elements: [tap("Settings", y: 150)])
        // No back chevron, no dismiss button — fallback to push
        let destElements = [
            tap("Some Content", y: 300),
            tap("More Content", y: 400),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("Something", y: 340),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .push,
            "When no clear signals, should fall back to push")
    }

    func testClassifyModalWithDoneButton() {
        let source = makeNode(elements: [tap("Settings", y: 150)])
        let destElements = [
            tap("Done", x: 370, y: 100),
            tap("Editor", y: 300),
        ]

        let result = EdgeClassifier.classify(
            sourceNode: source,
            destinationElements: destElements,
            destinationHints: [],
            tappedElement: tap("Edit", y: 400),
            screenHeight: screenHeight
        )

        XCTAssertEqual(result, .modal)
    }

    // MARK: - Edge Type Enum Values

    func testEdgeTypeToggleRawValue() {
        XCTAssertEqual(EdgeType.toggle.rawValue, "toggle")
    }

    func testEdgeTypeExternalRawValue() {
        XCTAssertEqual(EdgeType.external.rawValue, "external")
    }

    func testEdgeTypeRoundtripAllCases() {
        // Verify all edge types survive raw value round-trip (persistence)
        let allCases: [EdgeType] = [.push, .modal, .tab, .same, .dead, .toggle, .external]
        for edgeType in allCases {
            let roundtripped = EdgeType(rawValue: edgeType.rawValue)
            XCTAssertEqual(roundtripped, edgeType,
                "EdgeType.\(edgeType.rawValue) should survive raw value round-trip")
        }
    }

    // MARK: - Dismiss Target

    func testFindDismissTargetCloseButton() {
        let elements = [
            tap("Close", x: 40, y: 100),
            tap("Content", y: 300),
        ]

        let target = EdgeClassifier.findDismissTarget(
            elements: elements, screenHeight: screenHeight
        )

        XCTAssertNotNil(target)
        XCTAssertEqual(target?.text, "Close")
    }

    func testFindDismissTargetDoneButton() {
        let elements = [
            tap("Done", x: 370, y: 100),
            tap("Content", y: 300),
        ]

        let target = EdgeClassifier.findDismissTarget(
            elements: elements, screenHeight: screenHeight
        )

        XCTAssertNotNil(target)
        XCTAssertEqual(target?.text, "Done")
    }

    func testFindDismissTargetNoneFound() {
        let elements = [
            tap("Settings", y: 150),
            tap("General", y: 340),
        ]

        let target = EdgeClassifier.findDismissTarget(
            elements: elements, screenHeight: screenHeight
        )

        XCTAssertNil(target,
            "Should return nil when no dismiss button in top zone")
    }

    func testFindDismissTargetIgnoresBottomZone() {
        // "Close" button exists but not in top zone
        let elements = [
            tap("Content", y: 300),
            tap("Close", x: 40, y: 800),
        ]

        let target = EdgeClassifier.findDismissTarget(
            elements: elements, screenHeight: screenHeight
        )

        XCTAssertNil(target,
            "Should not find dismiss buttons outside the top zone")
    }
}
