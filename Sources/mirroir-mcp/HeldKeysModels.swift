// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value types for hold_keys: resolved held keys, the optional button drag, the validated request.
// ABOUTME: Also the keyboard and mouse events one hold is played as, shared by planner, poster, and tool.

import CoreGraphics
import Foundation
import HelperLib

/// A key hold_keys can keep pressed: a plain key that auto-repeats while held,
/// or a modifier that is held through flagsChanged events and never repeats.
struct HeldKey: Sendable, Equatable {
    /// The name the caller gave, lowercased.
    let name: String
    /// macOS virtual keycode (Carbon kVK_*), the same code CGEvent posts.
    let keycode: UInt16
    /// The modifier flag this key sets, or nil for a plain key.
    let modifier: CGEventFlags?

    /// Resolve a key name: a modifier (shift, control, option, command), a
    /// named key (space, return, arrows...), or one character typed without
    /// modifiers. Returns nil for anything else.
    static func resolve(_ rawName: String) -> HeldKey? {
        let name = rawName.lowercased()
        if let flag = CGEventInput.modifierFlag(named: name),
           let keycode = CGEventInput.modifierKeycode(for: flag) {
            return HeldKey(name: name, keycode: keycode, modifier: flag)
        }
        if let keycode = AppleScriptKeyMap.keyCode(for: name) {
            return HeldKey(name: name, keycode: keycode, modifier: nil)
        }
        guard name.count == 1, let char = name.first,
              let mapping = CGKeyMap.lookup(char), mapping.flags.isEmpty else {
            return nil
        }
        return HeldKey(name: name, keycode: mapping.keycode, modifier: nil)
    }
}

/// The mouse button a hold_keys drag holds down.
enum DragButton: String, Sendable, Equatable, CaseIterable {
    /// The primary button: one iOS touch, the same contact a drag uses.
    case left
    /// The secondary button: games with mouse controls turn the camera with it.
    case right
}

/// A button drag performed while the keys are held, in window-relative points.
struct HeldKeysDrag: Sendable, Equatable {
    let fromX: Double
    let fromY: Double
    let toX: Double
    let toY: Double
    let button: DragButton
}

/// One validated hold_keys call: which keys to hold, for how long, and the
/// optional drag performed over the same duration.
struct HeldKeysRequest: Sendable, Equatable {
    let keys: [HeldKey]
    let durationMs: Int
    let drag: HeldKeysDrag?

    /// The MCP tool this request drives.
    static let toolName = "hold_keys"
    /// Fewest keys one call holds.
    static let minKeys = 1
    /// Most keys one call holds: past this, keyboards stop registering chords.
    static let maxKeys = 6
    /// Shortest accepted hold, in milliseconds.
    static let minDurationMs = 100
    /// Longest accepted hold, in milliseconds.
    static let maxDurationMs = 10_000
    /// Hold duration used when the caller gives none, in milliseconds.
    static let defaultDurationMs = 1_000

    /// A request from raw key names, or why the arguments are refused. The
    /// error names the first key that cannot be held.
    static func make(keyNames: [String], durationMs: Int,
                     drag: HeldKeysDrag?) -> Result<HeldKeysRequest, HeldKeysArgumentError> {
        guard keyNames.count >= minKeys, keyNames.count <= maxKeys else {
            return .failure(HeldKeysArgumentError(
                message: "\(toolName) holds \(minKeys) to \(maxKeys) keys (got \(keyNames.count))."))
        }
        var keys: [HeldKey] = []
        for name in keyNames {
            guard let key = HeldKey.resolve(name) else {
                return .failure(HeldKeysArgumentError(message: unmappableMessage(name)))
            }
            guard !keys.contains(where: { $0.keycode == key.keycode }) else {
                return .failure(HeldKeysArgumentError(
                    message: "\(toolName) lists key '\(name)' more than once."))
            }
            keys.append(key)
        }
        guard durationMs >= minDurationMs, durationMs <= maxDurationMs else {
            return .failure(HeldKeysArgumentError(
                message: "\(toolName) duration_ms must be between \(minDurationMs) and "
                    + "\(maxDurationMs) (got \(durationMs))."))
        }
        if let drag, ![drag.fromX, drag.fromY, drag.toX, drag.toY].allSatisfy(\.isFinite) {
            return .failure(HeldKeysArgumentError(
                message: "\(toolName) drag requires finite from_x, from_y, to_x, to_y."))
        }
        return .success(HeldKeysRequest(keys: keys, durationMs: durationMs, drag: drag))
    }

    /// The error for a key name that has no keycode to hold.
    static func unmappableMessage(_ name: String) -> String {
        "\(toolName) cannot hold key '\(name)'. Use a single character typed without "
            + "modifiers (a-z, 0-9, punctuation), a modifier (\(CGEventInput.modifierNames.joined(separator: ", "))), "
            + "or a named key (\(AppleScriptKeyMap.supportedKeys.joined(separator: ", ")))."
    }
}

/// Why hold_keys arguments do not form a request.
struct HeldKeysArgumentError: Error, Equatable {
    let message: String
}

/// One keyboard or mouse event of a hold. Mouse points are screen-absolute.
enum HeldInputEvent: Sendable, Equatable {
    /// A modifier goes down; `flags` are every modifier held after it.
    case modifierDown(HeldKey, flags: CGEventFlags)
    /// A modifier comes up; `flags` are the modifiers still held after it.
    case modifierUp(HeldKey, flags: CGEventFlags)
    /// A plain key goes down, or repeats while held (`isRepeat`).
    case keyDown(HeldKey, flags: CGEventFlags, isRepeat: Bool)
    /// A plain key comes up.
    case keyUp(HeldKey, flags: CGEventFlags)
    /// The drag button goes down at a point.
    case buttonDown(DragButton, at: CGPoint)
    /// The held drag button moves to a point.
    case buttonDragged(DragButton, to: CGPoint)
    /// The drag button comes up at a point.
    case buttonUp(DragButton, at: CGPoint)

    /// Whether this is a keyboard event rather than a button event. Keyboard
    /// events go to whichever Mac app has focus, so they are posted only
    /// while the target is frontmost.
    var isKeyboard: Bool {
        switch self {
        case .modifierDown, .modifierUp, .keyDown, .keyUp: return true
        case .buttonDown, .buttonDragged, .buttonUp: return false
        }
    }
}

/// How a hold ended. Every outcome has already released whatever went down.
enum HeldInputOutcome: Sendable, Equatable {
    /// Every press, frame and release was posted.
    case delivered
    /// An event could not be created or posted.
    case postFailed
    /// The target stopped being the frontmost app, so the keys would have
    /// gone to another Mac app; the hold stopped early.
    case focusLost
    /// Server shutdown stopped the hold early.
    case interrupted
}

/// Events posted back to back, then a pause.
struct HeldInputStep: Sendable, Equatable {
    let events: [HeldInputEvent]
    let pauseAfterUs: UInt32
}

/// A whole hold: the presses, then the frames played while everything is
/// held (drag path and key repeats). Releases are derived from what was
/// actually pressed, so a partial press still comes back up.
struct HeldInputPlan: Sendable, Equatable {
    /// One step per key or button going down, in the order given.
    let presses: [HeldInputStep]
    /// The frames played while everything is held.
    let frames: [HeldInputStep]

    /// Whether the plan presses a mouse button (and so needs the pointer).
    var holdsButton: Bool {
        presses.contains { step in
            step.events.contains { if case .buttonDown = $0 { return true } else { return false } }
        }
    }
}
