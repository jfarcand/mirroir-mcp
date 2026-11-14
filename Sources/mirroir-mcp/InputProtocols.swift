// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: System-boundary protocols for input: taps, swipes and keys, the pointer, held input, window-addressed
// ABOUTME: events, the pasteboard, gestures and touch contacts.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Abstracts user input simulation (tap, swipe, type, etc.) via CGEvent.
protocol InputProviding: Sendable {
    func tap(x: Double, y: Double, cursorMode: CursorMode?) -> String?
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode?) -> String?
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode?) -> String?
    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode?) -> String?
    func doubleTap(x: Double, y: Double, cursorMode: CursorMode?) -> String?
    func shake() -> TypeResult
    func typeText(_ text: String) -> TypeResult
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult
    func launchApp(name: String) -> String?
    func openURL(_ url: String) -> String?
    /// Make sure the target accepts input: launch it when it is not running and
    /// free a paused session (iPhone Mirroring's Resume, OK or Try Again).
    /// Returns nil when it is connected, else the refusal to report, which
    /// quotes what the window says and names the next move.
    func ensureConnected(tag: String) -> String?
    /// Drive the single persistent touch contact that spans calls (begin,
    /// move, end, cancel). While it is held, every other pointing operation
    /// refuses. Coordinates are window-relative, like `tap`.
    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError>
    /// Perform a validated two-finger pinch or rotate centred at the request's
    /// window-relative point. Returns nil on success, or an error message.
    func gesture(_ request: GestureRequest) -> String?
    /// Hold the request's keys for its duration, re-posting key downs as
    /// auto-repeat, optionally dragging a mouse button over the same time,
    /// then release everything in reverse order. Returns nil on success, or
    /// an error message.
    func holdKeys(_ request: HeldKeysRequest) -> String?
}

/// Hides the cursor and detaches it from the physical mouse while synthetic
/// pointing input holds a button or runs a gesture, so the user's own mouse
/// movement cannot drag the held contact elsewhere.
protocol PointerEngaging: Sendable {
    /// Engage the pointer for input going to `targetPID` (nil: the HID tap).
    /// Returns whether it did (false in cursor-free mode).
    func engagePointer(targetPID: pid_t?) -> Bool
    /// Undo `engagePointer` when it returned true.
    func disengagePointer(_ engaged: Bool)
}

/// The live pointer engagement through `CGEventInput`, shared by every live
/// CGEvent poster so there is one implementation of it.
protocol CGEventPointerEngaging: PointerEngaging {}

extension CGEventPointerEngaging {
    func engagePointer(targetPID: pid_t?) -> Bool {
        CGEventInput.engageCursor(targetPID: targetPID)
    }

    func disengagePointer(_ engaged: Bool) {
        CGEventInput.disengageCursor(engaged)
    }
}

/// Posts the keyboard and mouse events of one hold_keys call. Mouse points are
/// screen-absolute; `targetPID` routes button events to one process
/// (cursor-free mode) instead of the HID event tap.
protocol HeldInputPosting: PointerEngaging {
    /// Post one key, modifier or button event. Returns false when the event
    /// could not be created.
    func post(_ event: HeldInputEvent, targetPID: pid_t?) -> Bool
    /// Wait between events.
    func pause(microseconds: UInt32)
}

/// Reads the text a macOS app reports for one window through its accessibility tree.
protocol AccessibilityTextReading: Sendable {
    /// The text nodes of the window `window` names, frames in window-local
    /// points; or why the tree could not be read.
    func readText(in window: WindowInfo) -> Result<AccessibilityTextSnapshot, AccessibilityTextUnreadable>
}

/// Posts the key events of type_text and press_key, to the HID event tap or,
/// when `targetPID` is set, to that one process.
protocol KeyEventPosting: Sendable {
    /// Post one key press (down then up) carrying `flags`. Returns false when
    /// the event could not be created.
    func postKey(keycode: UInt16, flags: CGEventFlags, targetPID: pid_t?) -> Bool
    /// Post every key press that types one character (a dead key and its
    /// base, for accents). Returns false when one could not be created.
    func postKeySequence(_ sequence: CGKeySequence, targetPID: pid_t?) -> Bool
}

