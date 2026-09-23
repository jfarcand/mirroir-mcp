// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentSkillParser: parsing COMPONENT.md files.
// ABOUTME: Verifies full parse, front matter extraction, and match/interaction defaults.

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

        // Exploration defaults (section absent → derived from interaction)
        XCTAssertTrue(definition.exploration.explorable,
            "Exploration.explorable should default to interaction.clickable")
        XCTAssertEqual(definition.exploration.role, .depthNavigation,
            "Exploration.role should default to depth_navigation")
        XCTAssertEqual(definition.exploration.priority, .normal,
            "Exploration.priority should default to normal")

        // Grouping
        XCTAssertTrue(definition.grouping.absorbsSameRow)
        XCTAssertEqual(definition.grouping.absorbsBelowWithinPt, 0)
        XCTAssertEqual(definition.grouping.absorbCondition, .any)
    }

    func testParseExplicitExplorationSection() {
        let content = """
            ---
            version: 1
            name: tab-bar-item
            platform: ios
            ---

            # Tab Bar Item

            ## Description

            Tab bar button for top-level navigation.

            ## Match Rules

            - zone: tab_bar

            ## Interaction

            - clickable: true
            - click_target: first_text
            - click_result: switches_context
            - back_after_click: false

            ## Exploration

            - explorable: true
            - role: breadth_navigation
            - priority: high

            ## Grouping

            - absorbs_same_row: false
            - absorbs_below_within_pt: 0
            - absorb_condition: any
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.name, "tab-bar-item")
        XCTAssertTrue(definition.exploration.explorable)
        XCTAssertEqual(definition.exploration.role, .breadthNavigation)
        XCTAssertEqual(definition.exploration.priority, .high)
    }

    func testExplorationDefaultsToNotExplorableWhenNotClickable() {
        let content = """
            ---
            version: 1
            name: section-header
            platform: ios
            ---

            # Section Header

            ## Interaction

            - clickable: false
            - click_target: none
            - click_result: none
            - back_after_click: false
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertFalse(definition.exploration.explorable,
            "Non-clickable component should default to non-explorable")
        XCTAssertEqual(definition.exploration.role, .depthNavigation)
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

}
