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
/// but NOT for iPhone Mirroring, which ignores event coordinates and reads
/// the actual cursor position.
enum CGEventInput {

    /// Milliseconds to pause between mouse-down and mouse-up for a click.
    private static let clickHoldUs: UInt32 = 50_000

    /// Milliseconds to settle after warping cursor before posting events.
    private static let warpSettleUs: UInt32 = 30_000

    /// Click (tap) at a screen-absolute point.
    static func click(at point: CGPoint, targetPID: pid_t? = nil) -> Bool {
        guard let down = makeMouseEvent(.leftMouseDown, at: point),
              let up = makeMouseEvent(.leftMouseUp, at: point) else {
            return false
        }

        let cursorEngaged = engageCursor(at: point, targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        if cursorEngaged { usleep(warpSettleUs) }
        post(down, targetPID: targetPID)
        usleep(clickHoldUs)
        post(up, targetPID: targetPID)
        return true
    }

    /// Long press at a screen-absolute point for the specified duration.
    static func longPress(at point: CGPoint, durationMs: Int, targetPID: pid_t? = nil) -> Bool {
        guard let down = makeMouseEvent(.leftMouseDown, at: point),
              let up = makeMouseEvent(.leftMouseUp, at: point) else {
            return false
        }

        let cursorEngaged = engageCursor(at: point, targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        if cursorEngaged { usleep(warpSettleUs) }
        post(down, targetPID: targetPID)
        usleep(UInt32(durationMs) * 1000)
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

        let cursorEngaged = engageCursor(at: point, targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        // First click
        if cursorEngaged { usleep(warpSettleUs) }
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
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y

        // Post scroll at the midpoint so it's within the window
        let midpoint = CGPoint(x: start.x + deltaX / 2, y: start.y + deltaY / 2)

        let cursorEngaged = engageCursor(at: midpoint, targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        if cursorEngaged { usleep(warpSettleUs) }

        // Send a zero-delta "may begin" scroll event to engage the window's
        // scroll handler. After a focus switch, iPhone Mirroring silently drops
        // scroll wheel events until the scroll subsystem is primed. MayBegin
        // (phase 32) simulates a finger touching the trackpad before movement,
        // waking the handler without any visible effect on the iOS screen.
        let scrollPhaseField = CGEventField(rawValue: 99)!    // kCGScrollWheelEventScrollPhase
        let momentumPhaseField = CGEventField(rawValue: 123)!  // kCGScrollWheelEventMomentumPhase
        let isContinuousField = CGEventField(rawValue: 88)!    // kCGScrollWheelEventIsContinuous
        let pointDeltaY = CGEventField(rawValue: 96)!          // kCGScrollWheelEventPointDeltaAxis1
        let pointDeltaX = CGEventField(rawValue: 97)!          // kCGScrollWheelEventPointDeltaAxis2

        let phaseMayBegin: Int64 = 32

        if let prime = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0
        ) {
            prime.location = midpoint
            prime.setIntegerValueField(isContinuousField, value: 1)
            prime.setIntegerValueField(scrollPhaseField, value: phaseMayBegin)
            prime.setIntegerValueField(momentumPhaseField, value: 0)
            prime.setIntegerValueField(pointDeltaY, value: 0)
            prime.setIntegerValueField(pointDeltaX, value: 0)
            post(prime, targetPID: targetPID)
            usleep(warpSettleUs)
        }

        // Split into steps for a smooth scroll gesture
        let steps = max(5, durationMs / 16) // ~60fps step rate
        let stepDelay = UInt32(durationMs) * 1000 / UInt32(steps)

        // Scroll wheel: positive wheel1 = scroll up (content moves down),
        // negative wheel1 = scroll down (content moves up).
        // A swipe from top to bottom (positive deltaY) means the user
        // dragged downward, which in scroll-wheel terms is scroll-up (positive).
        // Scale factor: continuous trackpad gestures with phase flags have
        // smaller per-pixel displacement than legacy scroll wheel events.
        // Amplify to match physical trackpad scroll distance.
        let scrollAmplification = 3.0
        let totalWheel1 = Int32(deltaY * scrollAmplification)
        let totalWheel2 = Int32(-deltaX * scrollAmplification)

        // Trackpad-style continuous scroll requires gesture phase flags and
        // precise point-delta fields. iPhone Mirroring ignores bare scroll
        // wheel events that lack these trackpad attributes.
        let phaseBegan: Int64 = 1
        let phaseChanged: Int64 = 2
        let phaseEnded: Int64 = 4
        let phaseNone: Int64 = 0

        for i in 1...steps {
            let prevFraction = Double(i - 1) / Double(steps)
            let fraction = Double(i) / Double(steps)
            let w1 = Int32(Double(totalWheel1) * fraction) - Int32(Double(totalWheel1) * prevFraction)
            let w2 = Int32(Double(totalWheel2) * fraction) - Int32(Double(totalWheel2) * prevFraction)

            guard let scroll = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: w1,
                wheel2: w2,
                wheel3: 0
            ) else { continue }
            scroll.location = midpoint

            // Mark as continuous trackpad gesture with precise pixel deltas
            scroll.setIntegerValueField(isContinuousField, value: 1)
            scroll.setIntegerValueField(pointDeltaY, value: Int64(w1))
            scroll.setIntegerValueField(pointDeltaX, value: Int64(w2))

            let phase: Int64
            if i == 1 { phase = phaseBegan }
            else if i == steps { phase = phaseEnded }
            else { phase = phaseChanged }
            scroll.setIntegerValueField(scrollPhaseField, value: phase)
            scroll.setIntegerValueField(momentumPhaseField, value: phaseNone)

            post(scroll, targetPID: targetPID)
            usleep(stepDelay)
        }

        // Send a zero-delta momentum-end event to fully close the gesture.
        // Without this, iPhone Mirroring may wait for momentum events and
        // ignore the next gesture's phaseBegan, causing stuck scrolls.
        if let momentumEnd = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0
        ) {
            momentumEnd.location = midpoint
            momentumEnd.setIntegerValueField(isContinuousField, value: 1)
            momentumEnd.setIntegerValueField(scrollPhaseField, value: phaseNone)
            momentumEnd.setIntegerValueField(momentumPhaseField, value: phaseEnded)
            momentumEnd.setIntegerValueField(pointDeltaY, value: 0)
            momentumEnd.setIntegerValueField(pointDeltaX, value: 0)
            post(momentumEnd, targetPID: targetPID)
            usleep(stepDelay)
        }

        return true
    }

    /// Drag (sustained mouse contact) from one screen-absolute point to another.
    /// Uses click-drag events (not scroll wheel) for rearranging icons,
    /// adjusting sliders, and drag-and-drop operations.
    static func drag(from start: CGPoint, to end: CGPoint, durationMs: Int,
                     targetPID: pid_t? = nil) -> Bool {
        guard let down = makeMouseEvent(.leftMouseDown, at: start),
              let up = makeMouseEvent(.leftMouseUp, at: end) else {
            return false
        }

        let cursorEngaged = engageCursor(at: start, targetPID: targetPID)
        defer { disengageCursor(cursorEngaged) }

        if cursorEngaged { usleep(warpSettleUs) }
        post(down, targetPID: targetPID)

        // Interpolate drag movement
        let steps = max(10, durationMs / 16) // ~60fps
        let stepDelay = UInt32(durationMs) * 1000 / UInt32(steps)

        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            let point = CGPoint(x: x, y: y)

            guard let dragEvent = makeMouseEvent(.leftMouseDragged, at: point) else { continue }
            post(dragEvent, targetPID: targetPID)
            usleep(stepDelay)
        }

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
    private static let modifierKeys: [(flag: CGEventFlags, keycode: UInt16)] = [
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
    private static func makeMouseEvent(
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
    private static func post(_ event: CGEvent, targetPID: pid_t?) {
        if let pid = targetPID {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Warp cursor and disassociate mouse tracking for HID-mode pointing.
    /// In cursor-free mode (targetPID set), this is a no-op.
    /// Returns true if cursor management was engaged.
    private static func engageCursor(at point: CGPoint, targetPID: pid_t?) -> Bool {
        guard targetPID == nil else { return false }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(0)
        return true
    }

    /// Re-associate mouse tracking if cursor management was engaged.
    private static func disengageCursor(_ engaged: Bool) {
        if engaged {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
