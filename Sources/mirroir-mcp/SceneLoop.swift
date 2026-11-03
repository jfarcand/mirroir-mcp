// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Plays one scene: read a frame, judge its OCR predicates, ask the model for one control, make that one touch.
// ABOUTME: A session accumulator that stops at its predicates or its frame/token/time budget, never past it.

import CoreGraphics
import Foundation
import HelperLib

/// One scene run. Lifecycle: `start`, then `step()` until it returns a stop
/// reason, then `finalize()`; `run` does all three.
///
/// Every frame is read once: the same read judges the predicates (OCR, never
/// the model), is shown to the model, and is kept as evidence. The token budget
/// is checked against the last frame's cost before asking again, and each model
/// call may take no longer than the time left, so the budget holds.
final class SceneLoop: @unchecked Sendable {

    /// What the loop reads, touches and asks, plus its clock.
    struct Dependencies {
        let bridge: any WindowBridging
        /// Local OCR: the predicates are judged on what it reads.
        let describer: any ScreenDescribing
        let input: any InputProviding
        let vision: any VisionCompleting
        /// Seconds since an arbitrary origin.
        let now: () -> Double
        let sleep: (UInt32) -> Void
        /// Milliseconds to let a touch's effect render before the next frame.
        let settleMs: UInt32
        /// Width the frame is resized to before it is sent.
        let imageWidth: Int
        /// The longest a single model call may take.
        let callTimeoutSeconds: Int
    }

    private let deps: Dependencies
    private let lock = NSLock()

    private var header: SceneHeader?
    private var budget = SceneBudget(maxFrames: 0, maxTokens: 0, maxSeconds: 0)
    private var evidence: SceneEvidenceWriter?
    private var systemPrompt = ""
    private var startTime = 0.0
    private var frames = 0
    private var promptTokens = 0
    private var completionTokens = 0
    private var lastFrameTokens = 0
    private var rejectedReplies = 0
    private var responseModel: String?
    private var stopReason: SceneStopReason?

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// Play `header` under `budget` from start to stop, writing evidence to `evidence`.
    func run(header: SceneHeader, budget: SceneBudget, evidence: SceneEvidenceWriter?) -> SceneReport {
        start(header: header, budget: budget, evidence: evidence)
        while step() == nil {}
        return finalize()
    }

    /// Begin a run. Resets every count.
    func start(header: SceneHeader, budget: SceneBudget, evidence: SceneEvidenceWriter?) {
        lock.lock()
        defer { lock.unlock() }
        self.header = header
        self.budget = budget
        self.evidence = evidence
        systemPrompt = ScenePrompt.systemPrompt(for: header)
        startTime = deps.now()
        frames = 0
        promptTokens = 0
        completionTokens = 0
        lastFrameTokens = 0
        rejectedReplies = 0
        responseModel = nil
        stopReason = nil
    }

    /// Play one frame. Returns why the scene stopped, or nil to play another.
    func step() -> SceneStopReason? {
        lock.lock()
        defer { lock.unlock() }
        if let stopReason { return stopReason }
        let reason = playFrame()
        stopReason = reason
        return reason
    }

    /// The run's report. Call after `step()` returned a stop reason.
    func finalize() -> SceneReport {
        lock.lock()
        defer { lock.unlock() }
        let reason = stopReason ?? .maxFrames
        return SceneReport(
            skill: header?.name ?? "",
            verdict: reason.verdict,
            reason: reason,
            frames: frames,
            framesToPredicate: reason == .success ? frames : nil,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens,
            seconds: deps.now() - startTime,
            model: deps.vision.model,
            responseModel: responseModel,
            rejectedReplies: rejectedReplies,
            evidenceDir: evidence?.directory ?? "")
    }

    // MARK: - Private (called with the lock held)

