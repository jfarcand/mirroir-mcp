// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for SkillMdGenerator: SKILL.md generation from explored screens.
// ABOUTME: Covers front matter, step generation, landmark picking, and name derivation.

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
                    TapPoint(text: "Settings", tapX: 205, tapY: 60, confidence: 0.98),
                    TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
                    TapPoint(text: "Privacy", tapX: 205, tapY: 400, confidence: 0.93),
                ],
                hints: [],
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

        // Launch step
        XCTAssertTrue(result.contains("Launch **Settings**"))

        // Wait for landmark (topmost element "Settings")
        XCTAssertTrue(result.contains("Wait for \"Settings\""))
    }

    // MARK: - Multiple Screens

    func testGenerateWithMultipleScreens() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 60, confidence: 0.98),
                    TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
                ],
                hints: [],
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "General", tapX: 205, tapY: 60, confidence: 0.97),
                    TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92),
                ],
                hints: [],
                arrivedVia: "General",
                screenshotBase64: "img1"
            ),
            ExploredScreen(
                index: 2,
                elements: [
                    TapPoint(text: "About", tapX: 205, tapY: 60, confidence: 0.96),
                    TapPoint(text: "iOS Version 18.2", tapX: 205, tapY: 300, confidence: 0.88),
                ],
                hints: [],
                arrivedVia: "About",
                screenshotBase64: "img2"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "check software version", screens: screens)

        // Should have steps for each screen
        XCTAssertTrue(result.contains("Launch **Settings**"))
        XCTAssertTrue(result.contains("Wait for \"Settings\""),
            "First screen should wait for landmark")
        XCTAssertTrue(result.contains("Tap \"General\""),
            "Second screen arrived via General")
        XCTAssertTrue(result.contains("Wait for \"General\""),
            "Second screen should wait for its landmark")
        XCTAssertTrue(result.contains("Tap \"About\""),
            "Third screen arrived via About")
        XCTAssertTrue(result.contains("Wait for \"About\""),
            "Third screen should wait for its landmark")
    }

    // MARK: - Goal Handling

    func testGenerateWithGoal() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Settings", tapX: 205, tapY: 60, confidence: 0.98),
                ],
                hints: [],
                arrivedVia: nil,
                screenshotBase64: "img"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "check version", screens: screens)

        XCTAssertTrue(result.contains("description: check version"),
            "Goal should appear in front matter description")
        XCTAssertTrue(result.contains("name: settings-check-version"),
            "Name should be derived from app + goal")
    }

    func testGenerateWithoutGoal() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Notes", tapX: 205, tapY: 60, confidence: 0.98),
                ],
                hints: [],
                arrivedVia: nil,
                screenshotBase64: "img"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Notes", goal: "", screens: screens)

        XCTAssertTrue(result.contains("description: Explore Notes"),
            "Empty goal should produce default description")
        XCTAssertTrue(result.contains("name: explore-notes"),
            "Empty goal should produce explore-based name")
    }

    // MARK: - ArrivedVia Produces Tap Step

    func testArrivedViaProducesTapStep() {
        let screens = [
            ExploredScreen(
                index: 0,
                elements: [
                    TapPoint(text: "Home", tapX: 205, tapY: 60, confidence: 0.98),
                ],
                hints: [],
                arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "Detail Page", tapX: 205, tapY: 60, confidence: 0.95),
                ],
                hints: [],
                arrivedVia: "More Info",
                screenshotBase64: "img1"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "MyApp", goal: "", screens: screens)

        XCTAssertTrue(result.contains("Tap \"More Info\""),
            "arrivedVia should become a Tap step")
    }

    // MARK: - pickLandmarkElement

    func testPickLandmarkElement() {
        let elements = [
            TapPoint(text: "Privacy & Security", tapX: 205, tapY: 400, confidence: 0.93),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 60, confidence: 0.98),
        ]

        let landmark = SkillMdGenerator.pickLandmarkElement(from: elements)
        XCTAssertEqual(landmark, "Settings",
            "Should pick the topmost qualifying element")
    }

    func testPickLandmarkElementEmpty() {
        let landmark = SkillMdGenerator.pickLandmarkElement(from: [])
        XCTAssertNil(landmark, "Empty elements should return nil")
    }

    func testPickLandmarkElementFiltersShortText() {
        let elements = [
            TapPoint(text: "OK", tapX: 205, tapY: 60, confidence: 0.99),
            TapPoint(text: "Cancel Button", tapX: 205, tapY: 120, confidence: 0.90),
        ]

        let landmark = SkillMdGenerator.pickLandmarkElement(from: elements)
        XCTAssertEqual(landmark, "Cancel Button",
            "Should skip elements shorter than 3 chars")
    }

    func testPickLandmarkElementFiltersLowConfidence() {
        let elements = [
            TapPoint(text: "Fuzzy Match", tapX: 205, tapY: 60, confidence: 0.3),
            TapPoint(text: "Clear Text", tapX: 205, tapY: 120, confidence: 0.85),
        ]

        let landmark = SkillMdGenerator.pickLandmarkElement(from: elements)
        XCTAssertEqual(landmark, "Clear Text",
            "Should skip elements with confidence below threshold")
    }

    func testPickLandmarkElementFiltersLongText() {
        let longText = String(repeating: "A", count: 50)
        let elements = [
            TapPoint(text: longText, tapX: 205, tapY: 60, confidence: 0.95),
            TapPoint(text: "Reasonable Label", tapX: 205, tapY: 120, confidence: 0.90),
        ]

        let landmark = SkillMdGenerator.pickLandmarkElement(from: elements)
        XCTAssertEqual(landmark, "Reasonable Label",
            "Should skip elements longer than 40 chars")
    }

    // MARK: - deriveName

    func testDeriveName() {
        XCTAssertEqual(
            SkillMdGenerator.deriveName(appName: "Settings", goal: "check version"),
            "settings-check-version")
    }

    func testDeriveNameWithoutGoal() {
        XCTAssertEqual(
            SkillMdGenerator.deriveName(appName: "Settings", goal: ""),
            "explore-settings")
    }

    func testDeriveNameHandlesSpecialCharacters() {
        XCTAssertEqual(
            SkillMdGenerator.deriveName(appName: "My App", goal: "do stuff & things!"),
            "my-app-do-stuff-things")
    }
}
