// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Two-finger pinch and rotate for InputSimulation: sender lookup, pointing preamble, playback.
// ABOUTME: Plays GesturePlanner's steps through a GestureEventPosting, always closing an opened gesture.

import CoreGraphics
import Foundation

/// The system boundaries a two-finger gesture needs: the event poster and the
/// trackpad whose sender ID every gesture event must carry.
struct GestureDevice: Sendable {
    let poster: any GestureEventPosting
    let senderResolver: any MultitouchSenderResolving

    /// The real CGEvent poster and IORegistry lookup.
    static let live = GestureDevice(poster: CGEventGesturePoster(),
                                    senderResolver: IOKitMultitouchSenderResolver())
}

extension InputSimulation {

    /// Perform a validated pinch or rotate centred at the request's
    /// window-relative point. Returns nil on success, or an error message.
    ///
    /// The trackpad sender is looked up first, so a Mac without a trackpad
    /// gets its answer without the window being brought forward. The pointing
    /// preamble then refuses while a touch is held (iOS ignores a gesture
    /// during a held button) and checks state, window and bounds.
    func gesture(_ request: GestureRequest) -> String? {
        let tool = request.gesture.toolName
        guard let senderID = gestureDevice.senderResolver.multitouchSenderID() else {
            DebugLog.log(tool, "REJECTED: no multitouch trackpad")
            return Self.noTrackpadMessage(tool: tool)
        }
        let prep = preparePointingInput(tag: tool, x: request.x, y: request.y)
        guard let info = prep.info else { return prep.error ?? "Unknown error" }

        let saved = saveCursor()
        defer { restoreCursor(saved) }

        let centre = CGPoint(x: info.position.x + CGFloat(request.x),
                             y: info.position.y + CGFloat(request.y))
        DebugLog.log(tool, "\(request.gesture) relative=(\(request.x),\(request.y)) "
            + "screen=(\(Int(centre.x)),\(Int(centre.y))) duration=\(request.durationMs)ms sender=\(senderID)")

        let steps = GesturePlanner.steps(for: request.gesture, durationMs: request.durationMs)
        let delivered = GesturePlayback.play(steps, at: centre, senderID: senderID,
                                             targetPID: cursorFreePID, poster: gestureDevice.poster)
        DebugLog.log(tool, "CGEvent=\(delivered ? "OK" : "FAILED")")
        return delivered ? nil : "CGEvent \(tool) failed"
    }

    /// The error a gesture returns on a Mac with no multitouch trackpad.
    static func noTrackpadMessage(tool: String) -> String {
        "\(tool) needs a Mac with a built-in trackpad or a Magic Trackpad: iPhone Mirroring "
            + "only accepts pinch and rotate events sent from a multitouch trackpad, and none "
            + "was found in the IORegistry."
    }
}

/// Posts gesture steps in order, pausing after each.
enum GesturePlayback {

    /// Post every step of `steps` at `centre`. When an event cannot be posted
    /// or shutdown interrupts (`interruption`) after the gesture opened, the
    /// remaining frames are skipped and the closing step is still posted, so
    /// iOS never keeps a gesture open. Returns whether every event was posted.
    static func play(_ steps: [GestureStep], at centre: CGPoint, senderID: UInt64,
                     targetPID: pid_t?, poster: any GestureEventPosting,
                     interruption: PlaybackInterruption = .shared) -> Bool {
        guard let closing = steps.last else { return true }
        guard interruption.begin() else { return false }
        defer { interruption.end() }
        let engaged = poster.engagePointer(targetPID: targetPID)
        defer { poster.disengagePointer(engaged) }

        var opened = false
        for step in steps.dropLast() {
            guard !interruption.isInterrupted else {
                if opened { _ = close(closing, centre, senderID, targetPID, poster) }
                return false
            }
            for event in step.events {
                guard poster.post(event, at: centre, senderID: senderID, targetPID: targetPID) else {
                    if opened { _ = close(closing, centre, senderID, targetPID, poster) }
                    return false
                }
                if case .gesture(_, .began, _) = event { opened = true }
            }
            poster.pause(microseconds: step.pauseAfterUs)
        }
        return close(closing, centre, senderID, targetPID, poster)
    }

    /// Post every closing event, attempting each one even when an earlier
    /// one fails: the `ended` sub-gesture event must go out even when the
    /// container before it could not. Returns whether all were posted.
    private static func close(_ closing: GestureStep, _ centre: CGPoint, _ senderID: UInt64,
                              _ targetPID: pid_t?, _ poster: any GestureEventPosting) -> Bool {
        closing.events
            .map { poster.post($0, at: centre, senderID: senderID, targetPID: targetPID) }
            .allSatisfy { $0 }
    }
}
