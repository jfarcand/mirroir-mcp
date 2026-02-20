// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for NavigationHintDetector back-button detection and hint generation.
// ABOUTME: Validates detection in nav bar zone, bottom toolbar zone, and absence when no chevron.

import Testing
@testable import HelperLib

@Suite("NavigationHintDetector")
struct NavigationHintDetectorTests {

    private let windowHeight: Double = 900.0

    private func makeTapPoint(_ text: String, x: Double = 100, y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    @Test("detects back chevron in nav bar zone")
    func backChevronInNavBar() {
        let elements = [
            makeTapPoint("<", x: 30, y: 80),
            makeTapPoint("Settings", x: 200, y: 80),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1)
        #expect(hints[0].contains("press_key"))
        #expect(hints[0].contains("command"))
    }

    @Test("detects back chevron in bottom toolbar zone")
    func backChevronInToolbar() {
        let elements = [
            makeTapPoint("<", x: 55, y: 840),
            makeTapPoint("apple.com", x: 200, y: 840),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1)
        #expect(hints[0].contains("press_key"))
    }

    @Test("no hint when no back chevron present")
    func noChevronNoHint() {
        let elements = [
            makeTapPoint("Settings", x: 200, y: 80),
            makeTapPoint("General", x: 200, y: 200),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.isEmpty)
    }

    @Test("no hint when chevron is in middle of screen")
    func chevronInMiddleNoHint() {
        let elements = [
            makeTapPoint("<", x: 100, y: 450),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.isEmpty, "Chevron in the middle of the screen is not a nav button")
    }

    @Test("produces only one hint even with chevrons in both zones")
    func chevronInBothZones() {
        let elements = [
            makeTapPoint("<", x: 30, y: 80),
            makeTapPoint("<", x: 55, y: 840),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1, "Should produce a single back navigation hint, not duplicates")
    }

    @Test("detects alternative chevron characters")
    func alternativeChevronCharacters() {
        let elements = [
            makeTapPoint("‹", x: 30, y: 80),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1, "Should detect single guillemet as back chevron")
    }

    @Test("ignores chevron with surrounding text")
    func chevronWithSurroundingText() {
        let elements = [
            makeTapPoint("< Back", x: 60, y: 80),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.isEmpty, "\"< Back\" is not a bare chevron — OCR typically splits them")
    }
}
