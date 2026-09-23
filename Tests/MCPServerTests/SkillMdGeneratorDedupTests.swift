// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for SkillMdGenerator landmark deduplication and displayLabel preference.
// ABOUTME: Covers consecutive duplicate dedup and set-based dedup of generated steps.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

extension SkillMdGeneratorTests {

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

    func testNonConsecutiveDuplicateLandmarksAreSkipped() {
        // Pattern: A, B, A — second A wait should be skipped (Set-based dedup)
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
        XCTAssertEqual(waitSettings.count, 1,
            "Non-consecutive duplicate landmarks should be skipped by Set-based dedup")
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

    // MARK: - Set-Based Dedup

    func testNonConsecutiveDifferentLandmarksAreKept() {
        // Pattern: A, B, C — all three landmarks should produce wait steps
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
                    TapPoint(text: "About", tapX: 205, tapY: 120, confidence: 0.96),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "About",
                screenshotBase64: "img2"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "test distinct", screens: screens)

        XCTAssertTrue(result.contains("Wait for \"Settings\" to appear"))
        XCTAssertTrue(result.contains("Wait for \"General\" to appear"))
        XCTAssertTrue(result.contains("Wait for \"About\" to appear"),
            "All distinct landmarks should produce wait steps")
    }

    func testStepNumberingWithSetDedup() {
        // Pattern: A, B, A with actions — step numbers stay sequential after skipped wait
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
            appName: "Settings", goal: "test numbering dedup", screens: screens)

        // Expected steps:
        // 1. Launch **Settings**
        // 2. Wait for "Settings" to appear
        // 3. Wait for "General" to appear
        // 4. Tap "General"
        // 5. Press **[**    ← "Settings" wait is skipped (Set-based dedup)
        XCTAssertTrue(result.contains("1. Launch **Settings**"))
        XCTAssertTrue(result.contains("2. Wait for \"Settings\" to appear"))
        XCTAssertTrue(result.contains("3. Wait for \"General\" to appear"))
        XCTAssertTrue(result.contains("4. Tap \"General\""))
        XCTAssertTrue(result.contains("5. Press **[**"),
            "Back navigation should be step 5, no gap from skipped duplicate wait")
        XCTAssertFalse(result.contains("6."),
            "Should only have 5 steps total")
    }

    // MARK: - displayLabel Preference

    func testDisplayLabelPreferredOverArrivedVia() {
        // Simulate a component-detected tap where arrivedVia is raw OCR ("icon")
        // but displayLabel is the cleaned label ("General")
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
                    TapPoint(text: "About", tapX: 205, tapY: 300, confidence: 0.9),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "icon",
                displayLabel: "General",
                screenshotBase64: "img1"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "test display label", screens: screens)

        XCTAssertTrue(result.contains("Tap \"General\""),
            "Should use displayLabel 'General', not raw arrivedVia 'icon'")
        XCTAssertFalse(result.contains("Tap \"icon\""),
            "Raw OCR artifact should not appear in skill steps")
    }

    func testFallsBackToArrivedViaWhenNoDisplayLabel() {
        // When displayLabel is nil, fall back to resolved arrivedVia
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
                    TapPoint(text: "General", tapX: 205, tapY: 300, confidence: 0.9),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "general",
                screenshotBase64: "img1"
            ),
        ]

        let result = SkillMdGenerator.generate(
            appName: "Settings", goal: "test fallback", screens: screens)

        // arrivedVia "general" should be resolved to "General" via element matching
        XCTAssertTrue(result.contains("Tap \"General\""),
            "Should resolve arrivedVia case against elements when no displayLabel")
    }
}
