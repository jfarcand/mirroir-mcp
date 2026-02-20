// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Replays compiled scenario steps with zero OCR by using cached coordinates and timing.
// ABOUTME: Falls through to the normal StepExecutor for passthrough steps that are already OCR-free.

import Foundation
import HelperLib

/// Replays compiled scenario steps using cached hints instead of live OCR.
/// Tap steps use recorded coordinates, wait_for/assert steps use recorded delays,
/// and scroll_to steps replay exact swipe sequences.
final class CompiledStepExecutor {
    private let bridge: any WindowBridging
    private let input: InputProviding
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
        self.capture = capture
        self.config = config
        self.normalExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config
        )
    }

    /// Execute a compiled step using cached hints.
    func execute(step: ScenarioStep, compiledStep: CompiledStep,
                 stepIndex: Int, scenarioName: String) -> StepResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let hints = compiledStep.hints else {
            // No hints (AI-only step) — skip
            return StepResult(step: step, status: .skipped,
                              message: "no compiled hints",
                              durationSeconds: elapsed(startTime))
        }

        switch hints.compiledAction {
        case .tap:
            return executeTap(step: step, hints: hints, startTime: startTime)
        case .sleep:
            return executeSleep(step: step, hints: hints, startTime: startTime)
        case .scrollSequence:
            return executeScrollSequence(step: step, hints: hints, startTime: startTime)
        case .passthrough:
            return normalExecutor.execute(step: step, stepIndex: stepIndex,
                                           scenarioName: scenarioName)
        }
    }

    // MARK: - Compiled Actions

    private func executeTap(step: ScenarioStep, hints: StepHints,
                            startTime: CFAbsoluteTime) -> StepResult {
        guard let x = hints.tapX, let y = hints.tapY else {
            return StepResult(step: step, status: .failed,
                              message: "compiled tap missing coordinates",
                              durationSeconds: elapsed(startTime))
        }

        if let error = input.tap(x: x, y: y) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }

        let strategy = hints.matchStrategy ?? "compiled"
        let result = StepResult(step: step, status: .passed,
                                message: "compiled tap via \(strategy)",
                                durationSeconds: elapsed(startTime))

        // Inter-step settling delay
        usleep(config.settlingDelayMs * 1000)

        return result
    }

    private func executeSleep(step: ScenarioStep, hints: StepHints,
                              startTime: CFAbsoluteTime) -> StepResult {
        let delayMs = (hints.observedDelayMs ?? 0) + Self.sleepBufferMs
        if delayMs > 0 {
            usleep(UInt32(delayMs) * 1000)
        }

        return StepResult(step: step, status: .passed,
                          message: "compiled sleep \(delayMs)ms",
                          durationSeconds: elapsed(startTime))
    }

    private func executeScrollSequence(step: ScenarioStep, hints: StepHints,
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

        return StepResult(step: step, status: .passed,
                          message: "compiled \(count) scroll(s) \(direction)",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - Helpers

    private func elapsed(_ startTime: CFAbsoluteTime) -> Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }
}
