// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Replays compiled skill steps from cached hints, checking each against the live screen.
// ABOUTME: Labeled taps and scroll_to verify by OCR; passthrough steps run live through StepExecutor.

import Foundation
import HelperLib

/// Replays compiled skill steps using cached hints, failing any step whose effect the
/// screen does not show. Labeled taps check their element by OCR before tapping,
/// assertions wait their recorded delay then check live, scroll_to steps replay their
/// swipe sequence then require the target, and every other step (`wait_for` included)
/// runs live through `StepExecutor`.
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
         config: StepExecutorConfig = .default,
         registry: TargetRegistry? = nil) {
        self.bridge = bridge
        self.input = input
        self.describer = describer
        self.capture = capture
        self.config = config
        self.normalExecutor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: config,
            registry: registry
        )
    }

    /// Execute a compiled step using cached hints.
    func execute(step: SkillStep, compiledStep: CompiledStep,
                 stepIndex: Int, skillName: String) -> StepResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        if let stepType = step.aiOnlyStepType {
            return .notEvaluated(step, stepType: stepType)
        }

        guard let hints = compiledStep.hints else {
            // Nothing was recorded to replay it from, so the step runs live, as
            // `passthrough` does: the skill is checked by what it says, never
            // skipped past.
            return normalExecutor.execute(step: step, stepIndex: stepIndex,
                                          skillName: skillName)
        }

        switch hints.compiledAction {
        case .tap:
            return executeTap(step: step, hints: hints, startTime: startTime)
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

    /// A labeled tap is checked by one OCR call before it is sent: its element at the
    /// recorded spot is tapped there, an element found elsewhere is tapped where it is
    /// now, and an element OCR cannot find fails the step. A tap recorded by
    /// coordinates alone (an icon with no text) has nothing to find, so the screen it
    /// reaches must match the one recorded.
    private func executeTap(step: SkillStep, hints: StepHints,
                            startTime: CFAbsoluteTime) -> StepResult {
        guard case .tap(let label) = step else {
            return mismatch(step: step, hints: hints, startTime: startTime)
        }
        guard let x = hints.tapX, let y = hints.tapY else {
            return StepResult(step: step, status: .failed,
                              message: "compiled tap missing coordinates",
                              durationSeconds: elapsed(startTime))
        }
        guard !label.isEmpty else {
            return executeCoordinateTap(step: step, x: x, y: y,
                                        arrival: hints.arrivalFingerprint,
                                        startTime: startTime)
        }

        guard let screen = describer.describe() else {
            return StepResult(step: step, status: .failed,
                              message: "Failed to capture screen for OCR",
                              durationSeconds: elapsed(startTime))
        }
        guard let match = ElementMatcher.findMatch(label: label, in: screen.elements,
                                                  nearestTo: (x, y)) else {
            return StepResult(step: step, status: .failed,
                              message: "Element \"\(label)\" not found on screen; compiled tap at "
                                + "(\(fmt(x)), \(fmt(y))) not sent. Visible: [\(visibleTexts(screen))]",
                              durationSeconds: elapsed(startTime))
        }

        let tolerance = EnvConfig.compiledTapPositionTolerance
        let liveX = match.element.tapX
        let liveY = match.element.tapY
        if abs(liveX - x) <= tolerance && abs(liveY - y) <= tolerance {
            let strategy = hints.matchStrategy ?? "compiled"
            return sendTap(step: step, x: x, y: y,
                           message: "compiled tap via \(strategy), \"\(label)\" verified at recorded position",
                           startTime: startTime)
        }
        return sendTap(step: step, x: liveX, y: liveY,
                       message: "\"\(label)\" moved from recorded (\(fmt(x)), \(fmt(y))) "
                         + "to (\(fmt(liveX)), \(fmt(liveY))); tapped where it is now",
                       startTime: startTime)
    }

    /// A tap recorded by coordinates alone (an icon with no text): nothing to find
    /// before it, so the screen proves it instead. The screen before the tap must
    /// not already be the recorded destination — otherwise even a dropped tap
    /// would look like it worked — and the screen after it must become that
    /// destination within the `wait_for` timeout.
    private func executeCoordinateTap(step: SkillStep, x: Double, y: Double,
                                      arrival: ScreenFingerprint?,
                                      startTime: CFAbsoluteTime) -> StepResult {
        let spot = "(\(fmt(x)), \(fmt(y)))"
        guard let arrival else {
            return failed(step, "compiled coordinate-only tap at \(spot) has no recorded "
                + "screen to check it against; recompile the skill", startTime)
        }
        guard ArrivalCheck.isCheckable(arrival) else {
            return failed(step, "compiled coordinate-only tap at \(spot) leads to a screen with "
                + "too little text to tell it apart, so it cannot be checked", startTime)
        }
        guard let before = CompileCommand.screenFingerprint(describer: describer) else {
            return failed(step, "Failed to capture the screen before the compiled tap at \(spot), "
                + "so it could not be checked", startTime)
        }
        if ArrivalCheck.matches(arrival, before) {
            return failed(step, "compiled tap at \(spot) not sent: the screen already matches the "
                + "one it leads to, so the tap could not be proven", startTime)
        }

        let tapped = sendTap(step: step, x: x, y: y, message: "", startTime: startTime)
        guard tapped.status == .passed else { return tapped }

        let deadline = CFAbsoluteTimeGetCurrent() + Double(config.waitForTimeoutSeconds)
        var best: Double?
        repeat {
            if let reached = CompileCommand.screenFingerprint(describer: describer) {
                let similarity = ArrivalCheck.similarity(arrival, reached)
                best = max(best ?? 0, similarity)
                if similarity >= StructuralFingerprint.similarityThreshold {
                    return StepResult(step: step, status: .passed,
                                      message: "compiled tap at recorded \(spot) reached the "
                                        + "recorded screen (similarity \(score(similarity)))",
                                      durationSeconds: elapsed(startTime))
                }
            }
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            usleep(EnvConfig.waitForPollIntervalUs)
        } while true

        guard let best else {
            return failed(step, "Failed to capture the screen after the compiled tap at \(spot), "
                + "so it could not be checked", startTime)
        }
        return failed(step, "compiled tap at \(spot) did not reach the recorded screen within "
            + "\(config.waitForTimeoutSeconds)s (best similarity \(score(best)) < "
            + "\(StructuralFingerprint.similarityThreshold))", startTime)
    }

    private func failed(_ step: SkillStep, _ message: String,
                        _ startTime: CFAbsoluteTime) -> StepResult {
        StepResult(step: step, status: .failed, message: message,
                   durationSeconds: elapsed(startTime))
    }

    private func score(_ similarity: Double) -> String {
        String(format: "%.2f", similarity)
    }

    private func sendTap(step: SkillStep, x: Double, y: Double, message: String,
                         startTime: CFAbsoluteTime) -> StepResult {
        if let error = input.tap(x: x, y: y) {
            return StepResult(step: step, status: .failed, message: error,
                              durationSeconds: elapsed(startTime))
        }
        usleep(config.settlingDelayMs * 1000)
        return StepResult(step: step, status: .passed, message: message,
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

    /// Replays the recorded scrolls, then requires the target on screen. A target still
    /// missing gets one extra scroll in the same direction; missing after that, the
    /// step fails.
    private func executeScrollSequence(step: SkillStep, hints: StepHints,
                                        startTime: CFAbsoluteTime) -> StepResult {
        guard case .scrollTo(let label, _, _) = step else {
            return mismatch(step: step, hints: hints, startTime: startTime)
        }
        let count = hints.scrollCount ?? 0
        let direction = hints.scrollDirection ?? "up"

        guard let windowInfo = bridge.getWindowInfo() else {
            return StepResult(step: step, status: .failed,
                              message: "Could not get window info for compiled scroll",
                              durationSeconds: elapsed(startTime))
        }
        guard let ep = normalExecutor.swipeEndpoints(direction: direction,
                                                     windowInfo: windowInfo) else {
            return StepResult(step: step, status: .failed,
                              message: "Unknown compiled scroll direction: \(direction)",
                              durationSeconds: elapsed(startTime))
        }

        for i in 0..<count {
            if let error = swipe(ep) {
                return StepResult(step: step, status: .failed,
                                  message: "Compiled scroll \(i + 1)/\(count) failed: \(error)",
                                  durationSeconds: elapsed(startTime))
            }
        }

        if isVisible(label) {
            return StepResult(step: step, status: .passed,
                              message: "compiled \(count) scroll(s) \(direction), target verified",
                              durationSeconds: elapsed(startTime))
        }

        if let error = swipe(ep) {
            return StepResult(step: step, status: .failed,
                              message: "Compiled extra scroll failed: \(error)",
                              durationSeconds: elapsed(startTime))
        }
        if isVisible(label) {
            return StepResult(step: step, status: .passed,
                              message: "compiled \(count + 1) scroll(s) \(direction), target verified after extra scroll",
                              durationSeconds: elapsed(startTime))
        }

        return StepResult(step: step, status: .failed,
                          message: "compiled \(count + 1) scroll(s) \(direction), target \"\(label)\" not found after OCR verification",
                          durationSeconds: elapsed(startTime))
    }

    // MARK: - Helpers

    private func swipe(_ ep: StepExecutor.SwipeEndpoints) -> String? {
        let error = input.swipe(fromX: ep.fromX, fromY: ep.fromY, toX: ep.toX, toY: ep.toY,
                                durationMs: EnvConfig.defaultSwipeDurationMs)
        usleep(config.settlingDelayMs * 1000)
        return error
    }

    private func isVisible(_ label: String) -> Bool {
        guard let screen = describer.describe() else { return false }
        return ElementMatcher.isVisible(label: label, in: screen.elements)
    }

    private func visibleTexts(_ screen: ScreenDescriber.DescribeResult) -> String {
        screen.elements.map(\.text).joined(separator: ", ")
    }

    /// A hint recorded for another kind of step: replay pairs steps by position, so the
    /// compiled file no longer describes this skill.
    private func mismatch(step: SkillStep, hints: StepHints,
                          startTime: CFAbsoluteTime) -> StepResult {
        StepResult(step: step, status: .failed,
                   message: "compiled \(hints.compiledAction.rawValue) hint does not fit a "
                     + "\(step.typeKey) step; recompile the skill",
                   durationSeconds: elapsed(startTime))
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func elapsed(_ startTime: CFAbsoluteTime) -> Double {
        CFAbsoluteTimeGetCurrent() - startTime
    }
}
