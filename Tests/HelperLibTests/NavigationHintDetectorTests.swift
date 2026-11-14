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

    @Test("detects back chevron in nav bar zone (mobile)")
    func backChevronInNavBar() {
        let elements = [
            makeTapPoint("<", x: 30, y: 80),
            makeTapPoint("Settings", x: 200, y: 80),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1)
        #expect(hints[0].contains("tap it to go back"))
    }

    @Test("detects back chevron in bottom toolbar zone (mobile)")
    func backChevronInToolbar() {
        let elements = [
            makeTapPoint("<", x: 55, y: 840),
            makeTapPoint("apple.com", x: 200, y: 840),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1)
        #expect(hints[0].contains("tap it to go back"))
    }

    @Test("desktop mode suggests press_key for back navigation")
    func backChevronDesktopMode() {
        let elements = [
            makeTapPoint("<", x: 30, y: 80),
            makeTapPoint("Settings", x: 200, y: 80),
        ]
        let hints = NavigationHintDetector.detect(elements: elements, windowHeight: windowHeight, isMobile: false)
        #expect(hints.count == 1)
        #expect(hints[0].contains("press_key"))
        #expect(hints[0].contains("command"))
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

    @Test("emits tab bar hint from icon-only cluster in bottom band")
    func tabBarHintFromIconCluster() {
        // Icon-only tab bar (Instagram-style): no OCR text labels at all,
        // only detected icon positions in the bottom band.
        let iconPoints = [
            makeTapPoint("", x: 41, y: 846),
            makeTapPoint("", x: 205, y: 846),
            makeTapPoint("", x: 369, y: 846),
        ]
        let hints = NavigationHintDetector.detect(
            elements: [], iconPoints: iconPoints, windowHeight: windowHeight)
        #expect(hints.count == 1)
        #expect(hints[0].hasPrefix(NavigationHintDetector.tabBarHintPrefix),
            "Three bottom-band icon points should emit a tab-bar hint")
    }

    @Test("no tab bar hint below three bottom-band points")
    func noHintBelowThreeBandPoints() {
        let iconPoints = [
            makeTapPoint("", x: 41, y: 846),
            makeTapPoint("", x: 205, y: 846),
        ]
        let hints = NavigationHintDetector.detect(
            elements: [], iconPoints: iconPoints, windowHeight: windowHeight)
        #expect(hints.isEmpty, "Two band points are below the tab-bar threshold")
    }

    @Test("labeled tab bar in the tab-bar band emits hint")
    func labeledTabBarEmitsHint() {
        let elements = [
            makeTapPoint("Home", x: 41, y: 850),
            makeTapPoint("Search", x: 205, y: 850),
            makeTapPoint("Profile", x: 369, y: 850),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight)
        #expect(hints.count == 1)
        #expect(hints[0].hasPrefix(NavigationHintDetector.tabBarHintPrefix),
            "Three short labels in the tab-bar band should emit a tab-bar hint")
    }

    @Test("list rows above the tab-bar band are not tab-bar evidence")
    func listRowsAboveBandEmitNoHint() {
        // Settings-style chevron-less list scrolled near the bottom: rows at
        // y=780/840/898 on a 900-pt window. Only two fall inside the bottom-12%
        // tab-bar band (>=792), so no tab-bar hint fires — screen classification
        // for list screens stays unchanged.
        let elements = [
            makeTapPoint("Notifications", y: 780),
            makeTapPoint("General", y: 840),
            makeTapPoint("Privacy", y: 898),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight)
        #expect(hints.isEmpty,
            "Rows above the tab-bar band must not count toward the hint")
    }

    @Test("back-navigation text is recognized in lone and labeled forms")
    func backNavigationTextRecognized() {
        #expect(NavigationHintDetector.isBackNavigationText("<"))
        #expect(NavigationHintDetector.isBackNavigationText(" ‹ "))
        #expect(NavigationHintDetector.isBackNavigationText("< Back"))
        #expect(NavigationHintDetector.isBackNavigationText("‹ Retour"))
        #expect(!NavigationHintDetector.isBackNavigationText("Back"))
        #expect(!NavigationHintDetector.isBackNavigationText("<html>"),
            "A chevron glued to following text is not a back button label")
        #expect(!NavigationHintDetector.isBackNavigationText("Réglages"))
    }

    @Test("sentence-like band text does not count as a tab label")
    func multiWordBandContentEmitsNoHint() {
        // Scrolled feed captions and action-bar sentences land in the band on
        // pushed screens; tab items are 1-2 words, so these must not fire the hint.
        let elements = [
            makeTapPoint("Amazing sunset over the bridge", y: 850),
            makeTapPoint("Nouveau post de Marie", y: 860),
            makeTapPoint("Story du jour", y: 880),
        ]
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight)
        #expect(hints.isEmpty,
            "Multi-word band text is content, not tab-bar evidence")
    }

    @Test("desktop window's bottom row is not a tab bar")
    func desktopBottomRowIsNotATabBar() {
        // Calculator's last row of keys sits where an iOS tab bar would.
        let elements = [
            makeTapPoint("0", x: 60, y: 860),
            makeTapPoint(",", x: 180, y: 860),
            makeTapPoint("=", x: 240, y: 860),
        ]
        let icons = [TapPoint(text: "", tapX: 120, tapY: 860, confidence: 1.0)]
        let hints = NavigationHintDetector.detect(
            elements: elements, iconPoints: icons,
            windowHeight: windowHeight, isMobile: false)
        #expect(hints.isEmpty, "A tab bar is iOS chrome; a Mac window gets no tab-bar hint")
    }

}
