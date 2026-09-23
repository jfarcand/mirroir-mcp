// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentDetector post-processing absorption.
// ABOUTME: Verifies that absorbing components merge adjacent rows after detection.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension ComponentDetectorTests {

    // MARK: - Post-Processing Absorption

    /// Helper to build a ScreenComponent with an absorbing definition for testing.
    private func makeAbsorbingComponent(
        kind: String, elements: [ClassifiedElement],
        absorbRange: Double, condition: AbsorbCondition = .any,
        clickable: Bool = true
    ) -> ScreenComponent {
        let def = ComponentDefinition(
            name: kind,
            platform: "ios",
            description: "Test absorbing component.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 10,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: clickable, clickTarget: .firstNavigation,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: clickable,
                role: clickable ? .depthNavigation : .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true, absorbsBelowWithinPt: absorbRange,
                absorbCondition: condition, splitMode: .none
            )
        )

        let ys = elements.map { $0.point.tapY }
        let topY = ys.min() ?? 0
        let bottomY = ys.max() ?? 0
        let tapTarget = elements.first(where: { $0.role == .navigation })?.point

        return ScreenComponent(
            kind: kind, definition: def, elements: elements,
            tapTarget: tapTarget,
            hasChevron: false, topY: topY, bottomY: bottomY
        )
    }

    /// Helper to build a simple non-absorbing component for testing.
    private func makeSimpleComponent(
        kind: String, elements: [ClassifiedElement], clickable: Bool = true
    ) -> ScreenComponent {
        return makeAbsorbingComponent(
            kind: kind, elements: elements, absorbRange: 0, clickable: clickable
        )
    }

    func testApplyAbsorptionMergesNearbyComponents() {
        // Summary card at y=280 with absorbs_below_within_pt=80
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80
        )
        // List item at y=335, within 80pt of parent's bottomY (280)
        let child = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("Bouger", x: 100, y: 335)]
        )

        let result = ComponentDetector.applyAbsorption([parent, child])

        XCTAssertEqual(result.count, 1,
            "Nearby component should be absorbed into the parent")
        XCTAssertEqual(result[0].elements.count, 2,
            "Merged component should contain both elements")
    }

    func testApplyAbsorptionSkipsBeyondRange() {
        // Summary card at y=100 with absorbs_below_within_pt=80
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 100)],
            absorbRange: 80
        )
        // List item at y=250, beyond 80pt range (100 + 80 = 180 < 250)
        let distant = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("Loin", x: 100, y: 250)]
        )

        let result = ComponentDetector.applyAbsorption([parent, distant])

        XCTAssertEqual(result.count, 2,
            "Component beyond absorption range should stay separate")
    }

    func testApplyAbsorptionPreservesParentTapTarget() {
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80
        )
        let child = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("65 cal", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, child])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tapTarget?.text, "Activité",
            "Merged component should keep the parent's tap target")
    }

    func testApplyAbsorptionRespectsCondition() {
        // Parent with infoOrDecorationOnly condition
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80,
            condition: .infoOrDecorationOnly
        )
        // Navigation element should NOT be absorbed (condition requires info/deco only)
        let navChild = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedNav("Détails", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, navChild])

        XCTAssertEqual(result.count, 2,
            "Navigation element should not be absorbed with infoOrDecorationOnly condition")
    }

    func testApplyAbsorptionAbsorbsInfoWithCondition() {
        // Same condition but with info-role elements — should absorb
        let parent = makeAbsorbingComponent(
            kind: "summary-card",
            elements: [classifiedNav("Activité", x: 100, y: 280)],
            absorbRange: 80,
            condition: .infoOrDecorationOnly
        )
        let infoChild = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("65 cal", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, infoChild])

        XCTAssertEqual(result.count, 1,
            "Info element should be absorbed with infoOrDecorationOnly condition")
    }

    func testNoChevronRowsOnlyAbsorbsInfoRow() {
        // Disclosure row at y=280 absorbs a non-chevron info row at y=330
        let parent = makeAbsorbingComponent(
            kind: "table-row-disclosure",
            elements: [
                classifiedNav("Activité", x: 100, y: 280, hasChevron: true),
                classifiedDeco(">", x: 370, y: 280),
            ],
            absorbRange: 80,
            condition: .noChevronRowsOnly
        )
        let child = makeSimpleComponent(
            kind: "list-item",
            elements: [classifiedInfo("12,4 km", x: 100, y: 330)]
        )

        let result = ComponentDetector.applyAbsorption([parent, child])

        XCTAssertEqual(result.count, 1,
            "Non-chevron row should be absorbed with noChevronRowsOnly condition")
        XCTAssertEqual(result[0].elements.count, 3,
            "Merged component should contain parent (2) + child (1) elements")
    }

    func testNoChevronRowsOnlyRejectsChevronRow() {
        // Disclosure row at y=280 should NOT absorb another chevron row at y=330
        let parent = makeAbsorbingComponent(
            kind: "table-row-disclosure",
            elements: [
                classifiedNav("Activité", x: 100, y: 280, hasChevron: true),
                classifiedDeco(">", x: 370, y: 280),
            ],
            absorbRange: 80,
            condition: .noChevronRowsOnly
        )
        let chevronChild = makeSimpleComponent(
            kind: "table-row-disclosure",
            elements: [
                classifiedNav("Bouger", x: 100, y: 330, hasChevron: true),
                classifiedDeco(">", x: 370, y: 330),
            ]
        )

        let result = ComponentDetector.applyAbsorption([parent, chevronChild])

        XCTAssertEqual(result.count, 2,
            "Chevron row should NOT be absorbed with noChevronRowsOnly condition")
    }

    func testApplyAbsorptionNoAbsorbWhenRangeZero() {
        // Both components have absorbRange=0 — no absorption
        let a = makeSimpleComponent(
            kind: "row-a",
            elements: [classifiedNav("First", x: 100, y: 300)]
        )
        let b = makeSimpleComponent(
            kind: "row-b",
            elements: [classifiedNav("Second", x: 100, y: 310)]
        )

        let result = ComponentDetector.applyAbsorption([a, b])

        XCTAssertEqual(result.count, 2,
            "Components with zero absorb range should not merge")
    }
}
