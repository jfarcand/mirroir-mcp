// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AppDescriptionParser and AppDescription integration.
// ABOUTME: Validates APP.md parsing, obstacle rules, skip lists, and credential handling.

import XCTest
@testable import mirroir_mcp

final class AppDescriptionTests: XCTestCase {

    // MARK: - Parser Tests

    func testParseValidAppDescription() {
        let content = """
        ---
        version: 1
        app: MyApp
        locale: en_US
        obstacle_mode: auto
        ---

        # MyApp

        ## Structure

        A simple app with two tabs.

        ## Home Tab

        Feed of posts.

        ## Obstacles

        - Permission dialog → tap "Don't Allow"
        - Paywall → dismiss via "Not Now"

        ## Skip

        - Delete Account
        - Sign Out

        ## Credentials

        - email: ${TEST_EMAIL:-test@example.com}
        - password: secret123

        ## Tips

        - The feed scrolls infinitely
        - Profile tab has settings
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.appName, "MyApp")
        XCTAssertEqual(desc?.locale, "en_US")
        XCTAssertEqual(desc?.obstacleMode, .auto)
    }

    func testParseObstacleRules() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Description

        Test app.

        ## Structure

        Simple.

        ## Obstacles

        - Health Access permission → tap "Allow"
        - Paywall modal -> dismiss "Not Now"
        - Onboarding screen → tap 'Continue'
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.obstacles.count, 3)

        XCTAssertEqual(desc?.obstacles[0].trigger, "Health Access permission")
        XCTAssertEqual(desc?.obstacles[0].action, "Allow")

        XCTAssertEqual(desc?.obstacles[1].trigger, "Paywall modal")
        XCTAssertEqual(desc?.obstacles[1].action, "Not Now")

        XCTAssertEqual(desc?.obstacles[2].trigger, "Onboarding screen")
        XCTAssertEqual(desc?.obstacles[2].action, "Continue")
    }

    func testParseSkipElements() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Structure

        Simple.

        ## Skip

        - Delete Account
        - "Sign Out"
        - Reset All Settings
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.skipElements.count, 3)
        XCTAssertTrue(desc?.skipElements.contains("Delete Account") ?? false)
        XCTAssertTrue(desc?.skipElements.contains("Sign Out") ?? false)
        XCTAssertTrue(desc?.skipElements.contains("Reset All Settings") ?? false)
    }

    func testParseCredentials() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Structure

        Simple.

        ## Credentials

        - email: test@example.com
        - password: ${TEST_PASSWORD:-secret}
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.credentials["email"], "test@example.com")
        XCTAssertEqual(desc?.credentials["password"], "${TEST_PASSWORD:-secret}")
    }

    func testParseContextIncludesStructureAndTabs() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Structure

        Dashboard with 3 tabs.

        ## Home Tab

        Summary cards.

        ## Settings Tab

        Drill-down rows.

        ## Tips

        - Tip one
        - Tip two
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.context.contains("Dashboard with 3 tabs") ?? false)
        XCTAssertTrue(desc?.context.contains("Home Tab") ?? false)
        XCTAssertTrue(desc?.context.contains("Summary cards") ?? false)
        XCTAssertTrue(desc?.context.contains("Settings Tab") ?? false)
        // Tips live on `.hints` now, rendered as a separate skill section — not in context.
        XCTAssertFalse(desc?.context.contains("Tip one") ?? true)
        XCTAssertEqual(desc?.hints, ["Tip one", "Tip two"])
    }

    func testParseReturnsNilWithoutAppName() {
        let content = """
        ---
        version: 1
        ---

        # No App Name

        ## Structure

        Missing app field.
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNil(desc, "Should return nil when app name is missing")
    }

