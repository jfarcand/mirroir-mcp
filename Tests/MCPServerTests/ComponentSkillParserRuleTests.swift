// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentSkillParser rule parsing: invalid enum values, label rules, split mode.
// ABOUTME: Verifies enum validation errors and label/split rule extraction from COMPONENT.md.

import XCTest
@testable import mirroir_mcp

extension ComponentSkillParserTests {

    // MARK: - Invalid Enum Value Validation

    func testParseValidatedRejectsInvalidExplorationRole() {
        let content = """
            ---
            name: bad-role
            ---

            # Bad Role

            ## Exploration

            - role: critical_navigation
            - priority: normal
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "bad")

        XCTAssertNil(result,
            "parseValidated should reject unknown exploration role values instead of silently coercing to depth_navigation")
    }

    func testParseValidatedRejectsInvalidExplorationPriority() {
        let content = """
            ---
            name: bad-priority
            ---

            # Bad Priority

            ## Exploration

            - role: depth_navigation
            - priority: urgent
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "bad")

        XCTAssertNil(result,
            "parseValidated should reject unknown exploration priority values instead of silently coercing to normal")
    }

    func testParseValidatedRejectsInvalidZone() {
        let content = """
            ---
            name: bad-zone
            ---

            # Bad Zone

            ## Match Rules

            - zone: middle
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "bad")

        XCTAssertNil(result,
            "parseValidated should reject unknown zone values")
    }

    func testParseValidatedAcceptsLegacyClickResultAlias() {
        // 'navigates' / 'toggles' are legacy synonyms for ClickResult
        // (mapped via ClickResult.init(legacy:)). They must still validate.
        let content = """
            ---
            name: legacy-click
            ---

            # Legacy Click

            ## Interaction

            - clickable: true
            - click_result: navigates
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "legacy")

        XCTAssertNotNil(result,
            "Legacy click_result alias 'navigates' should still validate")
    }

    func testParseValidatedAcceptsValidKeys() {
        let content = """
            ---
            name: valid-component
            ---

            # Valid Component

            ## Match Rules

            - has_dismiss_button: true
            - row_has_chevron: false
            - zone: content

            ## Interaction

            - clickable: true
            - click_target: first_dismiss_button
            - click_result: dismisses
            - back_after_click: false
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "valid"
        )

        XCTAssertNotNil(result,
            "parseValidated should accept definitions with all valid keys")
        XCTAssertEqual(result?.name, "valid-component")
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

    // MARK: - Label Rule Parsing

    func testLabelRuleDefaultsToTapTarget() {
        let content = """
            ---
            name: simple
            ---

            # Simple

            ## Interaction

            - clickable: true
            - click_target: first_text
            - click_result: pushes_screen
            - back_after_click: true
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.interaction.labelRule, .tapTarget,
            "label_rule should default to tap_target when not specified")
    }

    func testParsesLabelRuleFirstText() {
        let content = """
            ---
            name: tab-item
            ---

            # Tab Item

            ## Interaction

            - clickable: true
            - click_target: first_text
            - click_result: switches_context
            - back_after_click: false
            - label_rule: first_text
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.interaction.labelRule, .firstText)
    }

    func testParsesLabelRuleLongestText() {
        let content = """
            ---
            name: nav-bar
            ---

            # Nav Bar

            ## Interaction

            - clickable: true
            - click_target: first_navigation_element
            - click_result: dismisses
            - back_after_click: true
            - label_rule: longest_text
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.interaction.labelRule, .longestText)
    }

    // MARK: - Split Mode Parsing

    func testSplitModeDefaultsToNone() {
        let content = """
            ---
            name: simple
            ---

            # Simple

            ## Grouping

            - absorbs_same_row: true
            - absorbs_below_within_pt: 0
            - absorb_condition: any
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.grouping.splitMode, .none,
            "split_mode should default to none when not specified")
    }

    func testParsesSplitModePerItem() {
        let content = """
            ---
            name: tab-bar-item
            ---

            # Tab Bar Item

            ## Grouping

            - absorbs_same_row: false
            - absorbs_below_within_pt: 0
            - absorb_condition: any
            - split_mode: per_item
            """

        let definition = ComponentSkillParser.parse(
            content: content, fallbackName: "fallback"
        )

        XCTAssertEqual(definition.grouping.splitMode, .perItem)
    }
}
