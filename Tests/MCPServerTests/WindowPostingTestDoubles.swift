// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Test doubles that record the window events and key presses InputSimulation asks for.
// ABOUTME: Shared by the window-delivery and Spotlight launch tests; nothing reaches the window server.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

/// Records the window events InputSimulation asks for. A test double: the
/// live poster talks to the window server, which a unit test must not touch.
final class RecordingWindowPoster: WindowEventPosting, @unchecked Sendable {
    struct Button: Equatable {
        let down: Bool
        let point: CGPoint
        let clickCount: Int
        let windowID: CGWindowID
    }

    private(set) var buttons: [Button] = []
    private(set) var pauses: [UInt32] = []
    private(set) var keyFocusWindows: [CGWindowID] = []
    private(set) var stampedPoints: [CGPoint] = []
    var canStampEvents = true
    var focusSucceeds = true

    func postButton(down: Bool, at point: CGPoint, clickCount: Int, in window: WindowInfo) -> Bool {
        buttons.append(Button(down: down, point: point, clickCount: clickCount, windowID: window.windowID))
        return true
    }

    func focusKeys(in window: WindowInfo) -> Bool {
        keyFocusWindows.append(window.windowID)
        return focusSucceeds
    }

    func stamp(_ event: CGEvent, at point: CGPoint, in window: WindowInfo) {
        stampedPoints.append(point)
    }

    func pause(microseconds: UInt32) {
        pauses.append(microseconds)
    }
}

/// Records each key press and the process it was addressed to; nothing is posted.
final class RecordingKeyPoster: KeyEventPosting, @unchecked Sendable {
    private(set) var targets: [pid_t?] = []
    /// The single keys pressed, in order; typed text goes through key sequences.
    private(set) var keycodes: [UInt16] = []
    /// The flags each single key press carried, in the same order as `keycodes`.
    private(set) var flags: [CGEventFlags] = []
    /// The key sequences typed, in order.
    private(set) var sequences: [CGKeySequence] = []

    func postKey(keycode: UInt16, flags: CGEventFlags, targetPID: pid_t?) -> Bool {
        targets.append(targetPID)
        keycodes.append(keycode)
        self.flags.append(flags)
        return true
    }

    func postKeySequence(_ sequence: CGKeySequence, targetPID: pid_t?) -> Bool {
        targets.append(targetPID)
        sequences.append(sequence)
        return true
    }
}
