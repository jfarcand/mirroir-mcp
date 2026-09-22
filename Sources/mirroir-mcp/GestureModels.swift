// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value types for the two-finger pinch and rotate gestures: the request, its bounds, and its events.
// ABOUTME: Shared by GesturePlanner, InputSimulation, the CGEvent gesture poster, and the pinch/rotate tools.

import CoreGraphics
import Foundation

/// A two-finger trackpad gesture iPhone Mirroring turns into a UIKit gesture.
enum TwoFingerGesture: Sendable, Equatable {
    /// Multiply the distance between the two fingers by `scale`.
    case pinch(scale: Double)
    /// Turn the two fingers by `degrees`; positive is counter-clockwise, the
    /// macOS trackpad rotation convention.
    case rotate(degrees: Double)

    /// The MCP tool that performs this gesture.
    var toolName: String {
        switch self {
        case .pinch: return "pinch"
        case .rotate: return "rotate"
        }
    }
}

/// One validated pinch or rotate, centred at a window-relative point.
struct GestureRequest: Sendable, Equatable {
    let x: Double
    let y: Double
    let gesture: TwoFingerGesture
    let durationMs: Int

    /// Smallest accepted pinch scale (fingers end at a tenth of their spread).
    static let minPinchScale = 0.1
    /// Largest accepted pinch scale (fingers end at ten times their spread).
    static let maxPinchScale = 10.0
    /// Largest accepted rotation magnitude, in degrees: one full turn.
    static let maxRotateDegrees = 360.0
    /// Shortest accepted gesture duration, in milliseconds.
    static let minDurationMs = 100
    /// Longest accepted gesture duration, in milliseconds.
    static let maxDurationMs = 5_000
    /// Duration used when the caller gives none, in milliseconds.
    static let defaultDurationMs = 500

    /// A pinch request, or why its arguments are refused.
    static func pinch(x: Double, y: Double, scale: Double,
                      durationMs: Int) -> Result<GestureRequest, GestureArgumentError> {
        guard scale.isFinite, scale >= minPinchScale, scale <= maxPinchScale else {
            return .failure(GestureArgumentError(
                message: "pinch scale must be between \(minPinchScale) and \(maxPinchScale) "
                    + "(got \(scale)). Use > 1 to spread the fingers (zoom in), < 1 to pinch them together."))
        }
        guard scale != 1 else {
            return .failure(GestureArgumentError(
                message: "pinch scale 1 does not change the finger spread. "
                    + "Use > 1 to zoom in or < 1 to zoom out."))
        }
        return validated(x: x, y: y, gesture: .pinch(scale: scale), durationMs: durationMs)
    }

    /// A rotate request, or why its arguments are refused.
    static func rotate(x: Double, y: Double, degrees: Double,
                       durationMs: Int) -> Result<GestureRequest, GestureArgumentError> {
        guard degrees.isFinite, abs(degrees) <= maxRotateDegrees else {
            return .failure(GestureArgumentError(
                message: "rotate degrees must be between -\(Int(maxRotateDegrees)) and "
                    + "\(Int(maxRotateDegrees)) (got \(degrees))."))
        }
        guard degrees != 0 else {
            return .failure(GestureArgumentError(
                message: "rotate degrees 0 does not turn anything. "
                    + "Use a positive value for counter-clockwise, negative for clockwise."))
        }
        return validated(x: x, y: y, gesture: .rotate(degrees: degrees), durationMs: durationMs)
    }

    private static func validated(x: Double, y: Double, gesture: TwoFingerGesture,
                                  durationMs: Int) -> Result<GestureRequest, GestureArgumentError> {
        guard x.isFinite, y.isFinite else {
            return .failure(GestureArgumentError(
                message: "\(gesture.toolName) requires finite x, y coordinates."))
        }
        guard durationMs >= minDurationMs, durationMs <= maxDurationMs else {
            return .failure(GestureArgumentError(
                message: "\(gesture.toolName) duration_ms must be between \(minDurationMs) and "
                    + "\(maxDurationMs) (got \(durationMs))."))
        }
        return .success(GestureRequest(x: x, y: y, gesture: gesture, durationMs: durationMs))
    }
}

/// Why pinch or rotate arguments do not form a request.
struct GestureArgumentError: Error, Equatable {
    let message: String
}

/// The trackpad gesture subtype a gesture event carries (CGEvent field 110).
enum GestureKind: Int64, Sendable, Equatable {
    case zoom = 8
    case rotate = 5
}

/// The phase a gesture event carries (CGEvent field 132).
enum GesturePhase: Int64, Sendable, Equatable {
    case began = 1
    case changed = 2
    case ended = 4
}

/// One event of a two-finger gesture, posted at the gesture centre.
enum GestureEvent: Sendable, Equatable {
    /// A pointer move to the centre: iOS centres the gesture on the pointer's
    /// last moved-to position, and a cursor warp alone does not update it.
    case pointerMove
    /// The bare gesture event a real trackpad posts before every sub-gesture event.
    case container
    /// A zoom or rotate sub-gesture event. `delta` is the zoom factor minus
    /// one, or the rotation in degrees, applied by this one event.
    case gesture(GestureKind, GesturePhase, delta: Double)
}

/// A group of gesture events posted back to back, then a pause.
struct GestureStep: Sendable, Equatable {
    let events: [GestureEvent]
    let pauseAfterUs: UInt32
}
