// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value types for a multi-finger gesture: per-finger timelines, their validation, and the resolved paths.
// ABOUTME: Shared by the multi_touch tool, the coordinate mapper, W3CActionsBuilder, and the WebDriverAgent client.

import CoreGraphics
import Foundation

/// One step of a finger's timeline, as the caller writes it. Times are
/// milliseconds from the start of the whole gesture.
enum FingerStep: Sendable, Equatable {
    /// Put the finger down at `point`, `atMs` into the gesture (0 when nil).
    case down(point: CGPoint, atMs: Int?)
    /// Slide the finger to `point` over `durationMs`, starting `atMs` into the
    /// gesture (as soon as the previous step ends when nil).
    case move(to: CGPoint, atMs: Int?, durationMs: Int)
    /// Lift the finger `atMs` into the gesture (as soon as the previous step
    /// ends when nil).
    case up(atMs: Int?)

    /// The step with its point passed through `transform`; times unchanged.
    func mappingPoint(_ transform: (CGPoint) -> CGPoint) -> FingerStep {
        switch self {
        case .down(let point, let atMs): return .down(point: transform(point), atMs: atMs)
        case .move(let point, let atMs, let durationMs):
            return .move(to: transform(point), atMs: atMs, durationMs: durationMs)
        case .up: return self
        }
    }
}

/// Everything one finger does during a gesture, in order.
struct FingerTimeline: Sendable, Equatable {
    /// Caller-chosen identifier, unique within the gesture.
    let id: Int
    /// Down first, up last, moves in between.
    let steps: [FingerStep]

    /// The timeline with every point passed through `transform`.
    func mappingPoints(_ transform: (CGPoint) -> CGPoint) -> FingerTimeline {
        FingerTimeline(id: id, steps: steps.map { $0.mappingPoint(transform) })
    }
}

/// A validated slide of a finger, on the gesture's absolute clock.
struct FingerMove: Sendable, Equatable {
    let to: CGPoint
    let startMs: Int
    let durationMs: Int

    /// When the finger arrives at `to`.
    var endMs: Int { startMs + durationMs }
}

/// A finger's timeline with every time resolved to the gesture's absolute clock.
struct FingerPath: Sendable, Equatable {
    let id: Int
    let downPoint: CGPoint
    let downMs: Int
    let moves: [FingerMove]
    let upMs: Int

    /// Where the finger is when it lifts.
    var upPoint: CGPoint { moves.last?.to ?? downPoint }
}

/// Why a multi-finger gesture is refused before anything is sent to the device.
enum MultiTouchValidationError: Error, Equatable, CustomStringConvertible {
    case fingerCount(Int)
    case duplicateFingerID(Int)
    case emptyTimeline(finger: Int)
    case firstStepNotDown(finger: Int)
    case lastStepNotUp(finger: Int)
    case misplacedStep(finger: Int, index: Int)
    case negativeTime(finger: Int, index: Int, ms: Int)
    case moveDuration(finger: Int, index: Int, durationMs: Int)
    case timeGoesBackwards(finger: Int, index: Int, atMs: Int, previousEndMs: Int)
    case zeroLengthContact(finger: Int)
    case outOfBounds(finger: Int, index: Int, point: CGPoint, bounds: CGSize)
    case tooLong(durationMs: Int)

    var description: String {
        let limits = MultiTouchGesture.self
        switch self {
        case .fingerCount(let count):
            return "multi_touch needs \(limits.minFingers)-\(limits.maxFingers) fingers (got \(count))."
        case .duplicateFingerID(let id):
            return "finger id \(id) is used twice; every finger needs its own id."
        case .emptyTimeline(let finger):
            return "finger \(finger) has no steps; give it a down, optional moves, and an up."
        case .firstStepNotDown(let finger):
            return "finger \(finger) must start with a down step."
        case .lastStepNotUp(let finger):
            return "finger \(finger) must end with an up step: a finger cannot stay down "
                + "after the call returns."
        case .misplacedStep(let finger, let index):
            return "finger \(finger) step \(index): down may only be the first step and up only the last."
        case .negativeTime(let finger, let index, let ms):
            return "finger \(finger) step \(index): times must not be negative (got \(ms)ms)."
        case .moveDuration(let finger, let index, let durationMs):
            return "finger \(finger) step \(index): move duration_ms must be between "
                + "\(limits.minMoveDurationMs) and \(limits.maxDurationMs) (got \(durationMs))."
        case .timeGoesBackwards(let finger, let index, let atMs, let previousEndMs):
            return "finger \(finger) step \(index): at_ms \(atMs) is before the previous step "
                + "ends at \(previousEndMs)ms; a finger's steps must run in time order."
        case .zeroLengthContact(let finger):
            return "finger \(finger) lifts at the instant it goes down; give its up a later at_ms."
        case .outOfBounds(let finger, let index, let point, let bounds):
            return "finger \(finger) step \(index): (\(Self.format(point.x)), \(Self.format(point.y))) "
                + "is outside the \(Int(bounds.width))x\(Int(bounds.height)) screen."
        case .tooLong(let durationMs):
            return "multi_touch lasts \(durationMs)ms; the longest accepted gesture is "
                + "\(limits.maxDurationMs)ms."
        }
    }

    private static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", Double(value))
    }
}