    private func playFrame() -> SceneStopReason? {
        guard let header else { return .perceptionFailed }
        let elapsed = deps.now() - startTime
        if elapsed >= Double(budget.maxSeconds) { return .maxSeconds }
        if frames >= budget.maxFrames { return .maxFrames }
        if frames > 0, promptTokens + completionTokens + lastFrameTokens > budget.maxTokens {
            return .maxTokens
        }

        guard let screen = deps.describer.describe(settleTimeoutUs: 0),
              screen.ocrFailure == nil,
              let png = Data(base64Encoded: screen.screenshotBase64) else {
            return .perceptionFailed
        }
        if let fail = header.fail, fail.isMet(by: screen.elements) { return .fail }
        if header.success.isMet(by: screen.elements) { return .success }

        let windowSize = deps.bridge.getWindowInfo()?.size ?? .zero
        let image = ImageResizer.resize(
            pngData: png, targetWidth: deps.imageWidth, windowSize: windowSize)?.base64
            ?? screen.screenshotBase64
        let remaining = Double(budget.maxSeconds) - elapsed
        let timeout = max(1, min(deps.callTimeoutSeconds, Int(remaining.rounded(.up))))
        guard let reply = deps.vision.complete(
            systemPrompt: systemPrompt,
            image: ChatCompletionImage(pngBase64: image, caption: "Frame \(frames + 1)."),
            timeoutSeconds: timeout) else {
            if deps.now() - startTime >= Double(budget.maxSeconds) { return .maxSeconds }
            frames += 1
            rejectedReplies += 1
            evidence?.record(frame: frames, png: png, screen: screen, reply: nil, action: nil, touch: nil)
            return nil
        }
        guard let usage = reply.usage else { return .usageMissing }
        frames += 1
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
        lastFrameTokens = usage.promptTokens + usage.completionTokens
        responseModel = reply.responseModel ?? responseModel

        guard let action = ScenePrompt.parseAction(reply.text, controls: header.controls) else {
            rejectedReplies += 1
            evidence?.record(frame: frames, png: png, screen: screen, reply: reply, action: nil, touch: nil)
            return nil
        }
        let touch = Self.touch(for: action, in: windowSize)
        if let error = perform(touch) {
            evidence?.record(frame: frames, png: png, screen: screen, reply: reply, action: action,
                             touch: "\(touch.summary) failed: \(error)")
            return .inputFailed
        }
        evidence?.record(frame: frames, png: png, screen: screen, reply: reply, action: action,
                         touch: touch.summary)
        deps.sleep(deps.settleMs * 1000)
        return nil
    }

    /// One touch in window points.
    enum Touch: Equatable {
        case tap(x: Double, y: Double)
        case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
        case hold(x: Double, y: Double, ms: Int)

        var summary: String {
            switch self {
            case .tap(let x, let y): return "tap \(Int(x)),\(Int(y))"
            case .drag(let fx, let fy, let tx, let ty):
                return "drag \(Int(fx)),\(Int(fy)) -> \(Int(tx)),\(Int(ty))"
            case .hold(let x, let y, let ms): return "hold \(Int(x)),\(Int(y)) \(ms)ms"
            }
        }
    }

    /// The touch `action` makes in a window of `size`. Fractions scale per frame,
    /// so the controls follow the window's orientation; a drag radius is a
    /// fraction of the window's shorter side.
    static func touch(for action: SceneAction, in size: CGSize) -> Touch {
        let width = Double(size.width)
        let height = Double(size.height)
        switch action.control.gesture {
        case .tap(let x, let y):
            return .tap(x: x * width, y: y * height)
        case .hold(let x, let y, let ms):
            return .hold(x: x * width, y: y * height, ms: ms)
        case .drag(let x, let y, let radius):
            let vector = (action.direction ?? .up).vector
            let reach = radius * min(width, height)
            return .drag(fromX: x * width, fromY: y * height,
                         toX: x * width + vector.dx * reach, toY: y * height + vector.dy * reach)
        }
    }

    private func perform(_ touch: Touch) -> String? {
        switch touch {
        case .tap(let x, let y):
            return deps.input.tap(x: x, y: y)
        case .hold(let x, let y, let ms):
            return deps.input.longPress(x: x, y: y, durationMs: ms, cursorMode: nil)
        case .drag(let fromX, let fromY, let toX, let toY):
            return deps.input.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                   durationMs: EnvConfig.defaultDragDurationMs)
        }
    }
}
