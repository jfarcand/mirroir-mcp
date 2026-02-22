// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Diagnoses compiled skill failures by running one OCR call on the actual screen.
// ABOUTME: Compares compiled hints against reality and produces actionable patch recommendations.

import Foundation
import HelperLib

/// Diagnoses why a compiled step failed by comparing cached hints against the actual screen.
/// Costs exactly one OCR call per failure — zero cost on success.
enum AgentDiagnostic {

    /// A recommendation for fixing a compiled step.
    struct Recommendation {
        let stepIndex: Int
        let stepType: String
        let label: String?
        let diagnosis: String
        let patches: [Patch]
    }

    /// A single field change in the compiled JSON.
    struct Patch {
        let field: String
        let was: String
        let shouldBe: String
    }

    /// Diagnose a compiled step failure by OCR-ing the current screen.
    /// Returns a recommendation with specific patches, or nil if diagnosis isn't possible.
    static func diagnose(
        step: SkillStep,
        compiledStep: CompiledStep,
        failureMessage: String?,
        describer: ScreenDescribing
    ) -> Recommendation? {
        guard let hints = compiledStep.hints else { return nil }

        // Run one OCR call to see the actual screen
        guard let screen = describer.describe(skipOCR: false) else {
            return Recommendation(
                stepIndex: compiledStep.index,
                stepType: compiledStep.type,
                label: compiledStep.label,
                diagnosis: "Cannot OCR screen for diagnosis (capture failed)",
                patches: []
            )
        }

        switch hints.compiledAction {
        case .tap:
            return diagnoseTap(compiledStep: compiledStep, hints: hints,
                               screen: screen, failureMessage: failureMessage)
        case .sleep:
            return diagnoseSleep(compiledStep: compiledStep, hints: hints,
                                 screen: screen, failureMessage: failureMessage)
        case .scrollSequence:
            return diagnoseScroll(compiledStep: compiledStep, hints: hints,
                                  screen: screen, failureMessage: failureMessage)
        case .passthrough:
            return diagnosePassthrough(compiledStep: compiledStep,
                                       screen: screen, failureMessage: failureMessage)
        }
    }

    // MARK: - Tap Diagnosis

    private static func diagnoseTap(
        compiledStep: CompiledStep,
        hints: StepHints,
        screen: ScreenDescriber.DescribeResult,
        failureMessage: String?
    ) -> Recommendation {
        let label = compiledStep.label ?? ""
        let compiledX = hints.tapX ?? 0
        let compiledY = hints.tapY ?? 0

        // Check if the target element is still on screen but at different coordinates
        if let match = ElementMatcher.findMatch(label: label, in: screen.elements) {
            let dx = abs(match.element.tapX - compiledX)
            let dy = abs(match.element.tapY - compiledY)

            if dx < 5 && dy < 5 {
                return Recommendation(
                    stepIndex: compiledStep.index,
                    stepType: compiledStep.type,
                    label: label,
                    diagnosis: "Element \"\(label)\" is at the compiled position — tap may have been absorbed by the UI",
                    patches: []
                )
            }

            return Recommendation(
                stepIndex: compiledStep.index,
                stepType: compiledStep.type,
                label: label,
                diagnosis: "Element \"\(label)\" moved: compiled (\(fmt(compiledX)), \(fmt(compiledY))) vs actual (\(fmt(match.element.tapX)), \(fmt(match.element.tapY)))",
                patches: [
                    Patch(field: "tapX", was: fmt(compiledX), shouldBe: fmt(match.element.tapX)),
                    Patch(field: "tapY", was: fmt(compiledY), shouldBe: fmt(match.element.tapY)),
                ]
            )
        }

        // Element not found — list what IS on screen
        let visible = screen.elements.prefix(10).map { "\"\($0.text)\" (\(fmt($0.tapX)), \(fmt($0.tapY)))" }
        return Recommendation(
            stepIndex: compiledStep.index,
            stepType: compiledStep.type,
            label: label,
            diagnosis: "Element \"\(label)\" not found on screen. Visible: \(visible.joined(separator: ", "))",
            patches: []
        )
    }

    // MARK: - Sleep Diagnosis (wait_for / assert_visible)

    private static func diagnoseSleep(
        compiledStep: CompiledStep,
        hints: StepHints,
        screen: ScreenDescriber.DescribeResult,
        failureMessage: String?
    ) -> Recommendation {
        let label = compiledStep.label ?? ""

        // For assert_visible compiled as sleep — check if element is actually visible
        if compiledStep.type == "assert_visible" || compiledStep.type == "wait_for" {
            if ElementMatcher.isVisible(label: label, in: screen.elements) {
                let delayMs = hints.observedDelayMs ?? 0
                return Recommendation(
                    stepIndex: compiledStep.index,
                    stepType: compiledStep.type,
                    label: label,
                    diagnosis: "Element \"\(label)\" IS visible — compiled sleep (\(delayMs)ms) may be too short. Increase observedDelayMs.",
                    patches: [
                        Patch(field: "observedDelayMs", was: "\(delayMs)",
                              shouldBe: "\(delayMs + 1000)")
                    ]
                )
            }

            let visible = screen.elements.prefix(10).map { "\"\($0.text)\"" }
            return Recommendation(
                stepIndex: compiledStep.index,
                stepType: compiledStep.type,
                label: label,
                diagnosis: "Element \"\(label)\" not visible after compiled sleep. Screen shows: \(visible.joined(separator: ", ")). Previous step may have navigated to wrong screen.",
                patches: []
            )
        }

        if compiledStep.type == "assert_not_visible" {
            if !ElementMatcher.isVisible(label: label, in: screen.elements) {
                return Recommendation(
                    stepIndex: compiledStep.index,
                    stepType: compiledStep.type,
                    label: label,
                    diagnosis: "Element \"\(label)\" is correctly not visible. Step should have passed.",
                    patches: []
                )
            }

            return Recommendation(
                stepIndex: compiledStep.index,
                stepType: compiledStep.type,
                label: label,
                diagnosis: "Element \"\(label)\" is unexpectedly visible. Previous step may not have navigated away.",
                patches: []
            )
        }

        return Recommendation(
            stepIndex: compiledStep.index,
            stepType: compiledStep.type,
            label: label,
            diagnosis: failureMessage ?? "Sleep step failed",
            patches: []
        )
    }

