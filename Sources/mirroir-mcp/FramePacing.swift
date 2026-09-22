// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Frame pacing (~60fps) and straight-line interpolation shared by every paced pointer playback.
// ABOUTME: Used by the drag path, the held touch move, hold_keys button drags, and pinch/rotate frames.

import CoreGraphics
import Foundation

/// The one frame rate and interpolation every paced pointer playback uses, so
/// a retune after an on-device measurement reaches drag, touch, hold_keys and
/// pinch/rotate together.
enum FramePacing {

    /// Milliseconds per frame (~60fps, a trackpad's event rate).
    static let frameMs = 16

    /// Fewest frames in one paced playback, so even a very short duration
    /// still passes through intermediate positions.
    static let minFrames = 10

    /// Number of frames in a playback lasting `durationMs`.
    static func frameCount(durationMs: Int) -> Int {
        max(minFrames, durationMs / frameMs)
    }

    /// Microseconds each of `frames` frames lasts so they span `durationMs`.
    /// A negative duration paces at zero.
    static func frameUs(durationMs: Int, frames: Int) -> UInt32 {
        UInt32(max(0, durationMs)) * 1000 / UInt32(max(1, frames))
    }

    /// The point `frame` of `frames` along the straight line from `start` to
    /// `end`: frame `frames` is `end`, frame 0 is `start`.
    static func point(from start: CGPoint, to end: CGPoint, frame: Int, of frames: Int) -> CGPoint {
        let t = CGFloat(frame) / CGFloat(max(1, frames))
        return CGPoint(x: start.x + (end.x - start.x) * t,
                       y: start.y + (end.y - start.y) * t)
    }
}
