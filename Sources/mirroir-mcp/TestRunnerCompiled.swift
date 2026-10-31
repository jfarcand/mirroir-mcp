// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Extension for TestRunner handling compiled skill execution and AI diagnosis.
// ABOUTME: Extracted from TestRunner.swift to keep each file under the 500-line limit.

import Foundation
import HelperLib

extension TestRunner {

    /// Execute a skill from its compiled hints, each step verified on the live screen.
    /// When `agent` is non-nil, failed steps trigger a diagnostic OCR call.
    /// When `agent` is a non-empty model name, AI diagnosis runs after deterministic analysis.
    /// `recorder`, when given, reads the settled screen after each step that ran.
    static func executeCompiledSkill(
        skill: SkillDefinition,
        compiled: CompiledSkill,
        compiledExecutor: CompiledStepExecutor,
        normalExecutor: StepExecutor,
        describer: ScreenDescribing,
        agent: String?,
        verbose: Bool,
        recorder: StepScreenRecorder? = nil
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
        // A diagnosis reports a step with its `${VAR}` placeholders, never their values.
        let placeholderSteps = agentEnabled
            ? (try? SkillFileLoader.load(filePath: skill.filePath, substitutingEnv: false))?.steps
            : nil

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
                        label: placeholderSteps?.count == stepCount
                            ? placeholderSteps?[index].replayValue : nil,
                        hints: StepHints.passthrough())
                    if let rec = AgentDiagnostic.diagnose(
                        step: step, compiledStep: synthStep,
                        failureMessage: result.message, describer: describer) {
                        recommendations.append(rec)
                    }
                }
            }

            recorder?.recordStep(index, result: result)
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

    /// The compiled skill each skill replays from, keyed by skill path: those whose
    /// compiled file matches the skill source, the format version and the window.
    /// A stale one — including one that no longer decodes, like an older format
    /// version — is named through `warn` and left out, so its skill runs on live
    /// OCR. The files are only read: `mirroir-mcp test` writes a `.compiled.json` only
    /// where `--compiled-out` names it.
    static func freshCompiledSkills(
        for skills: [SkillDefinition],
        windowWidth: Double,
        windowHeight: Double,
        warn: (String) -> Void = { fputs($0, stderr) }
    ) -> [String: CompiledSkill] {
        var compiledMap: [String: CompiledSkill] = [:]
        for skill in skills {
            let compiled: CompiledSkill?
            do {
                compiled = try CompiledSkillIO.load(for: skill.filePath)
            } catch {
                warn(staleWarning(skill.name, reason: CompiledSkillIO.unreadableStaleness(
                    skillPath: skill.filePath, error: error)))
                continue
            }
            guard let compiled else { continue }
            switch CompiledSkillIO.checkStaleness(
                compiled: compiled, skillPath: skill.filePath,
                windowWidth: windowWidth, windowHeight: windowHeight) {
            case .fresh:
                compiledMap[skill.filePath] = compiled
            case .stale(let reason):
                warn(staleWarning(skill.name, reason: reason))
            }
        }
        return compiledMap
    }

    /// The notice for a compiled skill left out of replay, one line.
    private static func staleWarning(_ skillName: String, reason: String) -> String {
        "Warning: compiled skill stale for \(skillName): \(reason)\n"
    }
}
