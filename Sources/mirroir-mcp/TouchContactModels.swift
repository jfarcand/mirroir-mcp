// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value types for the persistent touch contact: the command, its outcome, and its errors.
// ABOUTME: Shared by TouchSession, InputSimulation, and the touch MCP tool.

import CoreGraphics
import Foundation

/// One step of the persistent single-contact touch. Points are window-relative.
enum TouchCommand: Sendable, Equatable {
    /// Press at a point and keep the contact held across calls.
    case begin(x: Double, y: Double)
    /// Move the held contact to a point over `durationMs`.
    case move(x: Double, y: Double, durationMs: Int)
    /// Lift the held contact where it is.
    case end
    /// Release the left button unconditionally, held contact or not.
    case cancel

    /// The `action` argument of the touch tool that names this command.
    var actionName: String {
        switch self {
        case .begin: return "begin"
        case .move: return "move"
        case .end: return "end"
        case .cancel: return "cancel"
        }
    }
}

/// What a touch command did. Points are window-relative.
enum TouchOutcome: Sendable, Equatable {
    case began(at: CGPoint)
    case moved(to: CGPoint)
    case ended(at: CGPoint)
    /// `releasedAt` is the held contact's point, or nil when no contact was
    /// held and cancel posted a defensive button release at the pointer.
    case cancelled(releasedAt: CGPoint?)
}

/// Why a touch command was refused or failed.
enum TouchSessionError: Error, Equatable, CustomStringConvertible {
    /// `begin` while a contact is already held at a window-relative point.
    case alreadyHeld(at: CGPoint)
    /// `move` or `end` with no contact held. `lastRelease` says why the
    /// previous contact ended when that was not the caller's own `end`.
    case notHeld(lastRelease: String?)
    /// The target or the coordinates cannot take a touch (state, window, bounds).
    case rejected(String)
    /// A CGEvent for `action` could not be created or posted.
    case eventPostFailed(action: String)
    /// The target window changed size or disappeared under the held contact;
    /// the contact was released and the move refused.
    case windowChanged(TouchWindowChange)

    var description: String {
        switch self {
        case .alreadyHeld(let point):
            return "A touch is already held at (\(Int(point.x)), \(Int(point.y))). "
                + "Move it with touch(action:\"move\"), lift it with touch(action:\"end\"), "
                + "or release it with touch(action:\"cancel\")."
        case .notHeld(let lastRelease):
            let base = "No touch is held. Start one with touch(action:\"begin\")."
            guard let lastRelease else { return base }
            return "\(base) The previous touch was released: \(lastRelease)."
        case .rejected(let message):
            return message
        case .eventPostFailed(let action):
            return "CGEvent touch \(action) failed. "
                + "Run touch(action:\"cancel\") to make sure the button is released."
        case .windowChanged(let change):
            return "The touch was released: \(change). Its coordinates no longer name the same "
                + "spot on the iPhone. Start a new touch with coordinates from the current window."
        }
    }
}

/// How the target window changed under a held contact.
struct TouchWindowChange: Sendable, Equatable, CustomStringConvertible {
    /// Window size when the contact was last placed.
    let heldSize: CGSize
    /// Window size now, or nil when the window is gone.
    let liveSize: CGSize?

    init(held: WindowInfo, live: WindowInfo?) {
        heldSize = held.size
        liveSize = live?.size
    }

    var description: String {
        guard let liveSize else { return "the target window disappeared while the touch was held" }
        return "the target window changed from \(Int(heldSize.width))x\(Int(heldSize.height)) to "
            + "\(Int(liveSize.width))x\(Int(liveSize.height)) while the touch was held "
            + "(the iPhone rotated, or Mirroring was resized or restarted)"
    }
}
