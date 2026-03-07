// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Extension for TestRunner handling compiled skill execution and AI diagnosis.
// ABOUTME: Extracted from TestRunner.swift to keep each file under the 500-line limit.

import Foundation
import HelperLib

extension TestRunner {

    /// Execute a skill using compiled hints for OCR-free replay.
    /// When `agent` is non-nil, failed steps trigger a diagnostic OCR call.
    /// When `agent` is a non-empty model name, AI diagnosis runs after deterministic analysis.
    static func executeCompiledSkill(
        skill: SkillDefinition,
        compiled: CompiledSkill,
        compiledExecutor: CompiledStepExecutor,
        normalExecutor: StepExecutor,
        describer: ScreenDescribing,
        agent: String?,
        verbose: Bool
    ) -> ConsoleReporter.SkillResult {
        let agentEnabled = agent != nil
        let stepCount = skill.steps.count
        let tag: String
        if let modelName = agent, !modelName.isEmpty {
            tag = " [compiled+agent:\(modelName)]"
        } else if agentEnabled {
            tag = " [compiled+agent]"
        } else {
            tag = " [compiled]"
        }
        ConsoleReporter.reportSkillStart(
            name: skill.name + tag,
            filePath: skill.filePath, stepCount: stepCount)

        let startTime = CFAbsoluteTimeGetCurrent()
        var stepResults: [StepResult] = []
        var stopOnFailure = false
        var recommendations: [AgentDiagnostic.Recommendation] = []

        for (index, step) in skill.steps.enumerated() {
            if stopOnFailure {
                let skippedResult = StepResult(
                    step: step, status: .skipped,
                    message: "Skipped due to previous failure",
                    durationSeconds: 0)
                stepResults.append(skippedResult)
                ConsoleReporter.reportStep(index: index, total: stepCount,
                                           result: skippedResult, verbose: verbose)
                continue
            }

            let result: StepResult
            if index < compiled.steps.count {
                let compiledStep = compiled.steps[index]
                result = compiledExecutor.execute(
                    step: step, compiledStep: compiledStep,
                    stepIndex: index, skillName: skill.name)

                // Agent diagnostic on failure
                if agentEnabled && result.status == .failed {
                    if let rec = AgentDiagnostic.diagnose(
                        step: step, compiledStep: compiledStep,
                        failureMessage: result.message, describer: describer) {
                        recommendations.append(rec)
                    }
                }
            } else {
                result = normalExecutor.execute(
                    step: step, stepIndex: index, skillName: skill.name)

                // Agent diagnostic on normal step failure within a compiled skill
                if agentEnabled && result.status == .failed {
                    let synthStep = CompiledStep(
                        index: index, type: step.typeKey,
                        label: step.labelValue,
                        hints: StepHints.passthrough())
                    if let rec = AgentDiagnostic.diagnose(
                        step: step, compiledStep: synthStep,
                        failureMessage: result.message, describer: describer) {
                        recommendations.append(rec)
                    }
                }
            }

            stepResults.append(result)
            ConsoleReporter.reportStep(index: index, total: stepCount,
                                       result: result, verbose: verbose)

            if result.status == .failed {
                stopOnFailure = true
            }
        }

        // Print deterministic diagnostic report
        if agentEnabled && !recommendations.isEmpty {
            AgentDiagnostic.printReport(recommendations: recommendations,
                                         skillName: skill.name)
        }

        // Run AI diagnosis if a model name was specified
        if let modelName = agent, !modelName.isEmpty, !recommendations.isEmpty {
            runAIDiagnosis(
                modelName: modelName,
                recommendations: recommendations,
                skillName: skill.name,
                skillFilePath: skill.filePath)
        }

        let totalDuration = CFAbsoluteTimeGetCurrent() - startTime
        let skillResult = ConsoleReporter.SkillResult(
            name: skill.name,
            filePath: skill.filePath,
            stepResults: stepResults,
            durationSeconds: totalDuration
        )
        ConsoleReporter.reportSkillEnd(result: skillResult)
        return skillResult
    }

    /// Resolve and invoke the AI agent for diagnosis. Errors are non-fatal warnings.
    static func runAIDiagnosis(
        modelName: String,
        recommendations: [AgentDiagnostic.Recommendation],
        skillName: String,
        skillFilePath: String
    ) {
        guard let agentConfig = AIAgentRegistry.resolve(name: modelName) else {
            let available = AIAgentRegistry.availableAgents().joined(separator: ", ")
            fputs("Error: Unknown agent '\(modelName)'. Available: \(available)\n", stderr)
            return
        }

        guard let provider = AIAgentRegistry.createProvider(config: agentConfig) else {
            fputs("Warning: Could not create provider for agent '\(modelName)'\n", stderr)
            return
        }

        let payload = AgentDiagnostic.buildPayload(
            recommendations: recommendations,
            skillName: skillName,
            skillFilePath: skillFilePath)

        if let diagnosis = provider.diagnose(payload: payload) {
            AgentDiagnostic.printAIReport(diagnosis: diagnosis, skillName: skillName)
        }
    }

    /// Auto-recompile a drifted skill and return the fresh compiled result.
    /// Returns nil if recompilation fails or is disabled.
    static func autoRecompile(
        skill: SkillDefinition,
        bridge: MirroringBridge,
        input: InputSimulation,
        describer: ScreenDescriber,
        capture: ScreenCapture,
        config: StepExecutorConfig
    ) -> CompiledSkill? {
        let windowInfo = bridge.getWindowInfo()
        let windowWidth = windowInfo.map { Double($0.size.width) } ?? 0
        let windowHeight = windowInfo.map { Double($0.size.height) } ?? 0
        let orientation = bridge.getOrientation()?.rawValue ?? "portrait"

        let recordingDescriber = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: config
        )

        fputs("  Auto-recompiling \(skill.name)...\n", stderr)

        guard let compiled = CompileCommand.compileSkill(
            skill: skill,
            executor: executor,
            recordingDescriber: recordingDescriber,
            filePath: skill.filePath,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            orientation: orientation
        ) else {
            fputs("  Auto-recompile FAILED for \(skill.name)\n", stderr)
            return nil
        }

        do {
            try CompiledSkillIO.save(compiled, for: skill.filePath)
            fputs("  Auto-recompile OK for \(skill.name)\n", stderr)
            return compiled
        } catch {
            fputs("  Auto-recompile save failed: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
