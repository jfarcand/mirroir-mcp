// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Executes a scene: step: loads its kind:game skill, plays it through SceneLoop, maps the verdict to a step status.
// ABOUTME: Pass passes; a fail predicate or a broken run fails; a spent budget is inconclusive, never a pass.

import Foundation
import HelperLib

extension StepExecutor {

    /// Play the scene skill `skill` under `budget` and report what it did.
    func executeScene(
        skill: String, budget: SceneBudget, stepIndex: Int, skillName: String,
        startTime: CFAbsoluteTime
    ) -> StepResult {
        let step = SkillStep.scene(skill: skill, budget: budget)
        guard let vision else {
            return StepResult(step: step, status: .failed,
                              message: "no vision model is configured to play the scene",
                              durationSeconds: elapsed(startTime))
        }
        let header: SceneHeader
        switch SceneSkills.load(name: skill) {
        case .success(let loaded):
            header = loaded
        case .failure(let error):
            return StepResult(step: step, status: .failed, message: error.localizedDescription,
                              durationSeconds: elapsed(startTime))
        }
        let loop = SceneLoop(dependencies: SceneLoop.Dependencies(
            bridge: bridge, describer: ocrDescriber, input: input, vision: vision,
            now: { CFAbsoluteTimeGetCurrent() }, sleep: { usleep($0) },
            settleMs: config.settlingDelayMs,
            imageWidth: EnvConfig.visionImageWidth,
            callTimeoutSeconds: EnvConfig.embacleTimeoutSeconds))
        let evidence = SceneEvidenceWriter(
            baseDir: config.screenshotDir, skillName: skillName, stepIndex: stepIndex)
        let report = loop.run(header: header, budget: budget, evidence: evidence)
        let status: StepResult.StepStatus
        switch report.verdict {
        case .pass: status = .passed
        case .fail: status = .failed
        case .inconclusive: status = .inconclusive
        }
        let message = report.failureLine
            ?? "passed in \(report.frames) frames, \(report.totalTokens) tokens"
        return StepResult(step: step, status: status, message: message,
                          durationSeconds: elapsed(startTime), scene: report)
    }
}
