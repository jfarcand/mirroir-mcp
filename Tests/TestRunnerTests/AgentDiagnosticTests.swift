// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AgentDiagnostic — compiled skill failure diagnosis.
// ABOUTME: Verifies tap drift detection, sleep timing analysis, scroll recommendations, and report formatting.

import Foundation
import Testing

@testable import HelperLib
@testable import mirroir_mcp

@Suite("AgentDiagnostic")
struct AgentDiagnosticTests {

    // MARK: - Helpers

    private func makeDescriber(elements: [TapPoint]) -> StubDescriber {
        let describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: elements, screenshotBase64: "")
        return describer
    }

    private func makeTapPoint(_ text: String, x: Double, y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95)
    }

    // MARK: - No Hints → nil

    @Test("Returns nil when compiled step has no hints")
    func noHintsReturnsNil() {
        let step = SkillStep.tap(label: "AirDrop")
        let compiled = CompiledStep(index: 0, type: "tap", label: "AirDrop", hints: nil)
        let describer = makeDescriber(elements: [])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)

        #expect(result == nil)
    }

    // MARK: - OCR Failure

    @Test("Returns capture-failed diagnosis when OCR returns nil")
    func ocrFailureReturnsDiagnosis() {
        let hints = StepHints.tap(x: 100, y: 200, confidence: 0.9, strategy: "exact")
        let compiled = CompiledStep(index: 0, type: "tap", label: "AirDrop", hints: hints)
        let step = SkillStep.tap(label: "AirDrop")

        let describer = StubDescriber()
        describer.describeResult = nil

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: "tap failed", describer: describer)

        #expect(result != nil)
        #expect(result!.diagnosis.contains("capture failed"))
    }

    // MARK: - Tap Diagnosis

    @Test("Detects element that moved to different coordinates")
    func tapElementMoved() {
        let hints = StepHints.tap(x: 100, y: 200, confidence: 0.9, strategy: "exact")
        let compiled = CompiledStep(index: 2, type: "tap", label: "AirDrop", hints: hints)
        let step = SkillStep.tap(label: "AirDrop")

        let describer = makeDescriber(elements: [
            makeTapPoint("AirDrop", x: 150, y: 250)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.stepIndex == 2)
        #expect(result.stepType == "tap")
        #expect(result.label == "AirDrop")
        #expect(result.diagnosis.contains("moved"))
        #expect(result.patches.count == 2)
        #expect(result.patches[0].field == "tapX")
        #expect(result.patches[0].was == "100.0")
        #expect(result.patches[0].shouldBe == "150.0")
        #expect(result.patches[1].field == "tapY")
        #expect(result.patches[1].was == "200.0")
        #expect(result.patches[1].shouldBe == "250.0")
    }

    @Test("Reports 'tap absorbed' when element is at compiled position")
    func tapAbsorbedAtSamePosition() {
        let hints = StepHints.tap(x: 100, y: 200, confidence: 0.9, strategy: "exact")
        let compiled = CompiledStep(index: 0, type: "tap", label: "AirDrop", hints: hints)
        let step = SkillStep.tap(label: "AirDrop")

        let describer = makeDescriber(elements: [
            makeTapPoint("AirDrop", x: 102, y: 201)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("absorbed"))
        #expect(result.patches.isEmpty)
    }

    @Test("Reports element not found with visible elements list")
    func tapElementNotFound() {
        let hints = StepHints.tap(x: 100, y: 200, confidence: 0.9, strategy: "exact")
        let compiled = CompiledStep(index: 0, type: "tap", label: "AirDrop", hints: hints)
        let step = SkillStep.tap(label: "AirDrop")

        let describer = makeDescriber(elements: [
            makeTapPoint("Wi-Fi", x: 100, y: 300),
            makeTapPoint("Bluetooth", x: 100, y: 350),
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("not found"))
        #expect(result.diagnosis.contains("Wi-Fi"))
        #expect(result.diagnosis.contains("Bluetooth"))
        #expect(result.patches.isEmpty)
    }

    // MARK: - Sleep Diagnosis (wait_for / assert_visible)

    @Test("wait_for: element visible suggests increasing delay")
    func waitForElementVisibleSuggestsLongerDelay() {
        let hints = StepHints.sleep(delayMs: 500)
        let compiled = CompiledStep(index: 1, type: "wait_for", label: "General", hints: hints)
        let step = SkillStep.waitFor(label: "General", timeoutSeconds: nil)

        let describer = makeDescriber(elements: [
            makeTapPoint("General", x: 200, y: 340)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("IS visible"))
        #expect(result.diagnosis.contains("too short"))
        #expect(result.patches.count == 1)
        #expect(result.patches[0].field == "observedDelayMs")
        #expect(result.patches[0].was == "500")
        #expect(result.patches[0].shouldBe == "1500")
    }

    @Test("assert_visible: element not visible reports wrong screen")
    func assertVisibleElementMissing() {
        let hints = StepHints.sleep(delayMs: 200)
        let compiled = CompiledStep(
            index: 3, type: "assert_visible", label: "Model Name", hints: hints)
        let step = SkillStep.assertVisible(label: "Model Name")

        let describer = makeDescriber(elements: [
            makeTapPoint("Settings", x: 200, y: 100)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("not visible"))
        #expect(result.diagnosis.contains("wrong screen"))
        #expect(result.patches.isEmpty)
    }

    @Test("assert_not_visible: element correctly absent")
    func assertNotVisibleCorrectlyAbsent() {
        let hints = StepHints.sleep(delayMs: 200)
        let compiled = CompiledStep(
            index: 0, type: "assert_not_visible", label: "Error", hints: hints)
        let step = SkillStep.assertNotVisible(label: "Error")

        let describer = makeDescriber(elements: [
            makeTapPoint("Settings", x: 200, y: 100)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("correctly not visible"))
        #expect(result.diagnosis.contains("should have passed"))
    }

    @Test("assert_not_visible: element unexpectedly visible")
    func assertNotVisibleButPresent() {
        let hints = StepHints.sleep(delayMs: 200)
        let compiled = CompiledStep(
            index: 0, type: "assert_not_visible", label: "Error", hints: hints)
        let step = SkillStep.assertNotVisible(label: "Error")

        let describer = makeDescriber(elements: [
            makeTapPoint("Error", x: 200, y: 100)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("unexpectedly visible"))
    }

    // MARK: - Scroll Diagnosis

    @Test("scroll_to: element visible after scrolls suggests count adjustment")
    func scrollElementVisibleAfterScrolls() {
        let hints = StepHints.scrollSequence(count: 3, direction: "up")
        let compiled = CompiledStep(
            index: 4, type: "scroll_to", label: "About", hints: hints)
        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)

        let describer = makeDescriber(elements: [
            makeTapPoint("About", x: 200, y: 500)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("IS visible"))
        #expect(result.diagnosis.contains("3 scroll(s)"))
    }

    @Test("scroll_to: element not found recommends more scrolls")
    func scrollElementNotFoundRecommendsMore() {
        let hints = StepHints.scrollSequence(count: 2, direction: "up")
        let compiled = CompiledStep(
            index: 4, type: "scroll_to", label: "About", hints: hints)
        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)

        let describer = makeDescriber(elements: [
            makeTapPoint("General", x: 200, y: 300),
            makeTapPoint("Privacy", x: 200, y: 400),
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: nil, describer: describer)!

        #expect(result.diagnosis.contains("not found"))
        #expect(result.diagnosis.contains("May need more scrolls"))
        #expect(result.patches.count == 1)
        #expect(result.patches[0].field == "scrollCount")
        #expect(result.patches[0].was == "2")
        #expect(result.patches[0].shouldBe == "4")
    }

    // MARK: - Passthrough Diagnosis

    @Test("passthrough: includes failure message and visible elements")
    func passthroughIncludesContext() {
        let hints = StepHints.passthrough()
        let compiled = CompiledStep(
            index: 0, type: "launch", label: "Settings", hints: hints)
        let step = SkillStep.launch(appName: "Settings")

        let describer = makeDescriber(elements: [
            makeTapPoint("Home", x: 200, y: 400)
        ])

        let result = AgentDiagnostic.diagnose(
            step: step, compiledStep: compiled,
            failureMessage: "App not installed", describer: describer)!

        #expect(result.diagnosis.contains("Passthrough step failed"))
        #expect(result.diagnosis.contains("App not installed"))
        #expect(result.diagnosis.contains("Home"))
    }

    // MARK: - Report Formatting

    @Test("printReport formats recommendations with patches to stderr")
    func printReportFormatsCorrectly() {
        let recs = [
            AgentDiagnostic.Recommendation(
                stepIndex: 2, stepType: "tap", label: "AirDrop",
                diagnosis: "Element moved",
                patches: [
                    AgentDiagnostic.Patch(field: "tapX", was: "100.0", shouldBe: "150.0"),
                    AgentDiagnostic.Patch(field: "tapY", was: "200.0", shouldBe: "250.0"),
                ]),
        ]

        // Capture stderr output
        let pipe = Pipe()
        let savedStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        AgentDiagnostic.printReport(recommendations: recs, skillName: "test-skill")

        fflush(stderr)
        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(output.contains("Agent Diagnostic: test-skill"))
        #expect(output.contains("Step 3 [tap \"AirDrop\"]"))
        #expect(output.contains("Fix: tapX: 100.0 -> 150.0"))
        #expect(output.contains("recompile"))
    }

    @Test("printReport is silent when recommendations array is empty")
    func printReportSilentWhenEmpty() {
        let pipe = Pipe()
        let savedStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        AgentDiagnostic.printReport(recommendations: [], skillName: "empty")

        fflush(stderr)
        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(output.isEmpty)
    }
}
