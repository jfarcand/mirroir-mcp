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
// ABOUTME: Integration tests for interactive FakeMirroring tap → navigation flows.
// ABOUTME: Validates that tapping elements in FakeMirroring triggers scenario transitions detected by OCR.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Tests that tapping rendered elements in FakeMirroring causes visible screen transitions.
/// Validates the full pipeline: OCR → compute coordinates → tap → verify new screen content.
///
/// These tests exercise real CGEvent taps against FakeMirroring's mouseUp hit detection,
/// proving that the input simulation and OCR pipeline produce correct, actionable coordinates.
final class TapNavigationTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var input: InputSimulation!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        let capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
        input = InputSimulation(bridge: bridge)

        // Start every test on Settings scenario
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(500_000)
    }

    override func tearDown() {
        // Restore Settings scenario for other test classes
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    // MARK: - Row Tap Navigation

    /// Tap "General" row on Settings → should navigate to Detail screen.
    /// Verifies by checking for "Keyboard" which exists only on Detail, not Settings.
    func testTapGeneralNavigatesToDetail() throws {
        try tapAndVerifyNavigation(
            tapLabel: "General",
            expectedElement: "Keyboard",
            description: "Settings → General → Detail"
        )
    }

    /// Drill Settings → General → About and verify the leaf screen with the
    /// "Model Number" detail. Exercises the same multi-hop tap-and-verify
    /// pipeline as the legacy "Settings → About → Detail (Back)" path, against
    /// the realistic Settings hierarchy (About lives under General, not root).
    func testTapAboutNavigatesToDetailWithBack() throws {
        try tapAndVerifyNavigation(
            tapLabel: "General",
            expectedElement: "About",
            description: "Settings → General"
        )
        try tapAndVerifyNavigation(
            tapLabel: "About",
            expectedElement: "Model Number",
            description: "General → About"
        )
    }

    // MARK: - Back Chevron Navigation

    /// Drill into Settings → General (a screen with a back chevron) and tap
    /// the "<" chevron to return to Settings. Verifies that OCR can locate
    /// the chevron glyph and that a tap there triggers the parent navigation.
    func testBackChevronReturnsToSettings() throws {
        // Navigate Settings → General through a row tap so we land on a
        // screen with back: main (renders the back chevron).
        try tapAndVerifyNavigation(
            tapLabel: "General",
            expectedElement: "About",
            description: "Settings → General"
        )

        // Find and tap the back chevron rendered by drawBackChevron().
        // FakeMirroring renders "< Back" (iOS-realistic). Vision OCR may
        // segment it as "<", "Back", "< Back", or just "Back" — accept any
        // of those anchors. The handleAppPackTap back-zone covers the full
        // top-left strip (0..80, 0..200) so any of these tap centers lands
        // in the navigate-back hitbox.
        let beforeScreen = try describeOrFail()
        let chevronAnchors: Set<String> = ["<", "‹", "〈", "く"]
        guard let chevron = beforeScreen.elements.first(where: { element in
            chevronAnchors.contains(element.text)
                || element.text.lowercased().contains("back")
        }) else {
            throw IntegrationTestError.elementNotFound("< Back (back chevron)")
        }

        let tapError = input.tap(x: chevron.tapX, y: chevron.tapY)
        XCTAssertNil(tapError, "Tap on back chevron should succeed: \(tapError ?? "")")
        usleep(800_000)

        // After the back tap we should be back on Settings root.
        let afterScreen = try describeOrFail()
        let afterTexts = afterScreen.elements.map { $0.text.lowercased() }
        XCTAssertTrue(afterTexts.contains("settings"),
                      "After back tap, should be on Settings. Found: \(afterTexts)")
    }

    // MARK: - Button Tap

    /// On Login screen, tap "Log In" button → should navigate to Feed.
    /// Verifies by checking for "johndoe" which exists only on Feed, not Login.
    func testTapLoginButtonNavigatesToFeed() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Login")
        usleep(500_000)

        try tapAndVerifyNavigation(
            tapLabel: "Log In",
            expectedElement: "johndoe",
            description: "Login → Log In → Feed"
        )
    }

    // MARK: - Card Tap

    /// On the Health summary screen, tap the "Steps" row → should navigate
    /// to the Steps detail screen. Verifies by checking for "Daily Average"
    /// which exists only on the detail screen, not the summary.
    func testTapHealthCardNavigatesToDetail() throws {
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Health")
        usleep(500_000)

        try tapAndVerifyNavigation(
            tapLabel: "Steps",
            expectedElement: "Daily Average",
            description: "Health → Steps → Detail"
        )
    }

    // MARK: - Helpers

    /// OCR the current screen, find the element matching `tapLabel`, tap it,
    /// then OCR again and verify that `expectedElement` (unique to the destination screen)
    /// appears in the OCR results.
    ///
    /// Retries the OCR/tap cycle up to `maxAttempts` times when the post-tap
    /// screen still doesn't contain `expectedElement`. CI runners
    /// occasionally drop the first CGEvent dispatch (window focus race after
    /// a Scenario menu trigger); re-OCRing and re-tapping recovers without
    /// masking a genuine navigation bug — by the second attempt the window
    /// is keyed and rendering is stable.
    private func tapAndVerifyNavigation(
        tapLabel: String,
        expectedElement: String,
        description: String,
        maxAttempts: Int = 2
    ) throws {
        var lastFoundTexts: [String] = []
        var diagnosticTrail: [String] = []
        for attempt in 1...maxAttempts {
            let screen = try describeOrFail()
            guard let target = screen.elements.first(where: {
                $0.text.caseInsensitiveCompare(tapLabel) == .orderedSame
            }) else {
                throw IntegrationTestError.elementNotFound("\(tapLabel) (\(description))")
            }

            let windowInfo = bridge.getWindowInfo()
            let windowDesc = windowInfo.map {
                "window=(\(Int($0.position.x)),\(Int($0.position.y))) " +
                "size=\(Int($0.size.width))x\(Int($0.size.height))"
            } ?? "windowInfo=nil"

            let tapError = input.tap(x: target.tapX, y: target.tapY)
            XCTAssertNil(tapError, "Tap on '\(tapLabel)' should succeed: \(tapError ?? "")")
            usleep(800_000)

            let afterScreen = try describeOrFail()
            lastFoundTexts = afterScreen.elements.map { $0.text.lowercased() }
            diagnosticTrail.append(
                "attempt=\(attempt) target='\(tapLabel)' " +
                "ocr=(\(String(format: "%.1f", target.tapX)),\(String(format: "%.1f", target.tapY))) " +
                "confidence=\(String(format: "%.2f", target.confidence)) " +
                "\(windowDesc) tapError=\(tapError ?? "nil") " +
                "after=\(lastFoundTexts.count) elements"
            )
            if lastFoundTexts.contains(expectedElement.lowercased()) {
                return
            }
            if attempt < maxAttempts { usleep(500_000) }
        }
        XCTFail(
            "\(description): expected '\(expectedElement)' after \(maxAttempts) tap attempt(s). " +
            "Found: \(lastFoundTexts)\n" +
            "Diagnostics:\n  " + diagnosticTrail.joined(separator: "\n  ")
        )
    }

    private func describeOrFail() throws -> ScreenDescriber.DescribeResult {
        for attempt in 1...3 {
            if let result = describer.describe() { return result }
            if attempt < 3 { usleep(500_000) }
        }
        throw IntegrationTestError.describeReturnedNil
    }
}
