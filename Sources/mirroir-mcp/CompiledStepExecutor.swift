// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Replays compiled skill steps with zero OCR by using cached coordinates and timing.
// ABOUTME: Falls through to the normal StepExecutor for passthrough steps that are already OCR-free.

import Foundation
import HelperLib

/// Replays compiled skill steps using cached hints instead of live OCR.
/// Tap steps use recorded coordinates, wait_for/assert steps use recorded delays,
/// and scroll_to steps replay exact swipe sequences.
final class CompiledStepExecutor {
    private let bridge: any WindowBridging
    private let input: InputProviding
    private let describer: ScreenDescribing
    private let capture: ScreenCapturing
    private let normalExecutor: StepExecutor
    private let config: StepExecutorConfig

    /// Extra milliseconds added to observed delays for safety margin.
    static var sleepBufferMs: Int { EnvConfig.compiledSleepBufferMs }

    init(bridge: any WindowBridging,
         input: InputProviding,
         describer: ScreenDescribing,
         capture: ScreenCapturing,
         config: StepExecutorConfig = .default) {
        self.bridge = bridge
        self.input = input
        self.describer = describer
        self.capture = capture
        self.config = config
        self.normalExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )
    }

    /// Execute a compiled step using cached hints.
    func execute(step: SkillStep, compiledStep: CompiledStep,
                 stepIndex: Int, skillName: String) -> StepResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let hints = compiledStep.hints else {
            // No hints (AI-only step) — skip
            return StepResult(step: step, status: .skipped,
                              message: "no compiled hints",
                              durationSeconds: elapsed(startTime))
        }

        switch hints.compiledAction {
        case .tap:
            return executeTap(step: step, hints: hints,
                              stepIndex: stepIndex, skillName: skillName,
                              startTime: startTime)
        case .sleep:
            return executeSleep(step: step, hints: hints, startTime: startTime)
        case .assertion:
            return executeAssertion(step: step, hints: hints,
                                     stepIndex: stepIndex, skillName: skillName,
                                     startTime: startTime)
        case .scrollSequence:
            return executeScrollSequence(step: step, hints: hints, startTime: startTime)
        case .passthrough:
            return normalExecutor.execute(step: step, stepIndex: stepIndex,
                                           skillName: skillName)
        }
    }

    // MARK: - Compiled Actions

    private func executeTap(step: SkillStep, hints: StepHints,
                            stepIndex: Int, skillName: String,
                            startTime: CFAbsoluteTime) -> StepResult {
        // Confidence gating: if compiled confidence is below threshold, fall back to live OCR
        let confidence = Double(hints.confidence ?? 1.0)
        let minConfidence = EnvConfig.compiledTapMinConfidence
        if confidence < minConfidence {
            fputs("  Warning: compiled tap confidence \(String(format: "%.2f", confidence)) < \(String(format: "%.2f", minConfidence)) — falling back to live OCR\n", stderr)
            return normalExecutor.execute(step: step, stepIndex: stepIndex,
                                           skillName: skillName)
        }

        guard let x = hints.tapX, let y = hints.tapY else {
            return StepResult(step: step, status: .failed,
                              message: "compiled tap missing coordinates",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.tap(x: x, y: y) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        // Inter-step settling delay
        usleep(config.settlingDelayMs * 1000)

        // Optional post-tap verification via OCR
        if EnvConfig.verifyTaps {
            if let screen = describer.describe() {
                if let label = step.labelValue,
                   let match = ElementMatcher.findMatch(label: label, in: screen.elements) {
                    let dx = abs(match.element.tapX - x)
                    let dy = abs(match.element.tapY - y)
                    if dx < 5 && dy < 5 {
                        fputs("  Warning: tap target \"\(label)\" still at same position — navigation may not have occurred\n", stderr)
                    }
                }
            }
        }

        let strategy = hints.matchStrategy ?? "compiled"
        return StepResult(step: step, status: .passed,
                          message: "compiled tap via \(strategy)",
                          durationSeconds: elapsed(startTime))
    }

    private func executeAssertion(step: SkillStep, hints: StepHints,
                                   stepIndex: Int, skillName: String,
                                   startTime: CFAbsoluteTime) -> StepResult {
        let delayMs = (hints.observedDelayMs ?? 0) + Self.sleepBufferMs
        if delayMs > 0 {
            usleep(UInt32(delayMs) * 1000)
        }

        // Delegate to the normal StepExecutor for real OCR verification
        return normalExecutor.execute(step: step, stepIndex: stepIndex,
                                       skillName: skillName)
    }

    private func executeSleep(step: SkillStep, hints: StepHints,
                              startTime: CFAbsoluteTime) -> StepResult {
        let delayMs = (hints.observedDelayMs ?? 0) + Self.sleepBufferMs
        if delayMs > 0 {
            usleep(UInt32(delayMs) * 1000)
        }

        return StepResult(step: step, status: .passed,
                          message: "compiled sleep \(delayMs)ms",
                          durationSeconds: elapsed(startTime))
    }

    private func executeScrollSequence(step: SkillStep, hints: StepHints,
                                        startTime: CFAbsoluteTime) -> StepResult {
        let count = hints.scrollCount ?? 0
        let direction = hints.scrollDirection ?? "up"

        if count == 0 {
            return StepResult(step: step, status: .passed,
                              message: "compiled scroll: already visible",
                              durationSeconds: elapsed(startTime))
        }

        guard let windowInfo = bridge.getWindowInfo() else {
            return StepResult(step: step, status: .failed,
                              message: "Could not get window info for compiled scroll",
                              durationSeconds: elapsed(startTime))
        }

        let centerX = Double(windowInfo.size.width) / 2.0
        let centerY = Double(windowInfo.size.height) / 2.0
        let swipeDistance = Double(windowInfo.size.height) * EnvConfig.swipeDistanceFraction

        for i in 0..<count {
            let fromX: Double, fromY: Double, toX: Double, toY: Double
            switch direction.lowercased() {
            case "up":
                fromX = centerX; fromY = centerY + swipeDistance / 2
                toX = centerX; toY = centerY - swipeDistance / 2
            case "down":
                fromX = centerX; fromY = centerY - swipeDistance / 2
                toX = centerX; toY = centerY + swipeDistance / 2
            case "left":
                fromX = centerX + swipeDistance / 2; fromY = centerY
                toX = centerX - swipeDistance / 2; toY = centerY
            case "right":
                fromX = centerX - swipeDistance / 2; fromY = centerY
                toX = centerX + swipeDistance / 2; toY = centerY
            default:
                return StepResult(step: step, status: .failed,
                                  message: "Unknown compiled scroll direction: \(direction)",
                                  durationSeconds: elapsed(startTime))
            }

            if let error = input.swipe(fromX: fromX, fromY: fromY,
                                        toX: toX, toY: toY, durationMs: EnvConfig.defaultSwipeDurationMs) {
                return StepResult(step: step, status: .failed,
                                  message: "Compiled scroll \(i + 1)/\(count) failed: \(error)",
                                  durationSeconds: elapsed(startTime))
            }

            usleep(config.settlingDelayMs * 1000)
        }

        // Post-scroll OCR verification: check if the target label is visible
        if case .scrollTo(let label, _, _) = step {
            if let screen = describer.describe(),
               ElementMatcher.isVisible(label: label, in: screen.elements) {
                return StepResult(step: step, status: .passed,
                                  message: "compiled \(count) scroll(s) \(direction), target verified",
                                  durationSeconds: elapsed(startTime))
            }

            // Target not found — try one more scroll in each direction
            for extraDirection in [direction] {
                let fromX: Double, fromY: Double, toX: Double, toY: Double
                switch extraDirection.lowercased() {
                case "up":
                    fromX = centerX; fromY = centerY + swipeDistance / 2
                    toX = centerX; toY = centerY - swipeDistance / 2
                case "down":
                    fromX = centerX; fromY = centerY - swipeDistance / 2
                    toX = centerX; toY = centerY + swipeDistance / 2
                default:
                    fromX = centerX; fromY = centerY + swipeDistance / 2
                    toX = centerX; toY = centerY - swipeDistance / 2
                }

                _ = input.swipe(fromX: fromX, fromY: fromY,
                                 toX: toX, toY: toY, durationMs: EnvConfig.defaultSwipeDurationMs)
                usleep(config.settlingDelayMs * 1000)

                if let screen = describer.describe(),
                   ElementMatcher.isVisible(label: label, in: screen.elements) {
                    return StepResult(step: step, status: .passed,
                                      message: "compiled \(count + 1) scroll(s) \(direction), target verified after extra scroll",
                                      durationSeconds: elapsed(startTime))
                }
            }

            return StepResult(step: step, status: .failed,
                              message: "compiled \(count) scroll(s) \(direction), target \"\(label)\" not found after OCR verification",
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .passed,
                          message: "compiled \(count) scroll(s) \(direction)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - Helpers

    private func elapsed(_ startTime: CFAbsoluteTime) -> Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }
}
