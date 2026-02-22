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

    // MARK: - HintConfig tests

    @Test("custom top zone fraction widens detection area")
    func customTopZoneFraction() {
        let config = NavigationHintDetector.HintConfig(topZoneFraction: 0.5)
        let elements = [
            makeTapPoint("<", x: 30, y: 400),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight, config: config
        )
        #expect(hints.count == 1, "y=400 is within 50% top zone of 900px window")
    }

    @Test("custom bottom zone fraction widens detection area")
    func customBottomZoneFraction() {
        let config = NavigationHintDetector.HintConfig(bottomZoneFraction: 0.5)
        let elements = [
            makeTapPoint("<", x: 30, y: 500),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight, config: config
        )
        #expect(hints.count == 1, "y=500 is within bottom zone starting at 50% of 900px")
    }

    @Test("custom chevron patterns detect non-default characters")
    func customChevronPatterns() {
        let config = NavigationHintDetector.HintConfig(
            backChevronPatterns: ["←", "BACK"]
        )
        let elements = [
            makeTapPoint("←", x: 30, y: 80),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight, config: config
        )
        #expect(hints.count == 1, "Custom pattern ← should be detected")
    }

    @Test("custom patterns exclude default chevron")
    func customPatternsExcludeDefault() {
        let config = NavigationHintDetector.HintConfig(
            backChevronPatterns: ["←"]
        )
        let elements = [
            makeTapPoint("<", x: 30, y: 80),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight, config: config
        )
        #expect(hints.isEmpty, "Default < should not match when custom patterns replace it")
    }

    @Test("default HintConfig matches original behavior")
    func defaultConfigMatchesOriginal() {
        let config = NavigationHintDetector.HintConfig()
        #expect(config.topZoneFraction == 0.15)
        #expect(config.bottomZoneFraction == 0.85)
        #expect(config.backChevronPatterns == ["<", "‹", "〈"])
    }
}
