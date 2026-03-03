// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
