// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Computes per-frame scroll wheel deltas for swipe gestures: a drag
// ABOUTME: phase plus an exponentially decaying momentum tail for fast flicks.

import Foundation

/// One frame of a synthesized scroll gesture.
/// `wheel1` is the vertical axis, `wheel2` the horizontal axis, matching
/// the CGEvent scroll wheel numbering.
struct SwipeWheelStep: Equatable {
    let wheel1: Int32
    let wheel2: Int32
}

/// Pure computation of the frame-by-frame deltas for a swipe gesture.
///
/// The shape mirrors a physical trackpad flick as captured from a real
/// device trace: while the finger is in contact the per-frame deltas ramp
/// up linearly to a peak velocity (gesture phase Began/Changed), and after
/// the finger lifts a momentum tail continues at that peak velocity and
/// decays geometrically (momentum phase flags). Most of a flick's
/// displacement — roughly 70% — travels in the momentum tail; iOS reads
/// those momentum semantics as a native flick, so paging surfaces (feeds,
/// carousels) snap to the next page exactly as they do for a finger flick.
///
/// Swipes slower than the flick threshold are deliberate drag-scrolls:
/// the finger stops before lifting, so all displacement is delivered by
/// evenly spaced drag frames and no momentum follows.
///
/// Total displacement is conserved exactly: the drag and momentum deltas
/// of a plan always sum to the amplified pixel distance, so scroll
/// calibration that estimates content offset from swipe distance behaves
/// identically whether or not a momentum tail is emitted.
enum SwipeGestureProfile {

    /// Wheel-pixel multiplier applied to the requested pixel distance.
    /// Continuous trackpad gestures with phase flags have smaller per-pixel
    /// displacement than legacy scroll wheel events; amplify to match
    /// physical trackpad scroll distance.
    static let scrollAmplification: Double = 3.0

    /// Gesture speed (pixels/second, pre-amplification) at or above which
    /// a swipe is treated as a flick and receives a momentum tail.
    /// Below this, the gesture is a deliberate drag-scroll: the finger
    /// stops before lifting, so no inertia follows.
    static let flickVelocityThreshold: Double = 500.0

    /// Per-frame decay factor for momentum deltas, measured from a real
    /// trackpad flick trace through iPhone Mirroring.
    static let momentumDecayPerFrame: Double = 0.94

    /// Upper bound on momentum frames (~1.5s at 60fps). The geometric decay
    /// exhausts the tail well before this in practice; trailing frames whose
    /// deltas round to zero on both axes are trimmed.
    static let momentumMaxSteps: Int = 90

    /// Frame duration for drag-step pacing (~60fps).
    static let frameMs: Int = 16

    /// Minimum number of drag frames regardless of duration.
    static let minimumDragSteps: Int = 5

    /// Gesture speed (pixels/second, pre-amplification) at or above which a
    /// flick carries real trackpad fields. A real trackpad flick measures about
    /// 3300. iOS honors the momentum of such a flick in full, so slower swipes
    /// leave these fields out: list scrolling keeps its bounded travel, which
    /// calibration, `scroll_to` and the explorers rely on.
    static let trackpadFlickVelocity: Double = 2000.0

    /// Reported velocity per point of a drag frame, measured from real
    /// trackpad flicks: the hardware's velocity leads its per-frame delta.
    static let dragVelocityPerPoint: Double = 1.75

    /// The complete delta schedule for one swipe gesture.
    struct Plan: Equatable {
        /// Deltas posted while the finger is down (phase Began/Changed).
        let drag: [SwipeWheelStep]
        /// Deltas posted after the finger lifts (momentum phase).
        /// Empty when the gesture is too slow to be a flick.
        let momentum: [SwipeWheelStep]
        /// Whether the events identify themselves as a real trackpad flick,
        /// which iOS paging surfaces need before they snap to the next page.
        var isTrackpadFlick = false

        /// The velocity a trackpad reports for each drag frame.
        var dragVelocities: [TrackpadVelocity] {
            drag.map {
                TrackpadVelocity(axis1: Double($0.wheel1) * dragVelocityPerPoint,
                                 axis2: Double($0.wheel2) * dragVelocityPerPoint)
            }
        }

