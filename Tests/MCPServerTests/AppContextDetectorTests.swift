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

    func testDetectsIPhoneInUse() {
        let elements = [
            TapPoint(text: "iPhone in Use", tapX: 205, tapY: 400, confidence: 0.95),
            TapPoint(text: "Open iPhone to continue", tapX: 205, tapY: 450, confidence: 0.95),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        if case .lockOrSystemScreen(let desc) = diagnosis {
            XCTAssertEqual(desc, "iphone in use")
        } else {
            XCTFail("Expected lockOrSystemScreen, got \(diagnosis)")
        }
    }

    func testDetectsLockYourIPhone() {
        let elements = [
            TapPoint(text: "Lock your iPhone to connect.", tapX: 205, tapY: 400, confidence: 0.95),
        ]
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
        if case .lockOrSystemScreen(let desc) = diagnosis {
            XCTAssertEqual(desc, "lock your iphone")
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
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
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
        let diagnosis = AppContextDetector.diagnose(elements: elements, screenHeight: screenHeight)
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
