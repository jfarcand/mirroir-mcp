// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Turns a MultiTouchGesture into the W3C actions JSON WebDriverAgent plays as one XCTest event record.
// ABOUTME: One touch pointer source per finger; pauses place every action on the gesture's absolute clock.

import CoreGraphics
import Foundation

/// One item of a pointer source's action list.
enum W3CPointerAction: Sendable, Equatable, Encodable {
    /// Wait `durationMs` without changing the finger.
    case pause(durationMs: Int)
    /// Slide (or, before the first down, place) the finger to `point` over `durationMs`.
    case move(point: CGPoint, durationMs: Int)
    /// Touch down where the finger was last moved.
    case down
    /// Lift the finger.
    case up

    private enum CodingKeys: String, CodingKey {
        case type, duration, x, y, origin, button
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pause(let durationMs):
            try container.encode("pause", forKey: .type)
            try container.encode(durationMs, forKey: .duration)
        case .move(let point, let durationMs):
            try container.encode("pointerMove", forKey: .type)
            try container.encode(durationMs, forKey: .duration)
            try container.encode(Double(point.x), forKey: .x)
            try container.encode(Double(point.y), forKey: .y)
            try container.encode(W3CActionsBuilder.viewportOrigin, forKey: .origin)
        case .down:
            try container.encode("pointerDown", forKey: .type)
            try container.encode(W3CActionsBuilder.primaryButton, forKey: .button)
        case .up:
            try container.encode("pointerUp", forKey: .type)
            try container.encode(W3CActionsBuilder.primaryButton, forKey: .button)
        }
    }
}

/// One finger: a W3C `pointer` input source of pointer type `touch`.
struct W3CPointerSource: Sendable, Equatable, Encodable {
    let id: String
    let actions: [W3CPointerAction]

    private enum CodingKeys: String, CodingKey { case type, id, parameters, actions }
    private enum ParameterKeys: String, CodingKey { case pointerType }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("pointer", forKey: .type)
        try container.encode(id, forKey: .id)
        var parameters = container.nestedContainer(keyedBy: ParameterKeys.self, forKey: .parameters)
        try parameters.encode(W3CActionsBuilder.touchPointerType, forKey: .pointerType)
        try container.encode(actions, forKey: .actions)
    }
}

/// The body of `POST /session/{id}/actions`.
struct W3CActionsRequest: Sendable, Equatable, Encodable {
    let actions: [W3CPointerSource]
}

/// Builds the W3C actions request for a multi-finger gesture.
///
/// WebDriverAgent (`FBW3CActionsSynthesizer`) turns every pointer source into
/// one finger of a single `XCSynthesizedEventRecord`, and times each action at
/// the sum of the durations before it in the same source. A pause therefore
/// places the next action at an absolute time, independently of the other
/// fingers:
///
/// - `pause(downMs)` when the finger starts late, then `pointerMove(0)` to the
///   down point and `pointerDown`: the move opens the touch and the down that
///   follows it is absorbed, as WebDriverAgent requires a positioned finger
///   before its first down.
/// - For each move, a pause up to its start, then `pointerMove(duration)`.
/// - A pause up to the lift, then `pointerUp`.
enum W3CActionsBuilder {
    /// W3C origin for coordinates in the active app's viewport, in points.
    static let viewportOrigin = "viewport"
    /// The W3C pointer type WebDriverAgent requires for touch synthesis.
    static let touchPointerType = "touch"
    /// W3C button number of the primary (and, for touch, only) button.
    static let primaryButton = 0
    /// Prefix of every finger's input source id; the finger id follows it.
    static let sourceIDPrefix = "finger"

    /// The request body for `gesture`, one pointer source per finger.
    static func request(for gesture: MultiTouchGesture) -> W3CActionsRequest {
        W3CActionsRequest(actions: gesture.paths.map(source(for:)))
    }

    /// The pointer source of one finger.
    static func source(for path: FingerPath) -> W3CPointerSource {
        var actions: [W3CPointerAction] = []
        var clock = 0
        func pause(until time: Int) {
            if time > clock { actions.append(.pause(durationMs: time - clock)) }
            clock = max(clock, time)
        }

        pause(until: path.downMs)
        actions.append(.move(point: path.downPoint, durationMs: 0))
        actions.append(.down)
        for move in path.moves {
            pause(until: move.startMs)
            actions.append(.move(point: move.to, durationMs: move.durationMs))
            clock = move.endMs
        }
        pause(until: path.upMs)
        actions.append(.up)
        return W3CPointerSource(id: sourceIDPrefix + String(path.id), actions: actions)
    }

    /// The JSON body of `POST /session/{id}/actions`, keys sorted so the
    /// same gesture always serializes to the same bytes.
    static func body(for gesture: MultiTouchGesture) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request(for: gesture))
    }
}
