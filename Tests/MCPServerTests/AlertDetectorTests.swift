/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Unit tests for AlertDetector: iOS system alert detection and dismiss target selection.
// ABOUTME: Verifies detection of permission prompts, rating dialogs, and rejection of normal screens.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class AlertDetectorTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeElements(_ texts: [String], startY: Double = 300) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 60, confidence: 0.95)
        }
    }

    // MARK: - Permission Prompt Detection

    func testDetectsLocationPermissionPrompt() {
        let elements = makeElements([
            "\"Maps\" would like to use your location",
            "Allow Once",
            "Allow While Using App",
            "Don't Allow",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert, "Should detect location permission prompt")
        XCTAssertEqual(alert?.dismissTarget.text, "Don't Allow",
            "Should pick most conservative dismiss target")
    }

    func testDetectsTrackingConsentDialog() {
        let elements = makeElements([
            "Allow \"App\" to track your activity?",
            "Ask App Not to Track",
            "Allow",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert, "Should detect tracking consent dialog")
        XCTAssertEqual(alert?.dismissTarget.text, "Ask App Not to Track",
            "Should prefer 'Ask App Not to Track' over 'Allow'")
    }

    func testDetectsNotificationPermissionPrompt() {
        let elements = makeElements([
            "\"App\" would like to send you notifications",
            "Allow",
            "Don't Allow",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert, "Should detect notification permission prompt")
        XCTAssertEqual(alert?.dismissTarget.text, "Don't Allow")
    }

    // MARK: - Rating Dialog Detection

    func testDetectsRatingDialog() {
        let elements = makeElements([
            "Enjoying the app?",
            "Not Now",
            "OK",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert, "Should detect rating dialog")
        XCTAssertEqual(alert?.dismissTarget.text, "Not Now",
            "Should prefer 'Not Now' over 'OK'")
    }

    // MARK: - Two Button Alerts

    func testDetectsSimpleCancelOKAlert() {
        let elements = makeElements([
            "Something happened",
            "Cancel",
            "OK",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert, "Should detect 2-button alert with Cancel and OK")
        XCTAssertEqual(alert?.dismissTarget.text, "Cancel",
            "Should prefer 'Cancel' over 'OK'")
    }

    // MARK: - False Positive Rejection

    func testRejectsNormalScreenWithManyElements() {
        // A normal Settings screen has many elements — should not be detected as alert
        let elements = makeElements([
            "Settings", "General", "Privacy", "About", "Display",
            "Sounds", "Notifications", "Battery", "Storage", "Accessibility",
            "OK",  // Having "OK" on a normal screen should not trigger detection
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNil(alert, "Normal screen with many elements should not be detected as alert")
    }

    func testRejectsScreenWithSingleIndicator() {
        // A screen with just one matching button and no title pattern
        let elements = makeElements([
            "Settings", "General", "Privacy",
            "Cancel",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNil(alert,
            "Screen with only one indicator and no title pattern should not trigger alert")
    }

    func testRejectsEmptyElements() {
        let alert = AlertDetector.detectAlert(elements: [])
        XCTAssertNil(alert, "Empty element list should not trigger alert")
    }

    func testRejectsSingleElement() {
        let elements = makeElements(["OK"])
        let alert = AlertDetector.detectAlert(elements: elements)
        XCTAssertNil(alert, "Single element should not trigger alert")
    }

    // MARK: - Dismiss Priority

    func testDismissPriorityOrderIsConservative() {
        // Verify the ordering: Don't Allow should always be preferred over Allow
        let elements = makeElements([
            "Allow access?",
            "Allow",
            "Don't Allow",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.dismissTarget.text, "Don't Allow",
            "Don't Allow (priority 0) should beat Allow (priority 9)")
    }

    func testNotNowBeatsOK() {
        let elements = makeElements([
            "Rate this app?",
            "OK",
            "Not Now",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.dismissTarget.text, "Not Now",
            "Not Now (priority 2) should beat OK (priority 8)")
    }

    // MARK: - Alert Type Classification

    func testTitlePatternSetsPermissionType() {
        let elements = makeElements([
            "App would like to use your camera",
            "Don't Allow",
            "OK",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.alertType, "permission/tracking dialog")
    }

    func testNoTitlePatternSetsSystemAlertType() {
        let elements = makeElements([
            "Something went wrong",
            "Cancel",
            "Dismiss",
        ])

        let alert = AlertDetector.detectAlert(elements: elements)

        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.alertType, "system alert")
    }
}
