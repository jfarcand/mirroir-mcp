// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Live text-entry boundaries: key events posted through CGEventInput and the general pasteboard.
// ABOUTME: InputSimulation types and pastes through these, so tests can swap them for doubles.

import AppKit
import CoreGraphics
import Foundation

/// Live `KeyEventPosting`: forwards to `CGEventInput`, which posts to the HID
/// event tap where iPhone Mirroring reads keyboard events.
struct CGEventKeyPoster: KeyEventPosting {

    func postKey(keycode: UInt16, flags: CGEventFlags) -> Bool {
        CGEventInput.postKey(keycode: keycode, flags: flags)
    }

    func postKeySequence(_ sequence: CGKeySequence) -> Bool {
        CGEventInput.postKeySequence(sequence)
    }
}

/// Live `PasteboardAccessing`: `NSPasteboard.general`, the pasteboard
/// Universal Clipboard syncs to the iPhone. Only the plain-text flavor is
/// read and written.
struct GeneralPasteboard: PasteboardAccessing {

    func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func replaceContents(with text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
