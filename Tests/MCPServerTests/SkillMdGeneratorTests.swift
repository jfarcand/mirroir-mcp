// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for SkillMdGenerator: SKILL.md document assembly.
// ABOUTME: Covers front matter, description paragraph, numbered steps, and name derivation.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class SkillMdGeneratorTests: XCTestCase {

    // MARK: - Single Screen

    func testGenerateWithSingleScreen() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
                    TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
                    TapPoint(text: "Privacy", tapX: 205, tapY: 400, confidence: 0.93),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "", screens: screens)

        // Front matter
        XCTAssertTrue(result.hasPrefix("---\n"), "Should start with YAML front matter")
        XCTAssertTrue(result.contains("app: Settings"))
        XCTAssertTrue(result.contains("tags: [generated]"))

        // Description paragraph
        XCTAssertTrue(result.contains("Explore the Settings app."))

        // Steps heading
        XCTAssertTrue(result.contains("## Steps"))

        // Numbered launch step
        XCTAssertTrue(result.contains("1. Launch **Settings**"))

        // Wait for landmark with "to appear" suffix
        XCTAssertTrue(result.contains("Wait for \"Settings\" to appear"))
    }

    // MARK: - Multiple Screens

    func testGenerateWithMultipleScreens() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
                    TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                    TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "General",
                screenshotBase64: "img1"
            ),
            ExploredScreen(
                index: 2,
                elements: [
                    TapPoint(text: "About", tapX: 205, tapY: 120, confidence: 0.96),
                    TapPoint(text: "iOS Version 18.2", tapX: 205, tapY: 300, confidence: 0.88),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "About",
                screenshotBase64: "img2"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "check software version", screens: screens)

        // Should have numbered steps
        XCTAssertTrue(result.contains("1. Launch **Settings**"))
        XCTAssertTrue(result.contains("Wait for \"Settings\" to appear"),
            "First screen should wait for landmark")
        XCTAssertTrue(result.contains("Tap \"General\""),
            "Second screen arrived via General")
        XCTAssertTrue(result.contains("Wait for \"General\" to appear"),
            "Second screen should wait for its landmark")
        XCTAssertTrue(result.contains("Tap \"About\""),
            "Third screen arrived via About")
        XCTAssertTrue(result.contains("Wait for \"About\" to appear"),
            "Third screen should wait for its landmark")

        // Description paragraph
        XCTAssertTrue(result.contains("Check software version in the Settings app."))
    }

    // MARK: - Goal Handling

    func testGenerateWithGoal() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "check version", screens: screens)

        XCTAssertTrue(result.contains("description: check version"),
            "Goal should appear in front matter description")
        XCTAssertTrue(result.contains("name: Check Version"),
            "Name should be title-cased goal")
    }

    func testGenerateWithoutGoal() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Notes", tapX: 205, tapY: 120, confidence: 0.98),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Notes", goal: "", screens: screens)

        XCTAssertTrue(result.contains("description: Explore Notes"),
            "Empty goal should produce default description")
        XCTAssertTrue(result.contains("name: Explore Notes"),
            "Empty goal should produce Explore-based title-case name")
    }

    // MARK: - Numbered Steps Format

    func testStepsAreNumbered() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "General",
                screenshotBase64: "img1"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "explore settings", screens: screens)

        XCTAssertTrue(result.contains("1. Launch **Settings**"),
            "Launch should be step 1")
        XCTAssertTrue(result.contains("2. Wait for \"Settings\" to appear"),
            "First wait should be step 2")
        XCTAssertTrue(result.contains("3. Wait for \"General\" to appear"),
            "Second wait should be step 3")
        XCTAssertTrue(result.contains("4. Tap \"General\""),
            "Tap should be step 4")
    }

    // MARK: - deriveName

    func testDeriveName() {
        XCTAssertEqual(
            SkillMdGenerator.deriveName(appName: "Settings", goal: "check version"),
            "Check Version")
    }

    func testDeriveNameWithoutGoal() {
        XCTAssertEqual(
            SkillMdGenerator.deriveName(appName: "Settings", goal: ""),
            "Explore Settings")
    }

    func testDeriveNameHandlesMultipleWords() {
        XCTAssertEqual(
            SkillMdGenerator.deriveName(appName: "Notes", goal: "browse notes list"),
            "Browse Notes List")
    }

    // MARK: - Consecutive Duplicate Landmark Dedup

    func testConsecutiveDuplicateLandmarksAreSkipped() {
        // Two screens where pickLandmark returns "General" for both
        // (same landmark text in header zone)
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                    TapPoint(text: "About", tapX: 205, tapY: 340, confidence: 0.95),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                    TapPoint(text: "Software Update", tapX: 205, tapY: 400, confidence: 0.92),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "About",
                screenshotBase64: "img1"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "test dedup", screens: screens)

        // "General" wait should appear only once
        let waitLines = result.components(separatedBy: "\n")
            .filter { $0.contains("Wait for \"General\" to appear") }
        XCTAssertEqual(waitLines.count, 1,
            "Consecutive duplicate landmark should produce only one wait step")
    }

    func testNonConsecutiveDuplicateLandmarksAreKept() {
        // Pattern: A, B, A — both A waits should appear
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "General",
                screenshotBase64: "img1"
            ),
            ExploredScreen(
                index: 2,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
                ],
                hints: [],
                actionType: "press_key",
                arrivedVia: "[",
                screenshotBase64: "img2"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "test non-consecutive", screens: screens)

        let waitSettings = result.components(separatedBy: "\n")
            .filter { $0.contains("Wait for \"Settings\" to appear") }
        XCTAssertEqual(waitSettings.count, 2,
            "Non-consecutive duplicate landmarks should both be kept")
    }

    func testStepNumberingWithSkippedLandmark() {
        // Two screens with same landmark + action on second
        // Should produce: 1. Launch, 2. Wait for "General", 3. Tap "About"
        // (no second wait, step numbers still sequential)
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                ],
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
                    TapPoint(text: "About", tapX: 205, tapY: 340, confidence: 0.95),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "About",
                screenshotBase64: "img1"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "test numbering", screens: screens)

        XCTAssertTrue(result.contains("1. Launch **Settings**"))
        XCTAssertTrue(result.contains("2. Wait for \"General\" to appear"))
        XCTAssertTrue(result.contains("3. Tap \"About\""),
            "Step numbering should be sequential after skipped duplicate landmark")
        XCTAssertFalse(result.contains("4."),
            "Should only have 3 steps total")
    }
}
