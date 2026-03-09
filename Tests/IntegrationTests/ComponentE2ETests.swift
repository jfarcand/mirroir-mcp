// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: End-to-end integration test for the full component → calibrate → compile → test pipeline.
// ABOUTME: Validates that components match FakeMirroring rows, skills compile, and compiled replay succeeds.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// End-to-end test exercising the complete pipeline against FakeMirroring:
/// 1. Define a component (table-row-disclosure)
/// 2. Calibrate it against the live FakeMirroring Settings screen via ComponentTester
/// 3. Compile a skill that taps a detected row and asserts navigation
/// 4. Replay the compiled skill and verify all steps pass
///
/// This validates the full chain: OCR → component detection → skill compilation → compiled replay.
final class ComponentE2ETests: XCTestCase {

    private var bridge: MirroringBridge!
    private var input: InputSimulation!
    private var describer: ScreenDescriber!
    private var capture: ScreenCapture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard IntegrationTestHelper.isFakeMirroringRunning else {
            throw XCTSkip("FakeMirroring not running")
        }
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw XCTSkip("FakeMirroring window not capturable")
        }
        capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
        input = InputSimulation(bridge: bridge)

        // Start on Settings scenario
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(1_000_000)
    }

    override func tearDown() {
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    // MARK: - Component Definition

    /// Build an inline table-row-disclosure definition matching FakeMirroring's Settings rows.
    private var disclosureDefinition: ComponentDefinition {
        ComponentDefinition(
            name: "table-row-disclosure",
            platform: "ios",
            description: "Table row with chevron disclosure indicator.",
            visualPattern: ["Label text ... >"],
            matchRules: ComponentMatchRules(
                rowHasChevron: true,
                chevronMode: nil,
                minElements: 1,
                maxElements: 4,
                maxRowHeightPt: 90,
                hasNumericValue: nil,
                hasLongText: nil,
                hasDismissButton: nil,
                zone: .content,
                minConfidence: nil,
                excludeNumericOnly: nil,
                textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true,
                clickTarget: .firstNavigation,
                clickResult: .pushesScreen,
                backAfterClick: true,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: true,
                role: .depthNavigation,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: true,
                absorbsBelowWithinPt: 0,
                absorbCondition: .any,
                splitMode: .none
            )
        )
    }

    // MARK: - Step 1: Calibrate Component

    /// Calibrate the table-row-disclosure component against FakeMirroring Settings screen.
    /// Settings has 6 rows with ">" chevrons — the component should match most of them.
    func testCalibrateComponentMatchesSettingsRows() throws {
        guard let screen = describeOrSkip() else {
            throw XCTSkip("describe() returned nil")
        }

        guard let windowInfo = bridge.getWindowInfo() else {
            throw XCTSkip("Cannot get window info")
        }
        let screenHeight = Double(windowInfo.size.height)

        let report = ComponentTester.diagnose(
            definition: disclosureDefinition,
            elements: screen.elements,
            screenHeight: screenHeight,
            allDefinitions: [disclosureDefinition]
        )

        // The report should show matches for at least some of the 6 Settings rows
        XCTAssertTrue(report.contains("✅"),
                      "Component should match at least one Settings row. Report:\n\(report)")
        XCTAssertTrue(report.contains("table-row-disclosure"),
                      "Report should reference the component name. Report:\n\(report)")

        // Verify the component detected clickable rows with tap targets
        let classified = ElementClassifier.classify(
            screen.elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [disclosureDefinition],
            screenHeight: screenHeight
        )

        let disclosureComponents = components.filter { $0.kind == "table-row-disclosure" }
        XCTAssertGreaterThanOrEqual(disclosureComponents.count, 3,
            "Should detect at least 3 disclosure rows on Settings. Found: \(disclosureComponents.count)")

        // Each disclosure component should have a tap target
        for component in disclosureComponents {
            XCTAssertNotNil(component.tapTarget,
                "Disclosure row should have a tap target. Elements: \(component.elements.map(\.point.text))")
        }

        print("Calibration: \(disclosureComponents.count) disclosure rows detected, "
              + "\(disclosureComponents.filter { $0.tapTarget != nil }.count) with tap targets")
    }

    // MARK: - Step 2: Compile Skill

    /// Compile a skill that asserts Settings rows and taps General to navigate.
    func testCompileSkillAgainstCalibratedScreen() throws {
        let yaml = """
        name: settings-to-detail
        app: FakeMirroring
        description: Navigate from Settings to Detail via General row

        steps:
          - assert_visible: "Settings"
          - assert_visible: "General"
          - tap: "General"
          - assert_visible: "Keyboard"
        """

        let tmpPath = writeTempYAML(yaml)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let config = testConfig()
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: config
        )

        let skill = SkillParser.parse(content: yaml, filePath: tmpPath)
        let dims = windowDimensions()
        let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: tmpPath,
            windowWidth: dims.width,
            windowHeight: dims.height,
            orientation: "portrait"
        )

        XCTAssertNotNil(compiled, "Skill should compile against FakeMirroring Settings")
        guard let compiled = compiled else { return }

        // Verify the compiled skill has correct step types
        XCTAssertEqual(compiled.steps.count, skill.steps.count,
                       "Compiled skill should have same number of steps")

        // Tap step should have cached coordinates
        let tapSteps = compiled.steps.filter { $0.type == "tap" }
        XCTAssertEqual(tapSteps.count, 1, "Should have 1 compiled tap step")
        if let tapHints = tapSteps.first?.hints {
            XCTAssertNotNil(tapHints.tapX, "Compiled tap should have cached X coordinate")
            XCTAssertNotNil(tapHints.tapY, "Compiled tap should have cached Y coordinate")
            XCTAssertNotNil(tapHints.confidence, "Compiled tap should have confidence score")
        }

        // Assertion steps should have .assertion action
        let assertionSteps = compiled.steps.filter {
            $0.hints?.compiledAction == .assertion
        }
        XCTAssertGreaterThanOrEqual(assertionSteps.count, 2,
            "At least 2 assertion steps should have .assertion action")

        print("Compilation: \(compiled.steps.count) steps compiled, "
              + "\(tapSteps.count) tap(s), \(assertionSteps.count) assertion(s)")
    }

    // MARK: - Step 3: Full E2E Pipeline

    /// Full end-to-end: calibrate → compile → reset → replay compiled → verify.
    func testFullPipeline_CalibrateCompileReplay() throws {
        // --- Phase 1: Calibrate ---
        guard let screen = describeOrSkip() else {
            throw XCTSkip("describe() returned nil")
        }
        guard let windowInfo = bridge.getWindowInfo() else {
            throw XCTSkip("Cannot get window info")
        }
        let screenHeight = Double(windowInfo.size.height)

        let classified = ElementClassifier.classify(
            screen.elements, screenHeight: screenHeight)
        let components = ComponentDetector.detect(
            classified: classified,
            definitions: [disclosureDefinition],
            screenHeight: screenHeight
        )
        let disclosureRows = components.filter { $0.kind == "table-row-disclosure" }
        XCTAssertGreaterThanOrEqual(disclosureRows.count, 3,
            "Calibration should find >= 3 disclosure rows")

        // --- Phase 2: Compile ---
        let yaml = """
        name: e2e-pipeline
        app: FakeMirroring
        description: Full E2E pipeline test

        steps:
          - assert_visible: "General"
          - tap: "General"
          - assert_visible: "Keyboard"
        """

        let tmpPath = writeTempYAML(yaml)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let config = testConfig()
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: config
        )

        let skill = SkillParser.parse(content: yaml, filePath: tmpPath)
        let dims = windowDimensions()
        let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: tmpPath,
            windowWidth: dims.width,
            windowHeight: dims.height,
            orientation: "portrait"
        )

        XCTAssertNotNil(compiled, "Skill should compile")
        guard let compiled = compiled else { return }

        // --- Phase 3: Reset & Replay ---
        // Reset to Settings before replay
        _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
        usleep(1_000_000)
        IntegrationTestHelper.ensureWindowReady(bridge: bridge)

        let compiledExecutor = CompiledStepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )

        var passCount = 0
        var failMessages: [String] = []
        for compiledStep in compiled.steps {
            let step = skill.steps[compiledStep.index]
            let result = compiledExecutor.execute(
                step: step, compiledStep: compiledStep,
                stepIndex: compiledStep.index, skillName: skill.name
            )
            if result.status == .passed {
                passCount += 1
            } else {
                failMessages.append("Step \(compiledStep.index) '\(compiledStep.type)' "
                    + "\(compiledStep.label ?? ""): \(result.message ?? "unknown")")
            }
        }

        XCTAssertEqual(passCount, compiled.steps.count,
            "All compiled steps should pass. Failures:\n\(failMessages.joined(separator: "\n"))")

        print("E2E pipeline: calibrated \(disclosureRows.count) components, "
              + "compiled \(compiled.steps.count) steps, "
              + "replayed \(passCount)/\(compiled.steps.count) passed")
    }

    // MARK: - Helpers

    private func describeOrSkip() -> ScreenDescriber.DescribeResult? {
        for attempt in 1...3 {
            if let result = describer.describe(skipOCR: false) { return result }
            if attempt < 3 { usleep(500_000) }
        }
        return nil
    }

    private func windowDimensions() -> (width: Double, height: Double) {
        guard let info = bridge.getWindowInfo() else { return (410, 898) }
        return (Double(info.size.width), Double(info.size.height))
    }

    private func writeTempYAML(_ content: String) -> String {
        let tmpDir = NSTemporaryDirectory()
        let fileName = "component-e2e-\(UUID().uuidString).yaml"
        let path = (tmpDir as NSString).appendingPathComponent(fileName)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func testConfig() -> StepExecutorConfig {
        StepExecutorConfig(
            waitForTimeoutSeconds: 10,
            settlingDelayMs: 500,
            screenshotDir: NSTemporaryDirectory() + "mirroir-component-e2e",
            dryRun: false
        )
    }
}
