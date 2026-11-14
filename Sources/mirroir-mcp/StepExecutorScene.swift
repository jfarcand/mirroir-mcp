/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Executes a scene: step: loads its kind:game skill, plays it through SceneLoop, maps the verdict to a step status.
// ABOUTME: Pass passes; a fail predicate or a broken run fails; a spent budget is inconclusive, never a pass.

import Foundation
import HelperLib

extension StepExecutor {

    /// Play the scene skill `skill` under `budget`, with the move picker
    /// `decider` (or `MIRROIR_SCENE_DECIDER`) when the skill needs one, and
    /// report what it did.
    func executeScene(
        skill: String, budget: SceneBudget, decider: String?, stepIndex: Int, skillName: String,
        startTime: CFAbsoluteTime
    ) -> StepResult {
        let step = SkillStep.scene(skill: skill, budget: budget, decider: decider)
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
        let picker = header.needsDecider
            ? (decider ?? EnvConfig.sceneDecider).flatMap { CommandSceneDecider(command: $0) }
            : nil
        let loop = SceneLoop(dependencies: SceneLoop.Dependencies(
            bridge: bridge, describer: ocrDescriber, input: input, vision: vision,
            now: { CFAbsoluteTimeGetCurrent() }, sleep: { usleep($0) },
            settleMs: config.settlingDelayMs,
            imageWidth: EnvConfig.visionImageWidth,
            callTimeoutSeconds: EnvConfig.embacleTimeoutSeconds,
            decider: picker))
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
