// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AppContextDetector: home screen grid detection, system screen pattern matching.
// ABOUTME: Validates that the detector correctly distinguishes in-app screens from escaped states.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class AppContextDetectorTests: XCTestCase {

    let screenHeight: Double = 890

    // MARK: - Home Screen Detection

    func testDetectsHomeScreenGrid() {
        // Simulate a home screen: 12 short labels in 4 Y-bands, no back chevron
        let elements = makeHomeScreenElements(rows: 4, columnsPerRow: 3, startY: 200)
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .homeScreen)
    }

    func testRejectsAppScreenWithBackChevron() {
        // Short labels present BUT a back chevron in the top zone → inside an app
        var elements = makeHomeScreenElements(rows: 4, columnsPerRow: 3, startY: 200)
        elements.append(TapPoint(text: "<", tapX: 46, tapY: 60, confidence: 0.9))
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp)
    }

    func testRejectsScreenWithFewCandidates() {
        // Only 5 short labels — below the minHomeScreenCandidates threshold
        let elements = makeHomeScreenElements(rows: 1, columnsPerRow: 5, startY: 300)
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp)
    }

    func testRejectsSingleYBand() {
        // 10 short labels all at the same Y — not a grid layout
        let elements = (0..<10).map { i in
            TapPoint(text: "App\(i)", tapX: Double(i) * 40 + 20, tapY: 400, confidence: 0.95)
        }
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp)
    }

    func testStatusBarElementsIgnored() {
        // Time and battery percentage in top 10% should be filtered out
        var elements = makeHomeScreenElements(rows: 3, columnsPerRow: 3, startY: 200)
        // Add status bar elements
        elements.append(TapPoint(text: "9:41", tapX: 205, tapY: 20, confidence: 0.95))
        elements.append(TapPoint(text: "85%", tapX: 370, tapY: 20, confidence: 0.95))
        // Still 9 candidates in 3 bands → triggers home screen (need 8+, 3+ bands)
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .homeScreen)
    }

    // MARK: - System Screen Detection

    /// The lock-screen fragments the skills checkout ships for an English phone.
    private static let englishLockScreen = ["slide to unlock", "enter passcode", "face id"]

    /// Diagnose with explicit tables, so the result does not depend on the
    /// Mac's language or on which pattern files this machine has.
    private func diagnoseSystem(
        _ elements: [TapPoint], lockScreen: [String] = englishLockScreen,
        interstitials: InterstitialPhrases = InterstitialFixtures.englishPhrases
    ) -> AppContextDiagnosis {
        AppContextDetector.diagnose(
            elements: elements, screenHeight: screenHeight,
            lockScreen: lockScreen, interstitials: interstitials)
    }

    /// iPhone Mirroring draws its "in use" words on the Mac, in the Mac's language.
    func testDetectsALocalizedInterstitialThroughTheMacsStrings() {
        let elements = [TapPoint(text: "iPhone en cours d’utilisation", tapX: 205, tapY: 400, confidence: 0.95)]
        XCTAssertEqual(diagnoseSystem(elements, interstitials: InterstitialFixtures.frenchCanadianPhrases),
                       .lockOrSystemScreen(description: "iPhone en cours d’utilisation"))
        XCTAssertEqual(diagnoseSystem(elements), .inApp, "an English Mac never draws the French words")
    }

    /// The iOS lock screen is drawn on the phone: its words are pattern data.
    func testLockScreenPhrasesComeFromTheGivenList() {
        let elements = [TapPoint(text: "Saisir le code", tapX: 205, tapY: 300, confidence: 0.95)]
        XCTAssertEqual(diagnoseSystem(elements, lockScreen: ["saisir le code"]),
                       .lockOrSystemScreen(description: "Saisir le code"))
        XCTAssertEqual(diagnoseSystem(elements), .inApp)
    }

    func testNoPhrasesMeansNoLockScreenMatch() {
        let elements = [TapPoint(text: "Enter Passcode", tapX: 205, tapY: 300, confidence: 0.95)]
        XCTAssertEqual(diagnoseSystem(elements, lockScreen: []), .inApp)
    }

    /// The camera notice is a different interruption: waiting, not a locked phone.
    func testCameraInUseIsNotTheLockInterstitial() {
        let elements = [TapPoint(text: "iPhone Camera in Use", tapX: 205, tapY: 400, confidence: 0.95)]
        XCTAssertEqual(diagnoseSystem(elements), .inApp)
    }

    func testDetectsIPhoneInUse() {
        let elements = [
            TapPoint(text: "iPhone in Use", tapX: 205, tapY: 400, confidence: 0.95),
            TapPoint(text: "Open iPhone to continue", tapX: 205, tapY: 450, confidence: 0.95),
        ]
        let diagnosis = diagnoseSystem(elements)
        if case .lockOrSystemScreen(let desc) = diagnosis {
            XCTAssertEqual(desc, "iPhone in Use", "the description is the screen's own words")
        } else {
            XCTFail("Expected lockOrSystemScreen, got \(diagnosis)")
        }
    }

    func testDetectsLockYourIPhone() {
        let elements = [
            TapPoint(text: "Lock your iPhone to connect.", tapX: 205, tapY: 400, confidence: 0.95),
        ]
        let diagnosis = diagnoseSystem(elements)
        if case .lockOrSystemScreen(let desc) = diagnosis {
            XCTAssertEqual(desc, "Lock your iPhone to connect.")
        } else {
            XCTFail("Expected lockOrSystemScreen, got \(diagnosis)")
        }
    }

    func testDetectsEnterPasscode() {
        let elements = [
            TapPoint(text: "Enter Passcode", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "1", tapX: 100, tapY: 500, confidence: 0.95),
            TapPoint(text: "2", tapX: 205, tapY: 500, confidence: 0.95),
            TapPoint(text: "3", tapX: 310, tapY: 500, confidence: 0.95),
        ]
        let diagnosis = diagnoseSystem(elements)
        if case .lockOrSystemScreen = diagnosis {
            // pass
        } else {
            XCTFail("Expected lockOrSystemScreen, got \(diagnosis)")
        }
    }

    func testSystemScreenIsCaseInsensitive() {
        let elements = [
            TapPoint(text: "IPHONE IN USE", tapX: 205, tapY: 400, confidence: 0.95),
        ]
        let diagnosis = diagnoseSystem(elements)
        if case .lockOrSystemScreen = diagnosis {
            // pass
        } else {
            XCTFail("Expected lockOrSystemScreen, got \(diagnosis)")
        }
    }

    // MARK: - False Positive Rejection

    func testNormalSettingsScreenIsInApp() {
        // A typical Settings screen has a back chevron and fewer short labels
        let elements = [
            TapPoint(text: "<", tapX: 46, tapY: 60, confidence: 0.9),
            TapPoint(text: "General", tapX: 205, tapY: 130, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 200, confidence: 0.95),
            TapPoint(text: "Software Update", tapX: 205, tapY: 280, confidence: 0.95),
            TapPoint(text: "AirDrop", tapX: 205, tapY: 360, confidence: 0.95),
            TapPoint(text: "AirPlay & Continuity", tapX: 205, tapY: 440, confidence: 0.95),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp)
    }

    func testAppWithShortTabBarLabelsIsInApp() {
        // A tab bar with short labels shouldn't trigger home screen detection
        // (< 8 candidates total)
        let elements = [
            TapPoint(text: "<", tapX: 46, tapY: 60, confidence: 0.9),
            TapPoint(text: "Summary", tapX: 205, tapY: 130, confidence: 0.95),
            TapPoint(text: "Health Details", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "Browse", tapX: 100, tapY: 850, confidence: 0.95),
            TapPoint(text: "Summary", tapX: 205, tapY: 850, confidence: 0.95),
            TapPoint(text: "Sharing", tapX: 310, tapY: 850, confidence: 0.95),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp)
    }

    func testEmptyElementsIsInApp() {
        // Not enough evidence to diagnose escape — default to in-app
        let diagnosis = AppContextDetector.diagnose(elements: [], screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp)
    }

    // MARK: - Time/Number Pattern Filtering

    func testIsTimeOrNumberPatternDetectsTime() {
        XCTAssertTrue(AppContextDetector.isTimeOrNumberPattern("9:41"))
        XCTAssertTrue(AppContextDetector.isTimeOrNumberPattern("12:00"))
    }

    func testIsTimeOrNumberPatternDetectsPercentage() {
        XCTAssertTrue(AppContextDetector.isTimeOrNumberPattern("85%"))
    }

    func testIsTimeOrNumberPatternDetectsBareNumber() {
        XCTAssertTrue(AppContextDetector.isTimeOrNumberPattern("42"))
    }

    func testIsTimeOrNumberPatternRejectsWords() {
        XCTAssertFalse(AppContextDetector.isTimeOrNumberPattern("Settings"))
        XCTAssertFalse(AppContextDetector.isTimeOrNumberPattern("Photos"))
    }

    // MARK: - Band Counting

    func testCountDistinctBandsMultipleBands() {
        let values = [200.0, 210.0, 350.0, 355.0, 500.0]
        XCTAssertEqual(AppContextDetector.countDistinctBands(values), 3)
    }

    func testCountDistinctBandsEmptyReturnsZero() {
        XCTAssertEqual(AppContextDetector.countDistinctBands([]), 0)
    }

    func testBackChevronDetectedAsIconInTopLeft() {
        // OCR sometimes detects "<" back chevron as "icon" via YOLO.
        // An icon in the top-left back button position should prevent
        // false positive home screen detection.
        var elements = makeHomeScreenElements(rows: 4, columnsPerRow: 3, startY: 200)
        elements.append(TapPoint(text: "icon", tapX: 47, tapY: 121, confidence: 0.9))
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp,
            "Icon in back button position should indicate in-app, not home screen")
    }

    func testIconNotInBackButtonPositionDoesNotSuppressHomeScreen() {
        // An icon far from the back button position should not prevent detection
        var elements = makeHomeScreenElements(rows: 4, columnsPerRow: 3, startY: 200)
        elements.append(TapPoint(text: "icon", tapX: 200, tapY: 121, confidence: 0.9))
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .homeScreen,
            "Icon not in back button position should not suppress home screen detection")
    }

    // MARK: - X-Column Grid Check

    func testRejectsAppRootWithScatteredXPositions() {
        // Santé-like root screen: many short labels, no back chevron, multiple Y-bands,
        // but X positions are scattered (left-aligned text, right-aligned times, tabs)
        // — NOT a regular 4-column grid.
        let elements = [
            TapPoint(text: "Résumé", tapX: 94, tapY: 176, confidence: 0.95),
            TapPoint(text: "Épinglés", tapX: 91, tapY: 227, confidence: 0.95),
            TapPoint(text: "Modifier", tapX: 342, tapY: 227, confidence: 0.95),
            TapPoint(text: "Activité", tapX: 84, tapY: 277, confidence: 0.95),
            TapPoint(text: "Bouger", tapX: 69, tapY: 335, confidence: 0.95),
            TapPoint(text: "1 cal", tapX: 65, tapY: 356, confidence: 0.95),
            TapPoint(text: "35 min", tapX: 80, tapY: 495, confidence: 0.95),
            TapPoint(text: "0,06 km", tapX: 89, tapY: 643, confidence: 0.95),
            TapPoint(text: "Pas", tapX: 68, tapY: 708, confidence: 0.95),
            TapPoint(text: "104 pas", tapX: 85, tapY: 783, confidence: 0.95),
            TapPoint(text: "Résumé", tapX: 82, tapY: 824, confidence: 0.95),
            TapPoint(text: "Partage", tapX: 170, tapY: 825, confidence: 0.95),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp, "App root with scattered X should not be detected as home screen")
    }

    // MARK: - Nav Bar Title Filter

    /// A chart screen with a centered nav-bar title should be detected as in-app.
    func testChartScreenWithNavBarTitleIsInApp() {
        let elements = [
            // Centered title in header zone
            TapPoint(text: "Activity", tapX: 205, tapY: 130, confidence: 0.95),
            // Chart day labels (short, grid-like)
            TapPoint(text: "Mon", tapX: 50, tapY: 350, confidence: 0.9),
            TapPoint(text: "Tue", tapX: 100, tapY: 350, confidence: 0.9),
            TapPoint(text: "Wed", tapX: 150, tapY: 350, confidence: 0.9),
            TapPoint(text: "Thu", tapX: 200, tapY: 350, confidence: 0.9),
            TapPoint(text: "Fri", tapX: 250, tapY: 350, confidence: 0.9),
            TapPoint(text: "Sat", tapX: 300, tapY: 350, confidence: 0.9),
            TapPoint(text: "Sun", tapX: 350, tapY: 350, confidence: 0.9),
            TapPoint(text: "Steps", tapX: 205, tapY: 500, confidence: 0.9),
            TapPoint(text: "Heart", tapX: 205, tapY: 600, confidence: 0.9),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp,
            "Chart screen with centered nav bar title should be detected as in-app")
    }

    // MARK: - Multi-Word Label Filter

    /// A screen with mostly multi-word labels should not be detected as home screen.
    func testMultiWordLabelsRejectHomeScreen() {
        let elements = [
            TapPoint(text: "Walking Distance", tapX: 70, tapY: 300, confidence: 0.9),
            TapPoint(text: "Heart Rate", tapX: 162, tapY: 300, confidence: 0.9),
            TapPoint(text: "Sleep Analysis", tapX: 255, tapY: 300, confidence: 0.9),
            TapPoint(text: "Blood Pressure", tapX: 70, tapY: 400, confidence: 0.9),
            TapPoint(text: "Body Weight", tapX: 162, tapY: 400, confidence: 0.9),
            TapPoint(text: "Respiratory Rate", tapX: 255, tapY: 400, confidence: 0.9),
            TapPoint(text: "Mental Health", tapX: 70, tapY: 500, confidence: 0.9),
            TapPoint(text: "Cycle Tracking", tapX: 162, tapY: 500, confidence: 0.9),
            TapPoint(text: "Hearing Levels", tapX: 255, tapY: 500, confidence: 0.9),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        XCTAssertEqual(diagnosis, .inApp,
            "Screen with >60% multi-word labels should not be classified as home screen")
    }

    // MARK: - Helpers

    /// Create a grid of home screen-like elements with short app-icon labels.
    /// Uses realistic 4-column X positions matching iOS home screen layout.
    private func makeHomeScreenElements(rows: Int, columnsPerRow: Int, startY: Double) -> [TapPoint] {
        let appNames = [
            "Messages", "Calendar", "Photos", "Camera", "Weather",
            "Clock", "Maps", "Notes", "Reminders", "Stocks",
            "News", "Health", "Wallet", "Settings", "Safari",
            "Music", "Podcasts", "TV", "Files", "Translate",
        ]
        // iOS home screen columns: ~70, ~162, ~255, ~348 (4 evenly spaced)
        let columnXPositions = [70.0, 162.0, 255.0, 348.0]
        var elements: [TapPoint] = []
        for row in 0..<rows {
            for col in 0..<columnsPerRow {
                let index = row * columnsPerRow + col
                let name = index < appNames.count ? appNames[index] : "App\(index)"
                let x = columnXPositions[col % columnXPositions.count]
                let y = startY + Double(row) * 100
                elements.append(TapPoint(text: name, tapX: x, tapY: y, confidence: 0.95))
            }
        }
        return elements
    }
}
