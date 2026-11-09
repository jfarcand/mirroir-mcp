// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Plans the events of one key press: modifiers down, the key down and up, modifiers up in reverse.
// ABOUTME: A pure value, so a test can prove that every press ends with no modifier held.

import CoreGraphics
import Foundation

/// The events of one key press, in posting order.
///
/// iPhone Mirroring tracks modifier state from flagsChanged events, not from
/// the flags a key event carries. A modifier that goes down and is never
/// released would mark every later keystroke, so the release is part of the
/// plan and uses the same reverse-order logic a held key does.
enum KeyStrokePlanner {

    /// Each modifier in `flags` down (control, option, shift, command), the
    /// key down and up, then the modifiers up in reverse. The last event
    /// carries no modifier.
    static func events(keycode: UInt16, flags: CGEventFlags) -> [HeldInputEvent] {
        var held = CGEventFlags()
        var presses: [HeldInputEvent] = []
        for (flag, modifierKeycode) in CGEventInput.modifierKeys where flags.contains(flag) {
            held.insert(flag)
            presses.append(.modifierDown(.unnamed(keycode: modifierKeycode, modifier: flag), flags: held))
        }
        presses.append(.keyDown(.unnamed(keycode: keycode, modifier: nil), flags: flags, isRepeat: false))
        return presses + HeldKeysPlanner.releases(for: presses, buttonPoint: .zero)
    }

    /// Whether a press holds a modifier around its key.
    static func isChord(_ events: [HeldInputEvent]) -> Bool {
        events.contains { if case .modifierDown = $0 { return true } else { return false } }
    }

    /// The modifiers still held once `events` have been played in order.
    static func heldModifiers(after events: [HeldInputEvent]) -> CGEventFlags {
        events.reduce(into: CGEventFlags()) { held, event in
            switch event {
            case .modifierDown(let key, _):
                if let flag = key.modifier { held.insert(flag) }
            case .modifierUp(let key, _):
                if let flag = key.modifier { held.remove(flag) }
            case .keyDown, .keyUp, .buttonDown, .buttonDragged, .buttonUp:
                break
            }
        }
    }
}