/// A validated gesture of 1 to 10 independent fingers, every finger lifted
/// by the end: the whole gesture plays in one request, so no finger can stay
/// down between calls.
struct MultiTouchGesture: Sendable, Equatable {
    /// Fewest fingers in a gesture.
    static let minFingers = 1
    /// Most fingers in a gesture: the fingers of two hands, and the most
    /// simultaneous touches an iPhone reports.
    static let maxFingers = 10
    /// Shortest accepted move, in milliseconds.
    static let minMoveDurationMs = 1
    /// Longest accepted gesture, in milliseconds, from the first down to the
    /// last up. The device plays the whole gesture before answering, so this
    /// also bounds how long one call can block.
    static let maxDurationMs = 60_000

    /// The timelines as given, in the coordinate space `bounds` describes.
    let timelines: [FingerTimeline]
    /// The same timelines with every time resolved.
    let paths: [FingerPath]
    /// The screen size, in points, every coordinate was checked against.
    let bounds: CGSize

    /// From the first down to the last up, in milliseconds.
    var durationMs: Int { paths.map(\.upMs).max() ?? 0 }

    /// Validate `timelines` against a screen of `bounds` points.
    init(timelines: [FingerTimeline], bounds: CGSize) throws(MultiTouchValidationError) {
        guard timelines.count >= Self.minFingers, timelines.count <= Self.maxFingers else {
            throw .fingerCount(timelines.count)
        }
        var seen = Set<Int>()
        var paths: [FingerPath] = []
        for timeline in timelines {
            guard seen.insert(timeline.id).inserted else { throw .duplicateFingerID(timeline.id) }
            paths.append(try Self.resolve(timeline, bounds: bounds))
        }
        let duration = paths.map(\.upMs).max() ?? 0
        guard duration <= Self.maxDurationMs else { throw .tooLong(durationMs: duration) }
        self.timelines = timelines
        self.paths = paths
        self.bounds = bounds
    }

    /// Resolve one finger's times onto the gesture clock, checking order and bounds.
    private static func resolve(_ timeline: FingerTimeline,
                                bounds: CGSize) throws(MultiTouchValidationError) -> FingerPath {
        let finger = timeline.id
        guard let first = timeline.steps.first else { throw .emptyTimeline(finger: finger) }
        guard case .down(let downPoint, let downAt) = first else { throw .firstStepNotDown(finger: finger) }
        guard let last = timeline.steps.last, case .up = last, timeline.steps.count >= 2 else {
            throw .lastStepNotUp(finger: finger)
        }
        let downMs = downAt ?? 0
        guard downMs >= 0 else { throw .negativeTime(finger: finger, index: 0, ms: downMs) }
        try checkBounds(downPoint, finger: finger, index: 0, bounds: bounds)

        var cursor = downMs
        var moves: [FingerMove] = []
        for (index, step) in timeline.steps.enumerated().dropFirst().dropLast() {
            guard case .move(let point, let atMs, let durationMs) = step else {
                throw .misplacedStep(finger: finger, index: index)
            }
            let start = try startTime(atMs, cursor: cursor, finger: finger, index: index)
            guard durationMs >= minMoveDurationMs, durationMs <= maxDurationMs else {
                throw .moveDuration(finger: finger, index: index, durationMs: durationMs)
            }
            try checkBounds(point, finger: finger, index: index, bounds: bounds)
            let move = FingerMove(to: point, startMs: start, durationMs: durationMs)
            moves.append(move)
            cursor = move.endMs
        }

        guard case .up(let upAt) = last else { throw .lastStepNotUp(finger: finger) }
        let upMs = try startTime(upAt, cursor: cursor, finger: finger,
                                 index: timeline.steps.count - 1)
        guard upMs > downMs else { throw .zeroLengthContact(finger: finger) }
        return FingerPath(id: finger, downPoint: downPoint, downMs: downMs, moves: moves, upMs: upMs)
    }

    /// The absolute start of a step: its own `atMs`, or `cursor` when nil.
    private static func startTime(_ atMs: Int?, cursor: Int, finger: Int,
                                  index: Int) throws(MultiTouchValidationError) -> Int {
        guard let atMs else { return cursor }
        guard atMs >= 0 else { throw .negativeTime(finger: finger, index: index, ms: atMs) }
        guard atMs >= cursor else {
            throw .timeGoesBackwards(finger: finger, index: index, atMs: atMs, previousEndMs: cursor)
        }
        return atMs
    }

    private static func checkBounds(_ point: CGPoint, finger: Int, index: Int,
                                    bounds: CGSize) throws(MultiTouchValidationError) {
        let inside = point.x.isFinite && point.y.isFinite
            && point.x >= 0 && point.x <= bounds.width
            && point.y >= 0 && point.y <= bounds.height
        guard inside else { throw .outOfBounds(finger: finger, index: index, point: point, bounds: bounds) }
    }
}

/// What a backend reports after playing a gesture.
struct MultiTouchReport: Sendable, Equatable {
    /// The gesture that was played, in device points.
    let gesture: MultiTouchGesture
    /// Wall-clock time the backend took to answer, in milliseconds.
    let elapsedMs: Int
}

/// What a multi-touch backend says about itself when asked.
struct MultiTouchBackendStatus: Sendable, Equatable {
    /// Whether the backend accepts gestures now.
    let ready: Bool
    /// The backend's own status message, when it gives one.
    let message: String?
    /// The device's OS name and version (e.g. "iOS 26.0"), when reported.
    let osVersion: String?
}
