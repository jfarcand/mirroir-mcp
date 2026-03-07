// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ElementMatcher: exact, case-insensitive, and substring matching.
// ABOUTME: Covers match priorities, empty input, no-match cases, and visibility checks.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ElementMatcherTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeTapPoint(text: String, x: Double = 100.0, y: Double = 200.0) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - Exact Match

    func testExactMatch() {
        let elements = [makeTapPoint(text: "General"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "General")
        XCTAssertEqual(result?.strategy, .exact)
    }

    func testExactMatchPreferredOverCaseInsensitive() {
        let elements = [makeTapPoint(text: "general"), makeTapPoint(text: "General")]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "General")
        XCTAssertEqual(result?.strategy, .exact)
    }

    // MARK: - Case-Insensitive Match

    func testCaseInsensitiveMatch() {
        let elements = [makeTapPoint(text: "GENERAL"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "general", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "GENERAL")
        XCTAssertEqual(result?.strategy, .caseInsensitive)
    }

    // MARK: - Substring Match

    func testSubstringMatch() {
        let elements = [
            makeTapPoint(text: "General Settings"),
            makeTapPoint(text: "About")
        ]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "General Settings")
        XCTAssertEqual(result?.strategy, .substring)
    }

    func testReverseSubstringMatch() {
        let elements = [makeTapPoint(text: "Gen"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "Gen")
        XCTAssertEqual(result?.strategy, .substring)
    }

    func testSubstringCaseInsensitive() {
        let elements = [makeTapPoint(text: "GENERAL SETTINGS")]
        let result = ElementMatcher.findMatch(label: "general", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.strategy, .substring)
    }

    func testReverseSubstringRejectsShortFragments() {
        // "en" (2 chars) is too short to match "Settings" (8 chars, min = max(3, 4) = 4)
        let elements = [makeTapPoint(text: "en"), makeTapPoint(text: "in")]
        let result = ElementMatcher.findMatch(label: "Settings", in: elements)
        XCTAssertNil(result)
    }

    func testReverseSubstringRejectsSingleCharacter() {
        let elements = [makeTapPoint(text: "S"), makeTapPoint(text: ">")]
        let result = ElementMatcher.findMatch(label: "Settings", in: elements)
        XCTAssertNil(result)
    }

    func testReverseSubstringRequiresMinimumCoverage() {
        // "set" (3 chars) doesn't meet the minimum for "Settings" (8 chars, min = 4)
        let elements = [makeTapPoint(text: "set")]
        let result = ElementMatcher.findMatch(label: "Settings", in: elements)
        XCTAssertNil(result)
    }

    func testReverseSubstringAcceptsSufficientCoverage() {
        // "Sett" (4 chars) meets the minimum for "Settings" (8 chars, min = 4)
        let elements = [makeTapPoint(text: "Sett")]
        let result = ElementMatcher.findMatch(label: "Settings", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "Sett")
    }

    // MARK: - Diacritic-Insensitive Match

    func testDiacriticInsensitiveMatch() {
        let elements = [makeTapPoint(text: "Résumé")]
        let result = ElementMatcher.findMatch(label: "Resume", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "Résumé")
        XCTAssertEqual(result?.strategy, .diacriticInsensitive)
    }

    func testDiacriticInsensitiveMatchCafe() {
        let elements = [makeTapPoint(text: "café")]
        let result = ElementMatcher.findMatch(label: "cafe", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "café")
        XCTAssertEqual(result?.strategy, .diacriticInsensitive)
    }

    func testDiacriticInsensitiveMatchReversed() {
        let elements = [makeTapPoint(text: "Resume")]
        let result = ElementMatcher.findMatch(label: "Résumé", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.text, "Resume")
        XCTAssertEqual(result?.strategy, .diacriticInsensitive)
    }

    func testDiacriticInsensitiveRankedBelowCaseInsensitive() {
        // "RESUME" matches "Resume" via case-insensitive (priority 2),
        // "Résumé" would match "Resume" via diacritic-insensitive (priority 3)
        let elements = [makeTapPoint(text: "Résumé"), makeTapPoint(text: "RESUME")]
        let result = ElementMatcher.findMatch(label: "Resume", in: elements)
        XCTAssertNotNil(result)
        // Should prefer case-insensitive exact match over diacritic match
        XCTAssertEqual(result?.element.text, "RESUME")
        XCTAssertEqual(result?.strategy, .caseInsensitive)
    }

    func testDiacriticInsensitiveWithAccentedChars() {
        let elements = [makeTapPoint(text: "Réglages")]
        let result = ElementMatcher.findMatch(label: "Reglages", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.strategy, .diacriticInsensitive)
    }

    // MARK: - No Match

    func testNoMatch() {
        let elements = [makeTapPoint(text: "General"), makeTapPoint(text: "About")]
        let result = ElementMatcher.findMatch(label: "Privacy", in: elements)
        XCTAssertNil(result)
    }

    func testEmptyLabel() {
        let elements = [makeTapPoint(text: "General")]
        let result = ElementMatcher.findMatch(label: "", in: elements)
        XCTAssertNil(result)
    }

    func testEmptyElements() {
        let result = ElementMatcher.findMatch(label: "General", in: [])
        XCTAssertNil(result)
    }

    func testBothEmpty() {
        let result = ElementMatcher.findMatch(label: "", in: [])
        XCTAssertNil(result)
    }

    // MARK: - isVisible

    func testIsVisibleTrue() {
        let elements = [makeTapPoint(text: "General")]
        XCTAssertTrue(ElementMatcher.isVisible(label: "General", in: elements))
    }

    func testIsVisibleFalse() {
        let elements = [makeTapPoint(text: "General")]
        XCTAssertFalse(ElementMatcher.isVisible(label: "Privacy", in: elements))
    }

    func testIsVisibleCaseInsensitive() {
        let elements = [makeTapPoint(text: "general")]
        XCTAssertTrue(ElementMatcher.isVisible(label: "General", in: elements))
    }

    // MARK: - Coordinate Preservation

    func testMatchPreservesCoordinates() {
        let elements = [makeTapPoint(text: "General", x: 150.0, y: 300.0)]
        let result = ElementMatcher.findMatch(label: "General", in: elements)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.element.tapX, 150.0)
        XCTAssertEqual(result?.element.tapY, 300.0)
    }
}
