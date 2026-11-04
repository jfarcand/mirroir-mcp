// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Samples who owns the Mac's front window and how deep the target sits, from the window server's list.
// ABOUTME: Diffs two samples into whether an action stole the user's focus or raised the target window.

import CoreGraphics
import Foundation

/// Focus state at one instant: the owner of the frontmost normal-layer
/// window and the target's depth among normal-layer windows.
struct FocusSample: Equatable, Sendable {
    /// PID owning the frontmost layer-0 window, nil when none is on screen.
    let frontmostPID: pid_t?
    /// Zero-based front-to-back index of the target's first layer-0 window,
    /// nil when the target has no window on screen.
    let targetDepth: Int?
}

/// What one action did to the user's Mac, judged from a before and after sample.
enum FocusInterruption: Equatable, Sendable {
    /// The target was not identified, so the action could not be judged.
    /// Counted apart from `clean` so an unjudged run never reads as focus-free.
    case unmeasured
    /// Focus and stacking order were left alone.
    case clean
    /// The target moved forward in the stack without taking the front.
    case raised
    /// The target took the front window from another app.
    case stoleFocus
}

/// Pure focus sampling and diffing over window-server entries.
enum FocusProbe {

    /// Sample focus for `targetPID` from on-screen entries in front-to-back order,
    /// as `WindowListHelper.windowEntries(onScreenOnly: true)` returns them.
    static func sample(entries: [WindowListEntry], targetPID: pid_t) -> FocusSample {
        let normal = entries.filter { $0.layer == 0 }
        return FocusSample(
            frontmostPID: normal.first?.ownerPID,
            targetDepth: normal.firstIndex { $0.ownerPID == targetPID })
    }

    /// Judge one action from the samples taken around it.
    static func interruption(before: FocusSample, after: FocusSample,
                             targetPID: pid_t) -> FocusInterruption {
        if before.frontmostPID != targetPID && after.frontmostPID == targetPID {
            return .stoleFocus
        }
        switch (before.targetDepth, after.targetDepth) {
        case let (old?, new?) where new < old:
            return .raised
        case (nil, .some):
            return .raised
        default:
            return .clean
        }
    }
}
