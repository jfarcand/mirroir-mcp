// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: After a gesture that had to take the Mac's front, gives the front back to the user's app and returns the pointer.
// ABOUTME: Swipes and drags still need the HID path; this limits what they cost the user to the gesture's own duration.

import CoreGraphics
import Foundation

/// The Mac state a gesture borrows, behind closures so tests move no real
/// window or pointer.
struct MacFront: Sendable {
    /// The process owning the front window right now, read live from the window server.
    let ownerPID: @Sendable () -> pid_t?
    /// Ask macOS to bring a process back to the front.
    let bringForward: @Sendable (pid_t) -> Void
    /// Where the pointer is now.
    let pointer: @Sendable () -> CGPoint?
    /// Move the pointer without generating input.
    let movePointer: @Sendable (CGPoint) -> Void

    static let live = MacFront(
        ownerPID: { WindowListHelper.frontmostWindowOwnerPID() },
        bringForward: { InputSimulation.requestFrontmost(pid: $0) },
        pointer: { CGEvent(source: nil)?.location },
        movePointer: { CGWarpMouseCursorPosition($0) })
}

/// What one gesture borrowed, and how to return it. `finish()` puts the pointer
/// back and, if the front changed hands during the gesture, returns it.
struct FrontHandback {
    private let front: MacFront
    private let ownerBefore: pid_t?
    private let pointerBefore: CGPoint?

    /// Nothing to return: the target is not one that keeps the user's front,
    /// or it already was the front app and the user is watching it.
    static func nothing(_ front: MacFront) -> FrontHandback {
        FrontHandback(front: front, ownerBefore: nil, pointerBefore: nil)
    }

    /// Remember the Mac's state before a gesture on `targetPID`.
    static func remember(_ front: MacFront, targetPID: pid_t?) -> FrontHandback {
        guard let owner = front.ownerPID(), owner != targetPID else { return nothing(front) }
        return FrontHandback(front: front, ownerBefore: owner, pointerBefore: front.pointer())
    }

    /// Return what the gesture took. A refused gesture took nothing, and the
    /// front is left alone; so is a user who moved to another app meanwhile,
    /// because only the target taking the front is undone.
    func finish(targetPID: pid_t?) {
        guard let ownerBefore else { return }
        if let pointerBefore { front.movePointer(pointerBefore) }
        if front.ownerPID() == targetPID {
            front.bringForward(ownerBefore)
        }
    }
}

extension InputSimulation {
    /// Start a gesture that must use the HID path. Only a target that takes
    /// taps and keys without the front (one with a window poster) promises to
    /// leave the user's app alone; other targets are meant to be in front.
    func beginFrontHandback() -> FrontHandback {
        guard windowPoster != nil else { return .nothing(macFront) }
        return .remember(macFront, targetPID: targetPID)
    }
}