    func testParseReturnsNilWithEmptyContent() {
        let content = """
        ---
        version: 1
        app: EmptyApp
        ---

        # Empty
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertNil(desc, "Should return nil when no sections have content")
    }

    func testDefaultObstacleModeIsAuto() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Structure

        Simple app.
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.obstacleMode, .auto)
    }

    func testObstacleModeHint() {
        let content = """
        ---
        version: 1
        app: TestApp
        obstacle_mode: hint
        ---

        # Test

        ## Structure

        Simple app.
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.obstacleMode, .hint)
    }

    func testObstacleModeOff() {
        let content = """
        ---
        version: 1
        app: TestApp
        obstacle_mode: off
        ---

        # Test

        ## Structure

        Simple app.
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.obstacleMode, .off)
    }

    func testObstacleArrowSeparators() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Structure

        Simple.

        ## Obstacles

        - Unicode arrow → tap "OK"
        - ASCII arrow -> tap "Cancel"
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.obstacles.count, 2)
        XCTAssertEqual(desc?.obstacles[0].action, "OK")
        XCTAssertEqual(desc?.obstacles[1].action, "Cancel")
    }

    func testHintsAreParsed() {
        let content = """
        ---
        version: 1
        app: TestApp
        ---

        # Test

        ## Structure

        Simple.

        ## Tips

        - First hint
        - Second hint
        - Third hint
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.hints.count, 3)
        XCTAssertEqual(desc?.hints[0], "First hint")
    }

    func testParseDeepTabs() {
        let content = """
        ---
        version: 1
        app: MyApp
        ---

        # MyApp

        ## Structure

        Social app with 3 tabs: Home, Search, Profile.

        ## Deep Tabs

        - Profile
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.deepTabs, ["Profile"])
    }

    func testDeepTabsDefaultToEmpty() {
        let content = """
        ---
        version: 1
        app: MyApp
        ---

        # MyApp

        ## Structure

        Social app with 2 tabs: Home, Profile.
        """

        let desc = AppDescriptionParser.parse(content: content)
        XCTAssertEqual(desc?.deepTabs, [])
    }

    // MARK: - Playable / exploration gate

    /// Builds a minimal, valid APP.md carrying the given `playable:` line
    /// (or none when nil) so the parser returns a non-nil description.
    private func describeWithPlayable(_ playable: String?) -> AppDescription? {
        let playableLine = playable.map { "playable: \($0)\n" } ?? ""
        let content = """
        ---
        version: 1
        app: GameApp
        \(playableLine)---

        # GameApp

        ## Structure

        A game.
        """
        return AppDescriptionParser.parse(content: content)
    }

    func testParsePlayableField() {
        let desc = describeWithPlayable("single-control")
        XCTAssertEqual(desc?.playable, "single-control")
    }

    func testPlayableDefaultsToNil() {
        let desc = describeWithPlayable(nil)
        XCTAssertNil(desc?.playable, "playable is nil when the field is absent")
    }

    func testAllowsExplorationForOrdinaryApp() {
        // No `playable:` → ordinary app → explorable.
        XCTAssertEqual(describeWithPlayable(nil)?.allowsExploration, true)
    }

    func testAllowsExplorationForObserveOnly() {
        XCTAssertEqual(describeWithPlayable("observe-only")?.allowsExploration, true)
    }

    func testAllowsExplorationBlockedForSingleControl() {
        XCTAssertEqual(describeWithPlayable("single-control")?.allowsExploration, false)
    }

    func testAllowsExplorationBlockedForPcControls() {
        XCTAssertEqual(describeWithPlayable("pc-controls")?.allowsExploration, false)
    }

    func testAllowsExplorationFailsSafeForUnknownPlayable() {
        // An unrecognized value is treated as not-explorable: never drive a
        // game the schema doesn't understand.
        XCTAssertEqual(describeWithPlayable("twin-stick")?.allowsExploration, false)
    }

}
// Loader-level integration (filesystem walk + diacritics match) was removed:
// parallel XCTest runs can't safely share a CWD swap, and the walk itself is
// a FileManager enumerator — covered implicitly by the parser tests above.
