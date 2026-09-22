// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CGEvent primitives for a persistent touch contact: button down, dragged path, button up.
// ABOUTME: Holds the paced drag path shared by the one-shot drag and the held touch.

import CoreGraphics
import Foundation

extension CGEventInput {

    /// Post `leftMouseDragged` events along the straight line from `start`
    /// to `end`, paced over `durationMs` by `FramePacing`. The left button
    /// must already be down; this neither presses nor releases it. Stops
    /// early when shutdown interrupts playbacks, so the caller's release
    /// runs promptly. Returns whether every frame was posted.
    @discardableResult
    static func postDragPath(from start: CGPoint, to end: CGPoint, durationMs: Int,
                             targetPID: pid_t?) -> Bool {
        let durationMs = safeDurationMs(durationMs)
        let frames = FramePacing.frameCount(durationMs: durationMs)
        let frameUs = FramePacing.frameUs(durationMs: durationMs, frames: frames)

        var postedAll = true
        for frame in 1...frames {
            guard !PlaybackInterruption.shared.isInterrupted else { return false }
            let point = FramePacing.point(from: start, to: end, frame: frame, of: frames)
            if let dragEvent = makeMouseEvent(.leftMouseDragged, at: point) {
                post(dragEvent, targetPID: targetPID)
            } else {
                postedAll = false
            }
            usleep(frameUs)
        }
        return postedAll
    }
}

/// Live `TouchContactPosting`: posts the held-button events through
/// `CGEventInput`, to the HID event tap or to one process in cursor-free mode.
struct CGEventTouchContact: TouchContactPosting, CGEventPointerEngaging {

    func press(at point: CGPoint, targetPID: pid_t?) -> Bool {
        guard let down = CGEventInput.makeMouseEvent(.leftMouseDown, at: point) else {
            return false
        }
        CGEventInput.post(down, targetPID: targetPID)
        return true
    }

    func move(from start: CGPoint, to end: CGPoint, durationMs: Int, targetPID: pid_t?) -> Bool {
        CGEventInput.postDragPath(from: start, to: end, durationMs: durationMs,
                                  targetPID: targetPID)
    }

    func release(at point: CGPoint, targetPID: pid_t?) -> Bool {
        guard let up = CGEventInput.makeMouseEvent(.leftMouseUp, at: point) else {
            return false
        }
        CGEventInput.post(up, targetPID: targetPID)
        return true
    }

    /// The pointer location from a fresh null event; the origin when the
    /// window server hands back no event.
    func pointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func warpPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }
}
