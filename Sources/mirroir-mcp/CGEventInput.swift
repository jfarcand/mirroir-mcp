// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CGEvent-based input (click, scroll, drag, keyboard) for target windows.
// ABOUTME: Posts mouse and keyboard events directly via macOS CGEvent API.

import CoreGraphics
import Foundation

/// CGEvent-based input operations for pointing and keyboard.
/// iPhone Mirroring accepts physical mouse and keyboard input;
/// CGEvent posts into the same macOS event pipeline as physical devices.
///
/// Pointing methods accept an optional `targetPID`. When set, events are
/// posted directly to that process via `CGEvent.postToPid` without moving
/// the system cursor. This works for regular macOS apps (e.g. FakeMirroring)
/// but NOT for iPhone Mirroring, which requires HID-level event posting.
///
/// For HID-mode pointing, mouse events (click/drag) carry their coordinates
/// and the HID pipeline moves the cursor to match — no explicit
/// `CGWarpMouseCursorPosition` is needed. Scroll wheel events (swipe) are
/// routed based on cursor position, so swipe still warps the cursor.
/// The cursor is hidden during operations to avoid visible teleportation.
enum CGEventInput {

    /// Milliseconds to pause between mouse-down and mouse-up for a click.
    private static let clickHoldUs: UInt32 = 50_000

    /// Microseconds to settle after warping cursor before posting scroll events.
    /// Only used by swipe, which needs the cursor pre-positioned for scroll routing.
    /// Set to 100ms to allow the window's scroll subsystem to register the cursor
    /// position and the MayBegin priming event before actual scroll events arrive.
    private static let warpSettleUs: UInt32 = 100_000

    /// Microseconds between momentum-tail scroll frames (~60fps), matching
    /// the frame pacing of physical trackpad momentum events.
    private static let momentumFrameUs: UInt32 = 16_000

    /// Lower bound for a caller-supplied gesture duration, in milliseconds.
    private static let minGestureDurationMs = 1

    /// Upper bound for a caller-supplied gesture duration, in milliseconds.
    /// A duration outside `[min, max]` would trap the `UInt32` microsecond
    /// conversion (negative input) or overflow the millisecond-to-microsecond
    /// multiply (extreme input). 60s is far beyond any real gesture while
    /// keeping every derived timing value well inside `UInt32`.
    private static let maxGestureDurationMs = 60_000

    /// Clamp a caller-supplied gesture duration into the safe range so the
    /// downstream microsecond conversions can never trap or overflow.
    static func safeDurationMs(_ durationMs: Int) -> Int {
        min(max(durationMs, minGestureDurationMs), maxGestureDurationMs)
    }