/// Posts clicks and keystroke focus to one window without making its app
/// active, so the user keeps the Mac's front app and cursor. Points are
/// window-local.
protocol WindowEventPosting: Sendable {
    /// Press (`down`) or lift the primary button at `point` in `window`, as
    /// click `clickCount` of a multi-click. Returns false when it was not posted.
    func postButton(down: Bool, at point: CGPoint, clickCount: Int, in window: WindowInfo) -> Bool
    /// Make `window` its app's key window, so key events posted to its
    /// process reach it. Returns false when it was not posted.
    func focusKeys(in window: WindowInfo) -> Bool
    /// Wait between button events.
    func pause(microseconds: UInt32)
    /// Whether `stamp` can address an event to a window on this Mac.
    var canStampEvents: Bool { get }
    /// Address `event` to `window` at the window-local `point`, so posting it
    /// to the window's process reaches that window with the pointer elsewhere.
    func stamp(_ event: CGEvent, at point: CGPoint, in window: WindowInfo)
}

/// The Mac's general pasteboard: type_text carries unmappable runs through it,
/// and Universal Clipboard carries it to the iPhone.
protocol PasteboardAccessing: Sendable {
    /// The plain-text contents, or nil when the pasteboard holds no text.
    func string() -> String?
    /// Replace the contents with `text`. Returns false when the pasteboard
    /// refused the write.
    func replaceContents(with text: String) -> Bool
}

/// Posts the CGEvents of a two-finger trackpad gesture (pinch, rotate) that
/// iPhone Mirroring forwards to iOS as a UIKit two-finger gesture. Points are
/// screen-absolute; `targetPID` routes events to one process (cursor-free
/// mode) instead of the HID event tap.
protocol GestureEventPosting: PointerEngaging {
    /// Post one gesture event at `centre`, stamped with the trackpad `senderID`.
    /// Returns false when the event could not be created.
    func post(_ event: GestureEvent, at centre: CGPoint, senderID: UInt64, targetPID: pid_t?) -> Bool
    /// Wait between gesture frames.
    func pause(microseconds: UInt32)
}

/// Finds the multitouch trackpad whose HID service a gesture event must name
/// as its sender: iPhone Mirroring ignores a gesture event whose sender is not
/// a real multitouch trackpad.
protocol MultitouchSenderResolving: Sendable {
    /// IORegistry entry ID of the Mac's multitouch trackpad (built-in first,
    /// then a Magic Trackpad), or nil when the Mac has none.
    func multitouchSenderID() -> UInt64?
}

/// Posts the CGEvent primitives of one persistent touch contact: a held left
/// button is one real iOS touch, and it stays down across calls until released.
/// All points are screen-absolute. `targetPID` routes events to one process
/// (cursor-free mode) instead of the HID event tap.
protocol TouchContactPosting: PointerEngaging {
    /// Press the left button at `point` (touch down).
    func press(at point: CGPoint, targetPID: pid_t?) -> Bool
    /// Move the held button from `start` to `end` over `durationMs`.
    func move(from start: CGPoint, to end: CGPoint, durationMs: Int, targetPID: pid_t?) -> Bool
    /// Release the left button at `point` (touch up).
    func release(at point: CGPoint, targetPID: pid_t?) -> Bool
    /// Where the system pointer is right now.
    func pointerLocation() -> CGPoint
    /// Put the system pointer back at `point`.
    func warpPointer(to point: CGPoint)
}

/// Default nil cursorMode for backward compatibility.
extension InputProviding {
    func tap(x: Double, y: Double) -> String? {
        tap(x: x, y: y, cursorMode: nil)
    }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int) -> String? {
        swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
              durationMs: durationMs, cursorMode: nil)
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int) -> String? {
        drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
             durationMs: durationMs, cursorMode: nil)
    }
    func longPress(x: Double, y: Double, durationMs: Int) -> String? {
        longPress(x: x, y: y, durationMs: durationMs, cursorMode: nil)
    }
    func doubleTap(x: Double, y: Double) -> String? {
        doubleTap(x: x, y: y, cursorMode: nil)
    }
}

// MARK: - Conformances

extension InputSimulation: InputProviding {}
