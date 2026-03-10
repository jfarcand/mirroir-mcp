// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration tests for the generate_skill pipeline against the FakeMirroring app.
// ABOUTME: Exercises ExplorationSession, StructuralFingerprint, and SkillMdGenerator with real OCR data.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

/// Integration tests for the generate_skill exploration pipeline.
/// Verifies that real OCR output flows correctly through ExplorationSession's
/// StructuralFingerprint-based dedup and SkillMdGenerator's SKILL.md assembly.
///
/// Run with: `swift test --filter IntegrationTests`
///
/// FakeMirroring must be running:
///   `swift build -c release --product FakeMirroring && ./scripts/package-fake-app.sh`
///   `open .build/release/FakeMirroring.app`
final class GenerateSkillIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()

        try IntegrationTestHelper.ensureFakeMirroringRunning()

        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)

        // Ensure window is capturable — prior test classes may have exhausted screencapture
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            XCTFail("FakeMirroring window not capturable after retries")
            return
        }

        describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
    }

    // MARK: - Exploration Session with Real OCR

    func testCaptureAndDedupWithRealOCR() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil — cannot test exploration pipeline")
            return
        }

        let session = ExplorationSession()
        session.start(appName: "FakeMirroring", goal: "test dedup")

        // First capture should be accepted
        let first = session.capture(
            elements: result.elements,
            hints: [],
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )
        XCTAssertTrue(first, "First capture of FakeMirroring screen should be accepted")
        XCTAssertEqual(session.screenCount, 1)

        // Second capture of the same static screen should be rejected (similarity = 1.0)
        guard let result2 = describer.describe() else {
            XCTFail("Second describe() returned nil")
            return
        }

        let second = session.capture(
            elements: result2.elements,
            hints: [],
            actionType: "tap",
            arrivedVia: "Settings",
            screenshotBase64: result2.screenshotBase64
        )
        XCTAssertFalse(second,
            "Recapture of unchanged FakeMirroring screen should be rejected as duplicate")
        XCTAssertEqual(session.screenCount, 1, "Count should stay at 1 after duplicate rejection")
    }

    func testSimilarityScoreWithRealOCR() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        // Two OCR passes of the same static screen should have high similarity
        guard let result2 = describer.describe() else {
            XCTFail("Second describe() returned nil")
            return
        }

        let set1 = StructuralFingerprint.extractStructural(from: result.elements)
        let set2 = StructuralFingerprint.extractStructural(from: result2.elements)
        let score = StructuralFingerprint.similarity(set1, set2)
        XCTAssertGreaterThanOrEqual(score, 0.9,
            "Two OCR passes of the same FakeMirroring screen should have similarity >= 0.9. Got \(score)")
    }

    func testStructuralExtractProducesStableElements() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        let structural = StructuralFingerprint.extractStructural(from: result.elements)

        // FakeMirroring renders: Settings, General, Display, Privacy, About, Software Update, Developer
        // (9:41 is filtered as a time pattern)
        XCTAssertGreaterThanOrEqual(structural.count, 5,
            "Structural set should contain most of FakeMirroring's labels. Got: \(structural)")

        // Verify time pattern is filtered
        let hasTime = structural.contains { $0.contains("9:41") || $0.contains("9:4") }
        XCTAssertFalse(hasTime,
            "Time pattern '9:41' should be filtered from structural set. Got: \(structural)")
    }

    // MARK: - End-to-End SKILL.md Generation

    func testGenerateSkillMdFromRealOCR() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        let session = ExplorationSession()
        session.start(appName: "FakeMirroring", goal: "verify home screen")

        session.capture(
            elements: result.elements,
            hints: [],
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )

        guard let data = session.finalize() else {
            XCTFail("finalize() returned nil")
            return
        }

        let skillMd = SkillMdGenerator.generate(
            appName: data.appName,
            goal: data.goal,
            screens: data.screens
        )

        // Front matter
        XCTAssertTrue(skillMd.hasPrefix("---\n"), "Should start with YAML front matter")
        XCTAssertTrue(skillMd.contains("app: FakeMirroring"))
        XCTAssertTrue(skillMd.contains("description: verify home screen"))

        // Launch step
        XCTAssertTrue(skillMd.contains("1. Launch **FakeMirroring**"))

        // Wait-for step: LandmarkPicker should find a landmark from FakeMirroring's labels
        XCTAssertTrue(skillMd.contains("2. Wait for"),
            "Should have a wait-for step from real OCR landmark. Got:\n\(skillMd)")
    }

    func testSetBasedLandmarkDedupWithRealOCR() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        // Simulate A-B-A navigation: same screen captured as first and third
        // with a synthetic middle screen
        let screens = [
            ExploredScreen(
                index: 0,
                elements: result.elements,
                hints: [],
                actionType: nil,
                arrivedVia: nil,
                screenshotBase64: result.screenshotBase64
            ),
            ExploredScreen(
                index: 1,
                elements: [
                    TapPoint(text: "About", tapX: 205, tapY: 120, confidence: 0.96),
                    TapPoint(text: "iOS Version 18.2", tapX: 205, tapY: 300, confidence: 0.88),
                ],
                hints: [],
                actionType: "tap",
                arrivedVia: "About",
                screenshotBase64: "synthetic"
            ),
            ExploredScreen(
                index: 2,
                elements: result.elements,
                hints: [],
                actionType: "press_key",
                arrivedVia: "[",
                screenshotBase64: result.screenshotBase64
            ),
        ]

        let skillMd = SkillMdGenerator.generate(
            appName: "FakeMirroring",
            goal: "test landmark dedup",
            screens: screens
        )

        // The landmark from screen 0 should appear only once (Set-based dedup)
        let landmark = LandmarkPicker.pickLandmark(from: result.elements)
        XCTAssertNotNil(landmark, "LandmarkPicker should find a landmark from real OCR")

        if let landmark = landmark {
            let waitLines = skillMd.components(separatedBy: "\n")
                .filter { $0.contains("Wait for \"\(landmark)\" to appear") }
            XCTAssertEqual(waitLines.count, 1,
                "Landmark '\(landmark)' should appear only once despite A-B-A pattern. Got:\n\(skillMd)")
        }
    }

    // MARK: - Exploration Guide with Real OCR

    func testExplorationGuideSuggestsFromRealElements() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        // Goal-driven analysis with a version-related goal
        let guidance = ExplorationGuide.analyze(
            mode: .goalDriven,
            goal: "check software version",
            elements: result.elements,
            hints: result.hints,
            startElements: nil,
            actionLog: [],
            screenCount: 1
        )

        XCTAssertFalse(guidance.suggestions.isEmpty,
            "ExplorationGuide should produce suggestions from real OCR data")
        XCTAssertNotNil(guidance.goalProgress,
            "Goal-driven mode should provide goal progress")
    }

    func testDiscoveryModeWithRealElements() {
        guard let result = describer.describe() else {
            XCTFail("describe() returned nil")
            return
        }

        let guidance = ExplorationGuide.analyze(
            mode: .discovery,
            goal: "",
            elements: result.elements,
            hints: result.hints,
            startElements: nil,
            actionLog: [],
            screenCount: 1
        )

        XCTAssertTrue(guidance.goalProgress?.contains("Discovery mode") ?? false,
            "Discovery mode should be indicated")
        XCTAssertTrue(guidance.suggestions.contains(where: { $0.contains("explore this flow") }),
            "Discovery should suggest flows to explore")
    }
}
