// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CGEvent construction for hold_keys: held keys, flagsChanged modifiers, left or right button drags.
// ABOUTME: Also the modifier name table shared by press_key and hold_keys.

import CoreGraphics
import Foundation

extension CGEventInput {

    /// Modifier names callers use, with the flag each sets, in the order
    /// error messages list them.
    private static let namedModifiers: [(name: String, flag: CGEventFlags)] = [
        ("shift", .maskShift),
        ("command", .maskCommand),
        ("option", .maskAlternate),
        ("control", .maskControl),
    ]

    /// Every accepted modifier name.
    static var modifierNames: [String] { namedModifiers.map(\.name) }

    /// The flag a lowercase modifier name sets, or nil when it names none.
    static func modifierFlag(named name: String) -> CGEventFlags? {
        namedModifiers.first { $0.name == name }?.flag
    }

    /// The virtual keycode of the key that sets `flag`, or nil when none does.
    static func modifierKeycode(for flag: CGEventFlags) -> UInt16? {
        modifierKeys.first { $0.flag == flag }?.keycode
    }
}

/// Live `HeldInputPosting`: keyboard events go to the HID event tap, where
/// iPhone Mirroring reads them (as `postKey` does); button events go through
/// `CGEventInput.post`, to the HID tap or one process in cursor-free mode.
struct CGEventHeldInputPoster: HeldInputPosting, CGEventPointerEngaging {

    func post(_ event: HeldInputEvent, targetPID: pid_t?) -> Bool {
        guard let cgEvent = Self.makeEvent(event) else { return false }
        if event.isKeyboard {
            cgEvent.post(tap: .cghidEventTap)
        } else {
            CGEventInput.post(cgEvent, targetPID: targetPID)
        }
        return true
    }

    func pause(microseconds: UInt32) {
        usleep(microseconds)
    }

    /// The CGEvent for one hold event, or nil when CoreGraphics refuses it.
    ///
    /// Modifiers are flagsChanged events carrying the modifiers held after
    /// them: iPhone Mirroring tracks modifier state from those events, not
    /// from the flags of key events. A repeated key down is marked as an
    /// auto-repeat, the way a held physical key reports it.
    static func makeEvent(_ event: HeldInputEvent) -> CGEvent? {
        switch event {
        case .modifierDown(let key, let flags):
            return keyboardEvent(key, down: true, flags: flags, type: .flagsChanged)
        case .modifierUp(let key, let flags):
            return keyboardEvent(key, down: false, flags: flags, type: .flagsChanged)
        case .keyDown(let key, let flags, let isRepeat):
            let cgEvent = keyboardEvent(key, down: true, flags: flags, type: .keyDown)
            cgEvent?.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
            return cgEvent
        case .keyUp(let key, let flags):
            return keyboardEvent(key, down: false, flags: flags, type: .keyUp)
        case .buttonDown(let button, let point):
            return mouseEvent(button.downType, button, point)
        case .buttonDragged(let button, let point):
            return mouseEvent(button.draggedType, button, point)
        case .buttonUp(let button, let point):
            return mouseEvent(button.upType, button, point)
        }
    }

    private static func keyboardEvent(_ key: HeldKey, down: Bool, flags: CGEventFlags,
                                      type: CGEventType) -> CGEvent? {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: key.keycode,
                                    keyDown: down) else { return nil }
        cgEvent.type = type
        cgEvent.flags = flags
        return cgEvent
    }

    private static func mouseEvent(_ type: CGEventType, _ button: DragButton,
                                   _ point: CGPoint) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                mouseButton: button.cgButton)
    }
}

extension DragButton {
    /// The CoreGraphics button this drag holds.
    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        }
    }

    /// The event type that presses this button.
    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        }
    }

    /// The event type that moves this button while it is held.
    var draggedType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        }
    }

    /// The event type that releases this button.
    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        }
    }
}
