// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentSkillParser: parsing COMPONENT.md files.
// ABOUTME: Verifies front matter extraction, section parsing, and fallback behavior.

import XCTest
@testable import mirroir_mcp

final class ComponentSkillParserTests: XCTestCase {

    // MARK: - Full Parse

    func testParseCompleteComponentFile() {
        let content = """
            ---
            version: 1
            name: table-row-disclosure
            platform: ios
            ---

            # Table Row with Disclosure Indicator

            ## Description

            Standard UITableViewCell with a disclosure indicator.

            ## Visual Pattern

            - One or two text labels aligned left
            - Chevron at the far right edge

            ## Match Rules

            - row_has_chevron: true
            - min_elements: 1
            - max_elements: 4
            - max_row_height_pt: 90
            - zone: content

            ## Interaction

            - clickable: true
            - click_target: first_navigation_element
            - click_result: navigates
            - back_after_click: true

            ## Grouping

            - absorbs_same_row: true
            - absorbs_below_within_pt: 0
            - absorb_condition: any
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.name, "table-row-disclosure")
        XCTAssertEqual(definition.platform, "ios")
        XCTAssertEqual(definition.description, "Standard UITableViewCell with a disclosure indicator.")
        XCTAssertEqual(definition.visualPattern.count, 2)
        XCTAssertEqual(definition.visualPattern[0], "One or two text labels aligned left")

        // Match rules
        XCTAssertEqual(definition.matchRules.rowHasChevron, true)
        XCTAssertEqual(definition.matchRules.minElements, 1)
        XCTAssertEqual(definition.matchRules.maxElements, 4)
        XCTAssertEqual(definition.matchRules.maxRowHeightPt, 90)
        XCTAssertEqual(definition.matchRules.zone, .content)
        XCTAssertNil(definition.matchRules.hasNumericValue)

        // Interaction
        XCTAssertTrue(definition.interaction.clickable)
        XCTAssertEqual(definition.interaction.clickTarget, .firstNavigation)
        XCTAssertEqual(definition.interaction.clickResult, .pushesScreen)
        XCTAssertTrue(definition.interaction.backAfterClick)

        // Grouping
        XCTAssertTrue(definition.grouping.absorbsSameRow)
        XCTAssertEqual(definition.grouping.absorbsBelowWithinPt, 0)
        XCTAssertEqual(definition.grouping.absorbCondition, .any)
    }

    func testParseSummaryCardWithAbsorption() {
        let content = """
            ---
            version: 1
            name: summary-card
            platform: ios
            ---

            # Summary Card

            ## Description

            Card showing a metric with title and large value.

            ## Visual Pattern

            - Title text on first line
            - Large numeric value on second line

            ## Match Rules

            - min_elements: 2
            - max_elements: 6
            - max_row_height_pt: 120
            - has_numeric_value: true
            - zone: content

            ## Interaction

            - clickable: true
            - click_target: first_navigation_element
            - click_result: navigates
            - back_after_click: true

            ## Grouping

            - absorbs_same_row: true
            - absorbs_below_within_pt: 50
            - absorb_condition: info_or_decoration_only
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.name, "summary-card")
        XCTAssertEqual(definition.matchRules.hasNumericValue, true)
        XCTAssertEqual(definition.matchRules.minElements, 2)
        XCTAssertEqual(definition.grouping.absorbsBelowWithinPt, 50)
        XCTAssertEqual(definition.grouping.absorbCondition, .infoOrDecorationOnly)
    }

    // MARK: - Front Matter Edge Cases

    func testParseMissingFrontMatterUsesFallbackName() {
        let content = """
            # No Front Matter Component

            ## Description

            A component without YAML front matter.

            ## Match Rules

            - min_elements: 1
            - max_elements: 3
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "my-fallback"
        )

        XCTAssertEqual(definition.name, "my-fallback")
        XCTAssertEqual(definition.platform, "ios") // default
    }

    func testParseEmptyFrontMatter() {
        let content = """
            ---
            ---

            # Empty Front Matter

            ## Description

            Component with empty YAML block.
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "empty-fm"
        )

        XCTAssertEqual(definition.name, "empty-fm")
    }

    // MARK: - Match Rules Defaults

    func testMissingMatchRulesUseDefaults() {
        let content = """
            ---
            name: minimal
            ---

            # Minimal Component
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.minElements, 1)
        XCTAssertEqual(definition.matchRules.maxElements, 10)
        XCTAssertEqual(definition.matchRules.maxRowHeightPt, 100)
        XCTAssertNil(definition.matchRules.rowHasChevron)
        XCTAssertNil(definition.matchRules.hasNumericValue)
        XCTAssertEqual(definition.matchRules.zone, .content)
    }

    // MARK: - Interaction Defaults

    func testMissingInteractionDefaultsToNotClickable() {
        let content = """
            ---
            name: no-interaction
            ---

            # No Interaction Section
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertFalse(definition.interaction.clickable)
        XCTAssertEqual(definition.interaction.clickTarget, .none)
        XCTAssertEqual(definition.interaction.clickResult, .none)
        XCTAssertFalse(definition.interaction.backAfterClick)
    }

    // MARK: - Zone Parsing

    func testParseNavBarZone() {
        let content = """
            ---
            name: nav-bar-test
            ---

            # Nav Bar Test

            ## Match Rules

            - zone: nav_bar
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.zone, .navBar)
    }

    func testParseTabBarZone() {
        let content = """
            ---
            name: tab-bar-test
            ---

            # Tab Bar Test

            ## Match Rules

            - zone: tab_bar
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.zone, .tabBar)
    }

    // MARK: - Boolean Parsing

    func testChevronRequiredFalse() {
        let content = """
            ---
            name: no-chevron
            ---

            # No Chevron

            ## Match Rules

            - row_has_chevron: false
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.rowHasChevron, false)
    }

    // MARK: - Dismiss Button Parsing

    func testParseDismissButtonMatchRule() {
        let content = """
            ---
            name: modal-sheet
            ---

            # Modal Sheet

            ## Match Rules

            - has_dismiss_button: true
            - row_has_chevron: false
            - min_elements: 2
            - max_elements: 4
            - zone: content

            ## Interaction

            - clickable: true
            - click_target: first_dismiss_button
            - click_result: dismisses
            - back_after_click: false
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.hasDismissButton, true)
        XCTAssertEqual(definition.matchRules.rowHasChevron, false)
        XCTAssertEqual(definition.interaction.clickTarget, .firstDismissButton)
        XCTAssertEqual(definition.interaction.clickResult, .dismisses)
        XCTAssertFalse(definition.interaction.backAfterClick)
    }

    // MARK: - Visual Pattern Extraction

    func testVisualPatternExtraction() {
        let content = """
            ---
            name: visual-test
            ---

            # Visual Test

            ## Visual Pattern

            - First pattern line
            - Second pattern line
            - Third pattern line

            ## Match Rules

            - min_elements: 1
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.visualPattern.count, 3)
        XCTAssertEqual(definition.visualPattern[0], "First pattern line")
        XCTAssertEqual(definition.visualPattern[2], "Third pattern line")
    }

    // MARK: - Precision Rules

    func testParsesNewPrecisionRules() {
        let content = """
            ---
            name: tab-bar-item
            platform: ios
            ---

            # Tab Bar Item

            ## Description

            Tab bar item with precision rules.

            ## Match Rules

            - zone: tab_bar
            - min_elements: 1
            - max_elements: 6
            - min_confidence: 0.50
            - exclude_numeric_only: true
            - text_pattern: ^[A-Za-z]+$
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.minConfidence, 0.50)
        XCTAssertEqual(definition.matchRules.excludeNumericOnly, true)
        XCTAssertEqual(definition.matchRules.textPattern, "^[A-Za-z]+$")
    }

    // MARK: - Chevron Mode Parsing

    func testParsesChevronModePreferred() {
        let content = """
            ---
            name: summary-card
            ---

            # Summary Card

            ## Match Rules

            - chevron_mode: preferred
            - has_numeric_value: true
            - min_elements: 2
            - max_elements: 3
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.chevronMode, .preferred)
        XCTAssertNil(definition.matchRules.rowHasChevron,
            "chevron_mode should not set rowHasChevron")
    }

    func testParsesChevronModeRequired() {
        let content = """
            ---
            name: disclosure-row
            ---

            # Disclosure Row

            ## Match Rules

            - chevron_mode: required
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.chevronMode, .required)
    }

    func testParsesChevronModeForbidden() {
        let content = """
            ---
            name: plain-row
            ---

            # Plain Row

            ## Match Rules

            - chevron_mode: forbidden
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.chevronMode, .forbidden)
    }

    func testChevronModeDefaultsToNil() {
        let content = """
            ---
            name: simple
            ---

            # Simple

            ## Match Rules

            - min_elements: 1
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertNil(definition.matchRules.chevronMode,
            "chevronMode should default to nil when not specified")
    }

    func testLegacyRowHasChevronStillParsed() {
        let content = """
            ---
            name: legacy-row
            ---

            # Legacy Row

            ## Match Rules

            - row_has_chevron: true
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.rowHasChevron, true,
            "Legacy row_has_chevron should still be parsed")
        XCTAssertNil(definition.matchRules.chevronMode,
            "chevronMode should be nil when only row_has_chevron is set")
    }

    func testBothChevronModeAndLegacyCanCoexist() {
        let content = """
            ---
            name: both-set
            ---

            # Both Set

            ## Match Rules

            - row_has_chevron: true
            - chevron_mode: preferred
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.matchRules.rowHasChevron, true)
        XCTAssertEqual(definition.matchRules.chevronMode, .preferred,
            "Both fields should be parsed independently")
    }

    func testPrecisionRulesDefaultToNil() {
        let content = """
            ---
            name: simple
            ---

            # Simple

            ## Match Rules

            - min_elements: 1
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertNil(definition.matchRules.minConfidence)
        XCTAssertNil(definition.matchRules.excludeNumericOnly)
        XCTAssertNil(definition.matchRules.textPattern)
    }
}
