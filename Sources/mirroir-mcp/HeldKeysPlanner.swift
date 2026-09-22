// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pure event math for hold_keys: press order, drag frames, key auto-repeat timing, reverse release.
// ABOUTME: Builds a HeldInputPlan from a HeldKeysRequest without touching CoreGraphics event posting.

import CoreGraphics
import Foundation

/// Turns a hold_keys request into the events that play it.
enum HeldKeysPlanner {

    /// Milliseconds between re-posted key downs while a key is held. A held
    /// physical key repeats; games that poll key-down events see the key as
    /// still pressed only while the repeats keep arriving.
    static let keyRepeatIntervalMs = 50

    /// Microseconds between consecutive presses or releases, so each key or
    /// button state change arrives as its own event.
    static let settleUs: UInt32 = 8_000

    /// Build the plan for `request`. `dragPath` is the drag's screen-absolute
    /// start and end, or nil when the request holds no button.
    ///
    /// Keys go down in the order given, then the button at the drag start.
    /// Each frame (~60fps, `FramePacing`) moves the button one
    /// interpolated step and, once per `keyRepeatIntervalMs` of elapsed time,
    /// re-posts every held plain key as an auto-repeat.
    static func plan(for request: HeldKeysRequest,
                     dragPath: (from: CGPoint, to: CGPoint)?) -> HeldInputPlan {
        var presses: [HeldInputStep] = []
        var held = CGEventFlags()
        for key in request.keys {
            if let flag = key.modifier {
                held.insert(flag)
                presses.append(step(.modifierDown(key, flags: held)))
            } else {
                presses.append(step(.keyDown(key, flags: held, isRepeat: false)))
            }
        }
        if let drag = request.drag, let dragPath {
            presses.append(step(.buttonDown(drag.button, at: dragPath.from)))
        }

        let frameCount = FramePacing.frameCount(durationMs: request.durationMs)
        let frameUs = FramePacing.frameUs(durationMs: request.durationMs, frames: frameCount)
        let repeatingKeys = request.keys.filter { $0.modifier == nil }
        let repeatIntervalUs = UInt32(keyRepeatIntervalMs) * 1000

        var frames: [HeldInputStep] = []
        for index in 1...frameCount {
            var events: [HeldInputEvent] = []
            if let drag = request.drag, let dragPath {
                let point = FramePacing.point(from: dragPath.from, to: dragPath.to,
                                              frame: index, of: frameCount)
                events.append(.buttonDragged(drag.button, to: point))
            }
            // A frame is posted at the start of its pause, so frame `index`
            // goes out (index - 1) frames into the hold.
            let postedAtUs = UInt32(index - 1) * frameUs
            let previousUs = index > 1 ? UInt32(index - 2) * frameUs : 0
            if index > 1, postedAtUs / repeatIntervalUs > previousUs / repeatIntervalUs {
                events += repeatingKeys.map { .keyDown($0, flags: held, isRepeat: true) }
            }
            frames.append(HeldInputStep(events: events, pauseAfterUs: frameUs))
        }
        return HeldInputPlan(presses: presses, frames: frames)
    }

    /// The events that release everything in `pressed`, in reverse order. A
    /// button comes up at `buttonPoint`, where it was last moved to.
    static func releases(for pressed: [HeldInputEvent], buttonPoint: CGPoint) -> [HeldInputEvent] {
        var held = pressed.reduce(into: CGEventFlags()) { flags, event in
            if case .modifierDown(let key, _) = event, let flag = key.modifier { flags.insert(flag) }
        }
        return pressed.reversed().compactMap { event -> HeldInputEvent? in
            switch event {
            case .modifierDown(let key, _):
                if let flag = key.modifier { held.remove(flag) }
                return .modifierUp(key, flags: held)
            case .keyDown(let key, _, _):
                return .keyUp(key, flags: held)
            case .buttonDown(let button, _):
                return .buttonUp(button, at: buttonPoint)
            case .modifierUp, .keyUp, .buttonDragged, .buttonUp:
                return nil
            }
        }
    }

    private static func step(_ event: HeldInputEvent) -> HeldInputStep {
        HeldInputStep(events: [event], pauseAfterUs: settleUs)
    }
}

/// Posts a hold plan and always releases what it pressed.
enum HeldInputPlayback {

    /// Post the presses, then the frames, then release every key and button
    /// that went down, in reverse order.
    ///
    /// Before every step that posts a keyboard event, `targetFocused` must
    /// still hold: keyboard events reach whichever Mac app has focus, and a
    /// held modifier plus a repeating key would drive another app. A failed
    /// post, lost focus, or a shutdown (`interruption`) stops the presses or
    /// frames early, yet the release still runs for everything already down,
    /// and each release is attempted even when an earlier one fails, so no
    /// key or button is left held.
    static func play(_ plan: HeldInputPlan, targetPID: pid_t?,
                     poster: any HeldInputPosting,
                     targetFocused: () -> Bool,
                     interruption: PlaybackInterruption = .shared) -> HeldInputOutcome {
        guard interruption.begin() else { return .interrupted }
        defer { interruption.end() }
        let engaged = plan.holdsButton ? poster.engagePointer(targetPID: targetPID) : false
        defer { poster.disengagePointer(engaged) }

        var pressed: [HeldInputEvent] = []
        var buttonPoint = CGPoint.zero
        var outcome = post(plan.presses, targetPID: targetPID, poster: poster,
                           targetFocused: targetFocused, interruption: interruption) { event in
            pressed.append(event)
            if case .buttonDown(_, let point) = event { buttonPoint = point }
        }
        if outcome == .delivered {
            outcome = post(plan.frames, targetPID: targetPID, poster: poster,
                           targetFocused: targetFocused, interruption: interruption) { event in
                if case .buttonDragged(_, let point) = event { buttonPoint = point }
            }
        }
        // Reached on every path: a stopped post above returns its outcome, it never exits.
        let released = release(pressed, at: buttonPoint, targetPID: targetPID, poster: poster)
        return outcome == .delivered && !released ? .postFailed : outcome
    }

    private static func release(_ pressed: [HeldInputEvent], at point: CGPoint,
                                targetPID: pid_t?, poster: any HeldInputPosting) -> Bool {
        var releasedAll = true
        for event in HeldKeysPlanner.releases(for: pressed, buttonPoint: point) {
            if !poster.post(event, targetPID: targetPID) { releasedAll = false }
            poster.pause(microseconds: HeldKeysPlanner.settleUs)
        }
        return releasedAll
    }

    /// Post every step's events, pausing after each step, reporting each
    /// posted event. Stops before a step once shutdown interrupts, or before
    /// a step with a keyboard event once the target lost focus, and at the
    /// first event that cannot be posted.
    private static func post(_ steps: [HeldInputStep], targetPID: pid_t?,
                             poster: any HeldInputPosting,
                             targetFocused: () -> Bool,
                             interruption: PlaybackInterruption,
                             posted: (HeldInputEvent) -> Void) -> HeldInputOutcome {
        for step in steps {
            if interruption.isInterrupted { return .interrupted }
            if step.events.contains(where: \.isKeyboard), !targetFocused() { return .focusLost }
            for event in step.events {
                guard poster.post(event, targetPID: targetPID) else { return .postFailed }
                posted(event)
            }
            poster.pause(microseconds: step.pauseAfterUs)
        }
        return .delivered
    }
}
