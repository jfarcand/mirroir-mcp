// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentScoring: scoring definitions against row properties.
// ABOUTME: Covers all three chevron modes (required, forbidden, preferred) and legacy behavior.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ComponentScoringTests: XCTestCase {

    // MARK: - Helpers

    /// Build a definition with a specific chevron mode for testing.
    private func definitionWithChevronMode(
        _ mode: ChevronMode?,
        rowHasChevron: Bool? = nil
    ) -> ComponentDefinition {
        ComponentDefinition(
            name: "test-chevron",
            platform: "ios",
            description: "Test definition for chevron mode.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: rowHasChevron,
                chevronMode: mode,
                minElements: 1,
                maxElements: 10,
                maxRowHeightPt: 100,
                hasNumericValue: nil,
                hasLongText: nil,
                hasDismissButton: nil,
                zone: .content,
                minConfidence: nil,
                excludeNumericOnly: nil,
                textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true,
                clickTarget: .firstNavigation,
                clickResult: .pushesScreen,
                backAfterClick: true
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true,
                absorbsBelowWithinPt: 0,
                absorbCondition: .any
            )
        )
    }

    private func rowProps(hasChevron: Bool) -> ComponentDetector.RowProperties {
        ComponentDetector.RowProperties(
            elementCount: 2,
            hasChevron: hasChevron,
            hasNumericValue: true,
            rowHeight: 5,
            topY: 400,
            bottomY: 405,
            zone: .content,
            hasStateIndicator: false,
            hasLongText: false,
            hasDismissButton: false,
            averageConfidence: 0.95,
            numericOnlyCount: 0,
            elementTexts: ["Distance", "12,4km"]
        )
    }

    // MARK: - ChevronMode.required

    func testRequiredChevronMatchesWhenPresent() {
        let def = definitionWithChevronMode(.required)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: true)
        )
        XCTAssertNotNil(score, "Required chevron should match when chevron is present")
    }

    func testRequiredChevronFailsWhenAbsent() {
        let def = definitionWithChevronMode(.required)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )
        XCTAssertNil(score, "Required chevron should hard-fail when chevron is absent")
    }

    // MARK: - ChevronMode.forbidden

    func testForbiddenChevronMatchesWhenAbsent() {
        let def = definitionWithChevronMode(.forbidden)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )
        XCTAssertNotNil(score, "Forbidden chevron should match when chevron is absent")
    }

    func testForbiddenChevronFailsWhenPresent() {
        let def = definitionWithChevronMode(.forbidden)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: true)
        )
        XCTAssertNil(score, "Forbidden chevron should hard-fail when chevron is present")
    }

    // MARK: - ChevronMode.preferred

    func testPreferredChevronMatchesWhenPresent() {
        let def = definitionWithChevronMode(.preferred)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: true)
        )
        XCTAssertNotNil(score, "Preferred chevron should match when chevron is present")
    }

    func testPreferredChevronMatchesWhenAbsent() {
        let def = definitionWithChevronMode(.preferred)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )
        XCTAssertNotNil(score, "Preferred chevron should still match when chevron is absent")
    }

    func testPreferredChevronGivesBonusWhenPresent() {
        let def = definitionWithChevronMode(.preferred)
        let withChevron = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: true)
        )!
        let withoutChevron = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )!
        XCTAssertGreaterThan(withChevron, withoutChevron,
            "Preferred chevron should give higher score when chevron is present")
    }

    // MARK: - Legacy rowHasChevron (backward compatibility)

    func testLegacyRowHasChevronTrueRequiresChevron() {
        let def = definitionWithChevronMode(nil, rowHasChevron: true)
        let matchWithChevron = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: true)
        )
        let matchWithoutChevron = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )
        XCTAssertNotNil(matchWithChevron, "Legacy rowHasChevron=true should match with chevron")
        XCTAssertNil(matchWithoutChevron, "Legacy rowHasChevron=true should fail without chevron")
    }

    func testLegacyRowHasChevronFalseRequiresNoChevron() {
        let def = definitionWithChevronMode(nil, rowHasChevron: false)
        let matchWithoutChevron = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )
        let matchWithChevron = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: true)
        )
        XCTAssertNotNil(matchWithoutChevron, "Legacy rowHasChevron=false should match without chevron")
        XCTAssertNil(matchWithChevron, "Legacy rowHasChevron=false should fail with chevron")
    }

    // MARK: - ChevronMode takes precedence over rowHasChevron

    func testChevronModeTakesPrecedenceOverLegacy() {
        // chevronMode=preferred + rowHasChevron=true: preferred should win (soft constraint)
        let def = definitionWithChevronMode(.preferred, rowHasChevron: true)
        let score = ComponentScoring.scoreMatch(
            definition: def, rowProps: rowProps(hasChevron: false)
        )
        XCTAssertNotNil(score,
            "chevronMode should take precedence over rowHasChevron — preferred allows missing chevron")
    }

    // MARK: - bestMatch delegation

    func testBestMatchUsesScoring() {
        let defs = [
            definitionWithChevronMode(.required),
            definitionWithChevronMode(.preferred),
        ]

        // Row without chevron: .required fails, .preferred matches
        let match = ComponentScoring.bestMatch(
            definitions: defs, rowProps: rowProps(hasChevron: false)
        )
        XCTAssertNotNil(match, "bestMatch should find the preferred definition")
    }
}
