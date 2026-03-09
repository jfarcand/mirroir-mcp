// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Experiment C4: validates that AgentDiagnostic produces actionable recommendations.
// ABOUTME: Verifies diagnosis contains plausible coordinates and specific fix patches.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Tests that AgentDiagnostic produces useful, actionable recommendations
/// when compiled steps fail due to coordinate drift.
///
/// Tier 2 metric: diagnosis actionability > 70%
final class DiagnosisValueTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard IntegrationTestHelper.isFakeMirroringRunning else {
            throw IntegrationTestError.fakeMirroringNotRunning
        }
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
    }

    /// Simulate a drifted tap and verify diagnosis contains actionable patches.
    func testDiagnosisProducesActionablePatches() throws {
        let capture = ScreenCapture(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)

        // Get current screen to find a real element
        guard let screen = describer.describe(skipOCR: false) else {
            throw IntegrationTestError.describeReturnedNil
        }

        guard let element = screen.elements.first else {
            throw IntegrationTestError.notEnoughElements(0)
        }

        // Create a compiled step with intentionally wrong coordinates
        let driftedStep = CompiledStep(
            index: 0,
            type: "tap",
            label: element.text,
            hints: .tap(x: element.tapX + 50, y: element.tapY + 50,
                       confidence: 0.9, strategy: "exact")
        )
        let skillStep = SkillStep.tap(label: element.text)

        // Run diagnosis
        let recommendation = AgentDiagnostic.diagnose(
            step: skillStep,
            compiledStep: driftedStep,
            failureMessage: "Compiled tap hit wrong target",
            describer: describer
        )

        XCTAssertNotNil(recommendation, "Diagnosis should produce a recommendation")

        guard let rec = recommendation else { return }

        // The diagnosis should detect the element moved and provide coordinate patches
        XCTAssertFalse(rec.diagnosis.isEmpty, "Diagnosis should have a message")
        XCTAssertTrue(rec.diagnosis.contains("moved") || rec.diagnosis.contains("position"),
                      "Diagnosis should mention element moved: \(rec.diagnosis)")
        XCTAssertFalse(rec.patches.isEmpty, "Diagnosis should include coordinate patches")

        // Verify patch values are plausible (within screen bounds)
        guard let windowInfo = bridge.getWindowInfo() else { return }
        let maxX = Double(windowInfo.size.width)
        let maxY = Double(windowInfo.size.height)

        for patch in rec.patches {
            if let value = Double(patch.shouldBe) {
                XCTAssertGreaterThanOrEqual(value, 0, "Patch \(patch.field) should be >= 0")
                if patch.field == "tapX" {
                    XCTAssertLessThanOrEqual(value, maxX,
                        "Patch tapX (\(value)) should be <= window width (\(maxX))")
                }
                if patch.field == "tapY" {
                    XCTAssertLessThanOrEqual(value, maxY,
                        "Patch tapY (\(value)) should be <= window height (\(maxY))")
                }
            }
        }

        // Verify screenshot is included
        XCTAssertNotNil(rec.screenshotBase64, "Recommendation should include a screenshot")

        print("Diagnosis value: \(rec.patches.count) patches, screenshot: \(rec.screenshotBase64 != nil)")
    }

    /// Verify diagnosis for an element not found on screen.
    func testDiagnosisForMissingElement() throws {
        let capture = ScreenCapture(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)

        let missingStep = CompiledStep(
            index: 0,
            type: "tap",
            label: "NonexistentElement12345",
            hints: .tap(x: 100, y: 200, confidence: 0.9, strategy: "exact")
        )
        let skillStep = SkillStep.tap(label: "NonexistentElement12345")

        let recommendation = AgentDiagnostic.diagnose(
            step: skillStep,
            compiledStep: missingStep,
            failureMessage: "Element not found",
            describer: describer
        )

        XCTAssertNotNil(recommendation)
        guard let rec = recommendation else { return }

        XCTAssertTrue(rec.diagnosis.contains("not found"),
                      "Should report element not found: \(rec.diagnosis)")
        XCTAssertTrue(rec.diagnosis.contains("Visible"),
                      "Should list visible elements: \(rec.diagnosis)")
        XCTAssertNotNil(rec.screenshotBase64, "Should include screenshot")
    }
}