        /// The velocity a trackpad reports for each momentum frame: it carries
        /// on from the last drag frame and decays frame by frame.
        var momentumVelocities: [TrackpadVelocity] {
            var current = dragVelocities.last ?? .zero
            return momentum.map { _ in
                current = TrackpadVelocity(axis1: current.axis1 * momentumDecayPerFrame,
                                           axis2: current.axis2 * momentumDecayPerFrame)
                return current
            }
        }
    }

    /// Compute the delta schedule for a swipe covering `deltaX`/`deltaY`
    /// pixels over `durationMs` milliseconds.
    static func plan(deltaX: Double, deltaY: Double, durationMs: Int) -> Plan {
        let dragStepCount = max(minimumDragSteps, durationMs / frameMs)
        let totalWheel1 = wheelDelta(deltaY * scrollAmplification)
        let totalWheel2 = wheelDelta(deltaX * scrollAmplification)

        let seconds = Double(max(durationMs, 1)) / 1000.0
        let velocity = (deltaX * deltaX + deltaY * deltaY).squareRoot() / seconds
        guard velocity >= flickVelocityThreshold else {
            let uniform = [Double](repeating: 1.0, count: dragStepCount)
            let drag = steps(wheel1: totalWheel1, wheel2: totalWheel2, weights: uniform)
            return Plan(drag: drag, momentum: [])
        }

        // Flick: drag frames ramp linearly from rest to a peak velocity,
        // and the momentum tail continues from that peak with geometric
        // decay. Building one weight sequence across both phases keeps the
        // velocity continuous at the lift and lets a single apportionment
        // conserve the total exactly.
        let peak = Double(dragStepCount)
        var weights: [Double] = []
        weights.reserveCapacity(dragStepCount + momentumMaxSteps)
        for frame in 1...dragStepCount {
            weights.append(Double(frame))
        }
        var momentumWeight = peak * momentumDecayPerFrame
        for _ in 0..<momentumMaxSteps {
            weights.append(momentumWeight)
            momentumWeight *= momentumDecayPerFrame
        }

        let all = steps(wheel1: totalWheel1, wheel2: totalWheel2, weights: weights)
        let drag = Array(all[..<dragStepCount])
        var momentum = Array(all[dragStepCount...])
        while let last = momentum.last, last.wheel1 == 0, last.wheel2 == 0 {
            momentum.removeLast()
        }
        return Plan(drag: drag, momentum: momentum,
                    isTrackpadFlick: velocity >= trackpadFlickVelocity)
    }

    /// Convert an amplified pixel distance into a wheel delta, saturating at
    /// the `Int32` range. A plain `Int32(_:)` conversion traps on an
    /// out-of-range or non-finite value; saturating keeps `plan` a total
    /// function for any caller input.
    private static func wheelDelta(_ amplifiedPixels: Double) -> Int32 {
        guard amplifiedPixels.isFinite else { return 0 }
        if amplifiedPixels >= Double(Int32.max) { return Int32.max }
        if amplifiedPixels <= Double(Int32.min) { return Int32.min }
        return Int32(amplifiedPixels)
    }

    /// Apportion each axis total across frames proportionally to `weights`,
    /// using cumulative rounding so the frame deltas sum exactly to the total.
    private static func steps(
        wheel1: Int32, wheel2: Int32, weights: [Double]
    ) -> [SwipeWheelStep] {
        let axis1 = apportion(total: wheel1, weights: weights)
        let axis2 = apportion(total: wheel2, weights: weights)
        return zip(axis1, axis2).map { SwipeWheelStep(wheel1: $0, wheel2: $1) }
    }

    /// Split `total` into per-frame integer deltas proportional to `weights`.
    /// Cumulative rounding guarantees the deltas sum exactly to `total`.
    private static func apportion(total: Int32, weights: [Double]) -> [Int32] {
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else {
            return [Int32](repeating: 0, count: weights.count)
        }
        var deltas: [Int32] = []
        deltas.reserveCapacity(weights.count)
        var cumulativeWeight = 0.0
        var allocated: Int32 = 0
        for weight in weights {
            cumulativeWeight += weight
            let target = Int32((Double(total) * cumulativeWeight / weightSum).rounded())
            deltas.append(target - allocated)
            allocated = target
        }
        return deltas
    }
}