    /// Click (tap) at a screen-absolute point.
    static func click(at point: CGPoint, targetPID: pid_t? = nil) -> Bool {
        guard let down = makeMouseEvent(.leftMouseDown, at: point),
              let up = makeMouseEvent(.leftMouseUp, at: point) else {
            return false
        }

        let cursorEngaged = engageCursor(targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        post(down, targetPID: targetPID)
        usleep(clickHoldUs)
        post(up, targetPID: targetPID)
        return true
    }

    /// Long press at a screen-absolute point for the specified duration.
    static func longPress(at point: CGPoint, durationMs: Int, targetPID: pid_t? = nil) -> Bool {
        let durationMs = safeDurationMs(durationMs)
        guard let down = makeMouseEvent(.leftMouseDown, at: point),
              let up = makeMouseEvent(.leftMouseUp, at: point) else {
            return false
        }

        // Registered so a shutdown mid-press lifts the button before exiting.
        guard PlaybackInterruption.shared.begin() else { return false }
        defer { PlaybackInterruption.shared.end() }
        let cursorEngaged = engageCursor(targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        post(down, targetPID: targetPID)
        PlaybackInterruption.shared.sleep(microseconds: UInt32(durationMs) * 1000)
        post(up, targetPID: targetPID)
        return true
    }

    /// Double-tap at a screen-absolute point.
    static func doubleTap(at point: CGPoint, targetPID: pid_t? = nil) -> Bool {
        guard let down1 = makeMouseEvent(.leftMouseDown, at: point),
              let up1 = makeMouseEvent(.leftMouseUp, at: point),
              let down2 = makeMouseEvent(.leftMouseDown, at: point),
              let up2 = makeMouseEvent(.leftMouseUp, at: point) else {
            return false
        }

        let cursorEngaged = engageCursor(targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        // First click
        down1.setIntegerValueField(.mouseEventClickState, value: 1)
        post(down1, targetPID: targetPID)
        usleep(clickHoldUs)
        up1.setIntegerValueField(.mouseEventClickState, value: 1)
        post(up1, targetPID: targetPID)

        // Brief inter-click pause (under the double-click threshold)
        usleep(clickHoldUs)

        // Second click with clickState=2 so macOS treats it as a double-click
        down2.setIntegerValueField(.mouseEventClickState, value: 2)
        post(down2, targetPID: targetPID)
        usleep(clickHoldUs)
        up2.setIntegerValueField(.mouseEventClickState, value: 2)
        post(up2, targetPID: targetPID)
        return true
    }

    /// Swipe (scroll wheel) from one screen-absolute point to another.
    /// Uses scroll wheel events since iPhone Mirroring interprets scroll
    /// wheel as swipe gestures (page scrolling, list scrolling).
    static func swipe(from start: CGPoint, to end: CGPoint, durationMs: Int,
                      targetPID: pid_t? = nil) -> Bool {
        let durationMs = safeDurationMs(durationMs)
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y

        // Post scroll at the midpoint so it's within the window
        let midpoint = CGPoint(x: start.x + deltaX / 2, y: start.y + deltaY / 2)

        let cursorEngaged = engageCursor(targetPID: targetPID, warpTo: midpoint)
        defer { disengageCursor(cursorEngaged) }

        // Post a mouseMoved event at the midpoint to firmly establish the
        // cursor inside the window. After a focus switch, the warp alone
        // may not register with the window's event tracking. The mouseMoved
        // event forces macOS to associate the cursor with this window.
        if let move = makeMouseEvent(.mouseMoved, at: midpoint) {
            post(move, targetPID: targetPID)
            usleep(50_000) // 50ms for window to register cursor presence
        }

        // Send a zero-delta "may begin" scroll event to engage the window's
        // scroll handler. After a focus switch, iPhone Mirroring silently drops
        // scroll wheel events until the scroll subsystem is primed. MayBegin
        // simulates a finger touching the trackpad before movement, waking the
        // handler without any visible effect on the iOS screen. Phase values
        // follow the CGScrollPhase convention observed in real trackpad traces:
        // MayBegin=128, Began=1, Changed=2, Ended=4.
        let scrollPhaseField = CGEventField(rawValue: 99)!    // kCGScrollWheelEventScrollPhase
        let momentumPhaseField = CGEventField(rawValue: 123)!  // kCGScrollWheelEventMomentumPhase

        let phaseMayBegin: Int64 = 128

        if let prime = makeScrollEvent(SwipeWheelStep(wheel1: 0, wheel2: 0), at: midpoint) {
            prime.setIntegerValueField(scrollPhaseField, value: phaseMayBegin)
            prime.setIntegerValueField(momentumPhaseField, value: 0)
            post(prime, targetPID: targetPID)
            usleep(warpSettleUs)
        }

        // Both axes use direct-manipulation sign: the content follows the
        // finger, matching real iOS touch and keeping horizontal and vertical
        // consistent. A swipe whose finger moves down (positive deltaY) drags
        // content down; a swipe whose finger moves left (negative deltaX) drags
        // content left, revealing content further right. iPhone Mirroring maps
        // positive wheel1 to content-down and positive wheel2 to content-right,
        // so each wheel delta carries the same sign as its pixel delta.
        // SwipeGestureProfile splits the amplified distance into a drag phase
        // and, for fast flicks, a decaying momentum tail.
        let plan = SwipeGestureProfile.plan(
            deltaX: deltaX, deltaY: deltaY, durationMs: durationMs
        )
        let stepDelay = UInt32(durationMs) * 1000 / UInt32(plan.drag.count)

        // Trackpad-style continuous scroll requires gesture phase flags and
        // precise point-delta fields. iPhone Mirroring ignores bare scroll
        // wheel events that lack these trackpad attributes. Momentum phase
        // values follow the CGMomentumScrollPhase convention observed in real
        // trackpad traces: Begin=1, Continue=2, End=3.
        let phaseBegan: Int64 = 1
        let phaseChanged: Int64 = 2
        let phaseEnded: Int64 = 4
        let phaseNone: Int64 = 0
        let momentumBegin: Int64 = 1
        let momentumContinue: Int64 = 2
        let momentumEnd: Int64 = 3

        // Drag phase: the finger is in contact and moving.
        for (index, step) in plan.drag.enumerated() {
            guard let scroll = makeScrollEvent(step, at: midpoint) else { continue }
            let phase = index == 0 ? phaseBegan : phaseChanged
            scroll.setIntegerValueField(scrollPhaseField, value: phase)
            scroll.setIntegerValueField(momentumPhaseField, value: phaseNone)
            post(scroll, targetPID: targetPID)
            usleep(stepDelay)
        }

        // Finger lift: a zero-delta phaseEnded event, matching a physical
        // trackpad trace. Ending the gesture while deltas are still flowing
        // reads as a stalled drag to iOS paging surfaces, which then settle
        // between pages instead of advancing.
        if let lift = makeScrollEvent(SwipeWheelStep(wheel1: 0, wheel2: 0), at: midpoint) {
            lift.setIntegerValueField(scrollPhaseField, value: phaseEnded)
            lift.setIntegerValueField(momentumPhaseField, value: phaseNone)
            post(lift, targetPID: targetPID)
            usleep(momentumFrameUs)
        }

        // Momentum tail: decaying deltas after the lift, present only for
        // flicks. iOS reads these momentum semantics as a native flick, so
        // paging surfaces (feeds, carousels) snap to the next page. A real
        // trackpad emits no momentum events at all for a slow drag-scroll,
        // so non-flick swipes close with the finger lift alone.
        for (index, step) in plan.momentum.enumerated() {
            guard let scroll = makeScrollEvent(step, at: midpoint) else { continue }
            scroll.setIntegerValueField(scrollPhaseField, value: phaseNone)
            let momentumPhase = index == 0 ? momentumBegin : momentumContinue
            scroll.setIntegerValueField(momentumPhaseField, value: momentumPhase)
            post(scroll, targetPID: targetPID)
            usleep(momentumFrameUs)
        }

        // Close the momentum tail with a zero-delta momentum-end event,
        // matching the real trackpad trace. Without it, iPhone Mirroring
        // waits for further momentum events and ignores the next gesture's
        // phaseBegan, causing stuck scrolls.
        if !plan.momentum.isEmpty,
           let close = makeScrollEvent(SwipeWheelStep(wheel1: 0, wheel2: 0), at: midpoint) {
            close.setIntegerValueField(scrollPhaseField, value: phaseNone)
            close.setIntegerValueField(momentumPhaseField, value: momentumEnd)
            post(close, targetPID: targetPID)
            usleep(stepDelay)
        }

        return true
    }

    /// Create a continuous scroll wheel event carrying one gesture frame.
    /// Phase fields are left for the caller to set.
    private static func makeScrollEvent(
        _ step: SwipeWheelStep, at location: CGPoint
    ) -> CGEvent? {
        guard let scroll = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: step.wheel1,
            wheel2: step.wheel2,
            wheel3: 0
        ) else { return nil }
        scroll.location = location
        // Mark as continuous trackpad gesture with precise pixel deltas
        let isContinuousField = CGEventField(rawValue: 88)!   // kCGScrollWheelEventIsContinuous
        let pointDeltaY = CGEventField(rawValue: 96)!         // kCGScrollWheelEventPointDeltaAxis1
        let pointDeltaX = CGEventField(rawValue: 97)!         // kCGScrollWheelEventPointDeltaAxis2
        scroll.setIntegerValueField(isContinuousField, value: 1)
        scroll.setIntegerValueField(pointDeltaY, value: Int64(step.wheel1))
        scroll.setIntegerValueField(pointDeltaX, value: Int64(step.wheel2))
        return scroll
    }

    /// Drag (sustained mouse contact) from one screen-absolute point to another.
    /// Uses click-drag events (not scroll wheel) for rearranging icons,
    /// adjusting sliders, and drag-and-drop operations.
    static func drag(from start: CGPoint, to end: CGPoint, durationMs: Int,
                     targetPID: pid_t? = nil) -> Bool {
        let durationMs = safeDurationMs(durationMs)
        guard let down = makeMouseEvent(.leftMouseDown, at: start),
              let up = makeMouseEvent(.leftMouseUp, at: end) else {
            return false
        }

        // Registered so a shutdown mid-drag lifts the button before exiting.
        guard PlaybackInterruption.shared.begin() else { return false }
        defer { PlaybackInterruption.shared.end() }
        let cursorEngaged = engageCursor(targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        post(down, targetPID: targetPID)
        postDragPath(from: start, to: end, durationMs: durationMs, targetPID: targetPID)
        post(up, targetPID: targetPID)
        return true
    }

    // MARK: - Keyboard

    /// Microseconds to pause between consecutive keystrokes.
    private static let keystrokeDelayUs: UInt32 = 8_000

    /// Microseconds to pause between dead-key trigger and base character.
    private static let deadKeyDelayUs: UInt32 = 30_000

    /// Modifier flags that we explicitly press/release via flagsChanged events.
    private static let allModifierFlags: CGEventFlags = [
        .maskShift, .maskCommand, .maskAlternate, .maskControl,
    ]

    /// Modifier virtual keycodes (Carbon kVK_*). Order: press in this order,
    /// release in reverse.
    static let modifierKeys: [(flag: CGEventFlags, keycode: UInt16)] = [
        (.maskControl, 0x3B),   // kVK_Control
        (.maskAlternate, 0x3A), // kVK_Option
        (.maskShift, 0x38),     // kVK_Shift
        (.maskCommand, 0x37),   // kVK_Command
    ]

    /// Post a single key event (key-down + key-up) with modifier flags.
    ///
    /// iPhone Mirroring tracks modifier state from explicit flagsChanged events
    /// rather than reading flags from key events. This method sends
    /// flagsChanged press/release events for each required modifier around
    /// the actual keystroke, matching how a physical keyboard works.
    static func postKey(keycode: UInt16, flags: CGEventFlags = CGEventFlags()) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else {
            return false
        }

        let hasModifiers = !flags.intersection(allModifierFlags).isEmpty

        // Press modifier keys explicitly so iPhone Mirroring sees the state change
        if hasModifiers {
            pressModifiers(flags)
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(keystrokeDelayUs)
        up.post(tap: .cghidEventTap)

        // Release modifiers after the keystroke
        if hasModifiers {
            usleep(keystrokeDelayUs)
            releaseModifiers(flags)
        }

        return true
    }

    /// Post flagsChanged events to press the specified modifier keys.
    private static func pressModifiers(_ flags: CGEventFlags) {
        var accumulated = CGEventFlags()
        for (flag, keycode) in modifierKeys {
            if flags.contains(flag) {
                accumulated.insert(flag)
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true) else {
                    continue
                }
                event.type = .flagsChanged
                event.flags = accumulated
                event.post(tap: .cghidEventTap)
                usleep(keystrokeDelayUs)
            }
        }
    }

    /// Post flagsChanged events to release the specified modifier keys (reverse order).
    private static func releaseModifiers(_ flags: CGEventFlags) {
        var remaining = flags.intersection(allModifierFlags)
        for (flag, keycode) in modifierKeys.reversed() {
            if remaining.contains(flag) {
                remaining.remove(flag)
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else {
                    continue
                }
                event.type = .flagsChanged
                event.flags = remaining
                event.post(tap: .cghidEventTap)
                usleep(keystrokeDelayUs)
            }
        }
    }

    /// Post a dead-key sequence (2+ key events with a longer delay between them).
    /// Used for accented characters like é (Option+e, then e).
    static func postKeySequence(_ sequence: CGKeySequence) -> Bool {
        for (index, step) in sequence.steps.enumerated() {
            guard postKey(keycode: step.keycode, flags: step.flags) else {
                return false
            }
            // Use longer delay after the dead-key trigger (first step),
            // shorter delay after subsequent steps.
            if index < sequence.steps.count - 1 {
                usleep(deadKeyDelayUs)
            }
        }
        return true
    }

    /// Trigger a shake gesture by posting Ctrl+Cmd+Z via CGEvent.
    static func shake() -> Bool {
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        // Z key = kVK_ANSI_Z = 0x06
        return postKey(keycode: 0x06, flags: flags)
    }

    // MARK: - Private

    /// Create a CGEvent for the given mouse event type at the specified position.
    static func makeMouseEvent(
        _ type: CGEventType, at point: CGPoint
    ) -> CGEvent? {
        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )
    }

    /// Post an event either to the HID event tap (system-wide) or directly to a PID.
    static func post(_ event: CGEvent, targetPID: pid_t?) {
        if let pid = targetPID {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Prepare cursor for HID-mode pointing: hide cursor and disassociate
    /// physical mouse tracking. In cursor-free mode (targetPID set), this
    /// is a no-op.
    ///
    /// For mouse events (click, drag), the HID pipeline moves the cursor
    /// to the event's coordinates automatically — no warp needed. For scroll
    /// events (swipe), pass `warpTo:` to pre-position the cursor since scroll
    /// routing is based on cursor position.
    static func engageCursor(targetPID: pid_t?, warpTo point: CGPoint? = nil) -> Bool {
        guard targetPID == nil else { return false }
        // Warp BEFORE hiding cursor — hiding first can prevent the warp
        // from registering for scroll event routing in iPhone Mirroring.
        if let point {
            CGWarpMouseCursorPosition(point)
        }
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
        if point != nil {
            usleep(warpSettleUs)
        }
        return true
    }

    /// Re-associate mouse tracking and show cursor if it was engaged.
    static func disengageCursor(_ engaged: Bool) {
        if engaged {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }
}