    // MARK: - Scroll Diagnosis

    private static func diagnoseScroll(
        compiledStep: CompiledStep,
        hints: StepHints,
        screen: ScreenDescriber.DescribeResult,
        failureMessage: String?
    ) -> Recommendation {
        let label = compiledStep.label ?? ""
        let compiledCount = hints.scrollCount ?? 0

        if ElementMatcher.isVisible(label: label, in: screen.elements) {
            return Recommendation(
                stepIndex: compiledStep.index,
                stepType: compiledStep.type,
                label: label,
                diagnosis: "Element \"\(label)\" IS visible after \(compiledCount) scroll(s) — scroll count may need adjustment",
                patches: []
            )
        }

        let visible = screen.elements.prefix(8).map { "\"\($0.text)\"" }
        return Recommendation(
            stepIndex: compiledStep.index,
            stepType: compiledStep.type,
            label: label,
            diagnosis: "Element \"\(label)\" not found after \(compiledCount) compiled scroll(s). Visible: \(visible.joined(separator: ", ")). May need more scrolls.",
            patches: [
                Patch(field: "scrollCount", was: "\(compiledCount)",
                      shouldBe: "\(compiledCount + 2)")
            ]
        )
    }

    // MARK: - Passthrough Diagnosis

    private static func diagnosePassthrough(
        compiledStep: CompiledStep,
        screen: ScreenDescriber.DescribeResult,
        failureMessage: String?
    ) -> Recommendation {
        let visible = screen.elements.prefix(8).map { "\"\($0.text)\"" }
        return Recommendation(
            stepIndex: compiledStep.index,
            stepType: compiledStep.type,
            label: compiledStep.label,
            diagnosis: "Passthrough step failed: \(failureMessage ?? "unknown"). Screen shows: \(visible.joined(separator: ", "))",
            patches: []
        )
    }

    // MARK: - Report Formatting

    /// Format a diagnostic report to stderr.
    static func printReport(recommendations: [Recommendation], skillName: String) {
        guard !recommendations.isEmpty else { return }

        fputs("\n--- Agent Diagnostic: \(skillName) ---\n", stderr)

        for rec in recommendations {
            let label = rec.label.map { " \"\($0)\"" } ?? ""
            fputs("\nStep \(rec.stepIndex + 1) [\(rec.stepType)\(label)]:\n", stderr)
            fputs("  Diagnosis: \(rec.diagnosis)\n", stderr)

            for patch in rec.patches {
                fputs("  Fix: \(patch.field): \(patch.was) -> \(patch.shouldBe)\n", stderr)
            }
        }

        if recommendations.contains(where: { !$0.patches.isEmpty }) {
            fputs("\nRecommendation: recompile with `mirroir compile` or apply patches manually.\n", stderr)
        }

        fputs("---\n", stderr)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: - AI Diagnosis

    /// Build a diagnostic payload from deterministic recommendations for AI analysis.
    static func buildPayload(
        recommendations: [Recommendation],
        skillName: String,
        skillFilePath: String
    ) -> DiagnosticPayload {
        let steps = recommendations.map { rec in
            DiagnosticPayload.FailedStep(
                stepIndex: rec.stepIndex,
                stepType: rec.stepType,
                label: rec.label,
                deterministicDiagnosis: rec.diagnosis,
                patches: rec.patches.map { p in
                    DiagnosticPayload.PatchInfo(
                        field: p.field, was: p.was, shouldBe: p.shouldBe)
                }
            )
        }
        return DiagnosticPayload(
            skillName: skillName,
            skillFilePath: skillFilePath,
            failedSteps: steps)
    }

    /// Print AI diagnosis results to stderr.
    static func printAIReport(diagnosis: AIDiagnosis, skillName: String) {
        fputs("\n--- AI Diagnosis (\(diagnosis.modelUsed)): \(skillName) ---\n", stderr)
        fputs("\nAnalysis: \(diagnosis.analysis)\n", stderr)

        if !diagnosis.suggestedFixes.isEmpty {
            fputs("\nSuggested Fixes:\n", stderr)
            for fix in diagnosis.suggestedFixes {
                fputs("  \(fix.field): \(fix.was) -> \(fix.shouldBe)\n", stderr)
            }
        }

        fputs("Confidence: \(diagnosis.confidence)\n", stderr)
        fputs("---\n", stderr)
    }
}

/// Diagnostic context sent to an AI agent for analysis.
struct DiagnosticPayload: Codable {
    let skillName: String
    let skillFilePath: String
    let failedSteps: [FailedStep]

    struct FailedStep: Codable {
        let stepIndex: Int
        let stepType: String
        let label: String?
        let deterministicDiagnosis: String
        let patches: [PatchInfo]
    }

    struct PatchInfo: Codable {
        let field: String
        let was: String
        let shouldBe: String
    }
}
