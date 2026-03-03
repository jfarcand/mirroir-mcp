// ABOUTME: Tests for ExplorerUtilities.verifyAppContext recovery flow using mock test doubles.
// ABOUTME: Validates ok/recovered/failed outcomes when explorer escapes the target app.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class AppContextRecoveryTests: XCTestCase {

    let screenHeight: Double = 890

    // MARK: - Normal Operation

    func testVerifyAppContextReturnsOkForNormalScreen() {
        // An in-app screen with a back chevron — should return .ok immediately
        let elements = [
            TapPoint(text: "<", tapX: 46, tapY: 60, confidence: 0.9),
            TapPoint(text: "General", tapX: 205, tapY: 130, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 200, confidence: 0.95),
        ]
        let describer = MockExplorerDescriber(screens: [])
        let input = MockExplorerInput()

        let result = ExplorerUtilities.verifyAppContext(
            elements: elements, screenHeight: screenHeight,
            appName: "Settings", input: input, describer: describer
        )

        if case .ok = result {
            // pass — no launchApp call, no OCR call
            XCTAssertEqual(input.taps.count, 0, "Should not tap anything on ok")
        } else {
            XCTFail("Expected .ok, got \(result)")
        }
    }

    // MARK: - Recovery from Home Screen

    func testVerifyAppContextRecoversFromHomeScreen() {
        // First OCR (main screen) shows home screen elements (passed as input to verifyAppContext)
        // After launchApp + waitForDismissal, the describer returns an in-app screen
        let appScreen = ScreenDescriber.DescribeResult(
            elements: [
                TapPoint(text: "<", tapX: 46, tapY: 60, confidence: 0.9),
                TapPoint(text: "Santé", tapX: 205, tapY: 130, confidence: 0.95),
            ],
            screenshotBase64: "recovered"
        )

        // SpotlightDetector.waitForDismissal polls describer — first few may still show Spotlight,
        // but our mock just returns the app screen on first call
        let describer = MockExplorerDescriber(screens: [appScreen])
        let input = MockExplorerInput()

        let homeElements = makeHomeScreenGrid()

        let result = ExplorerUtilities.verifyAppContext(
            elements: homeElements, screenHeight: screenHeight,
            appName: "Santé", input: input, describer: describer
        )

        if case .recovered = result {
            // pass
        } else {
            XCTFail("Expected .recovered, got \(result)")
        }
    }

    func testVerifyAppContextFailsWhenRecoveryUnsuccessful() {
        // After relaunch, we still see the home screen (recovery failed)
        let stillHomeScreen = ScreenDescriber.DescribeResult(
            elements: makeHomeScreenGrid(),
            screenshotBase64: "stillhome"
        )

        // SpotlightDetector.waitForDismissal will poll up to 5 times — all return home screen
        let describer = MockExplorerDescriber(screens: Array(repeating: stillHomeScreen, count: 6))
        let input = MockExplorerInput()

        let homeElements = makeHomeScreenGrid()

        let result = ExplorerUtilities.verifyAppContext(
            elements: homeElements, screenHeight: screenHeight,
            appName: "Santé", input: input, describer: describer
        )

        if case .failed(let reason) = result {
            XCTAssertTrue(reason.contains("home screen"), "Reason should mention home screen: \(reason)")
        } else {
            XCTFail("Expected .failed, got \(result)")
        }
    }

    // MARK: - Recovery from System Screen

    func testVerifyAppContextRecoversFromSystemScreen() {
        // System screen detected, then recovery succeeds
        let appScreen = ScreenDescriber.DescribeResult(
            elements: [
                TapPoint(text: "<", tapX: 46, tapY: 60, confidence: 0.9),
                TapPoint(text: "Health", tapX: 205, tapY: 130, confidence: 0.95),
            ],
            screenshotBase64: "recovered"
        )

        let describer = MockExplorerDescriber(screens: [appScreen])
        let input = MockExplorerInput()

        let systemElements = [
            TapPoint(text: "iPhone in Use", tapX: 205, tapY: 400, confidence: 0.95),
            TapPoint(text: "Open iPhone to continue", tapX: 205, tapY: 450, confidence: 0.95),
        ]

        let result = ExplorerUtilities.verifyAppContext(
            elements: systemElements, screenHeight: screenHeight,
            appName: "Health", input: input, describer: describer
        )

        if case .recovered = result {
            // pass
        } else {
            XCTFail("Expected .recovered, got \(result)")
        }
    }

    func testVerifyAppContextFailsFromSystemScreenWhenRecoveryFails() {
        // System screen detected, recovery still shows system screen
        let stillSystemScreen = ScreenDescriber.DescribeResult(
            elements: [
                TapPoint(text: "Lock your iPhone to connect.", tapX: 205, tapY: 400, confidence: 0.95),
            ],
            screenshotBase64: "stillsystem"
        )

        let describer = MockExplorerDescriber(screens: Array(repeating: stillSystemScreen, count: 6))
        let input = MockExplorerInput()

        let systemElements = [
            TapPoint(text: "iPhone in Use", tapX: 205, tapY: 400, confidence: 0.95),
        ]

        let result = ExplorerUtilities.verifyAppContext(
            elements: systemElements, screenHeight: screenHeight,
            appName: "Health", input: input, describer: describer
        )

        if case .failed(let reason) = result {
            XCTAssertTrue(reason.contains("system screen"), "Reason should mention system screen: \(reason)")
        } else {
            XCTFail("Expected .failed, got \(result)")
        }
    }

    // MARK: - Helpers

    /// Create a realistic home screen grid with enough elements and Y-bands to trigger detection.
    /// Uses 4-column X positions matching real iOS home screen layout.
    private func makeHomeScreenGrid() -> [TapPoint] {
        let appNames = [
            "Messages", "Calendar", "Photos", "Camera",
            "Weather", "Clock", "Maps", "Notes",
            "Reminders", "Stocks", "News", "Health",
        ]
        let columnXPositions = [70.0, 162.0, 255.0, 348.0]
        var elements: [TapPoint] = []
        for (i, name) in appNames.enumerated() {
            let row = i / 4
            let col = i % 4
            let x = columnXPositions[col]
            let y = Double(row) * 100 + 200
            elements.append(TapPoint(text: name, tapX: x, tapY: y, confidence: 0.95))
        }
        return elements
    }
}
