/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Live text-entry boundaries: key events posted through CGEventInput and the general pasteboard.
// ABOUTME: InputSimulation types and pastes through these, so tests can swap them for doubles.

import AppKit
import CoreGraphics
import Foundation

/// Live `KeyEventPosting`: forwards to `CGEventInput`, which posts to the HID
/// event tap where iPhone Mirroring reads keyboard events, or to one process.
struct CGEventKeyPoster: KeyEventPosting {

    func postKey(keycode: UInt16, flags: CGEventFlags, targetPID: pid_t?) -> Bool {
        CGEventInput.postKey(keycode: keycode, flags: flags, targetPID: targetPID)
    }

    func postKeySequence(_ sequence: CGKeySequence, targetPID: pid_t?) -> Bool {
        CGEventInput.postKeySequence(sequence, targetPID: targetPID)
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
