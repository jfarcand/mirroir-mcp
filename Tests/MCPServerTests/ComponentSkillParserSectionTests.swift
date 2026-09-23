// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentSkillParser section parsing: zones, booleans, dismiss buttons, patterns.
// ABOUTME: Covers precision rules, chevron modes, and unknown key validation.

import XCTest
@testable import mirroir_mcp

extension ComponentSkillParserTests {

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

    // MARK: - Unknown Key Validation

    func testParseValidatedRejectsUnknownMatchRuleKeys() {
        let content = """
            ---
            name: bad-component
            ---

            # Bad Component

            ## Match Rules

            - has_dismiss_icon: true
            - zone: content
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "bad"
        )

        XCTAssertNil(result,
            "parseValidated should reject definitions with unknown keys like 'has_dismiss_icon'")
    }

    func testParseValidatedRejectsUnknownInteractionKeys() {
        let content = """
            ---
            name: bad-interaction
            ---

            # Bad Interaction

            ## Interaction

            - clickable: true
            - auto_dismiss: true
            """

        let result = ComponentSkillParser.parseValidated(
            content: content, fallbackName: "bad"
        )

        XCTAssertNil(result,
            "parseValidated should reject unknown interaction keys")
    }
}
