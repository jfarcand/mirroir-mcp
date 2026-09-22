// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pure step computation for pinch and rotate: frame count, per-frame deltas, and the event sequence.
// ABOUTME: Produces GestureSteps (pointer move, then began, changed x n, ended) without touching CGEvent.

import Foundation

/// Turns a pinch or rotate into the timed event sequence a real trackpad posts.
///
/// The sequence is a pointer move to the centre, a `began` event, `n` `changed`
/// events paced by `FramePacing` (~60fps), and an `ended` event, with a bare container event before
/// each sub-gesture event. iOS multiplies the finger spread by `1 + delta` on
/// every zoom `changed` event, so each delta is `scale^(1/n) - 1` and the spread
/// ends at exactly `scale`; each rotate delta is `degrees / n`.
enum GesturePlanner {

    /// Microseconds to let iPhone Mirroring register the pointer at the
    /// centre before the gesture opens (the same settle swipe uses).
    static let pointerSettleUs: UInt32 = 50_000

    /// The per-frame delta of every `changed` event.
    static func deltas(for gesture: TwoFingerGesture, frames: Int) -> [Double] {
        let perFrame: Double
        switch gesture {
        case .pinch(let scale):
            // scale^(1/n) - 1, computed without cancellation near 1.
            perFrame = expm1(log(scale) / Double(frames))
        case .rotate(let degrees):
            perFrame = degrees / Double(frames)
        }
        return Array(repeating: perFrame, count: frames)
    }

    /// The subtype a gesture's events carry.
    static func kind(of gesture: TwoFingerGesture) -> GestureKind {
        switch gesture {
        case .pinch: return .zoom
        case .rotate: return .rotate
        }
    }

    /// The full timed event sequence for `gesture` over `durationMs`.
    static func steps(for gesture: TwoFingerGesture, durationMs: Int) -> [GestureStep] {
        let frames = FramePacing.frameCount(durationMs: durationMs)
        let frameUs = FramePacing.frameUs(durationMs: durationMs, frames: frames)
        let kind = kind(of: gesture)

        var steps = [GestureStep(events: [.pointerMove], pauseAfterUs: pointerSettleUs)]
        steps.reserveCapacity(frames + 3)
        steps.append(subGesture(kind, .began, delta: 0, pauseAfterUs: frameUs))
        for delta in deltas(for: gesture, frames: frames) {
            steps.append(subGesture(kind, .changed, delta: delta, pauseAfterUs: frameUs))
        }
        steps.append(subGesture(kind, .ended, delta: 0, pauseAfterUs: 0))
        return steps
    }

    private static func subGesture(_ kind: GestureKind, _ phase: GesturePhase, delta: Double,
                                   pauseAfterUs: UInt32) -> GestureStep {
        GestureStep(events: [.container, .gesture(kind, phase, delta: delta)],
                    pauseAfterUs: pauseAfterUs)
    }
}
