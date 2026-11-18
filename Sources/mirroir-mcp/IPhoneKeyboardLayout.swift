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
// ABOUTME: The iPhone's hardware keyboard layout as a character → keystroke table for typing.
// ABOUTME: US QWERTY uses CGKeyMap; any other layout is read from macOS's copy of it via LayoutMapper.

import CoreGraphics
import Foundation
import HelperLib

/// Which keystrokes type each character on the iPhone's hardware keyboard layout.
///
/// iPhone Mirroring forwards physical keys; the iPhone turns them into
/// characters with its own keyboard layout. On US QWERTY the keystrokes come
/// from `CGKeyMap` (including its dead-key sequences for accented letters). On
/// any other layout they come from that layout's own key table, so a
/// character is typed with the key that produces it there — `/` on
/// Canadian-CSA is the ISO section key (keycode 0x0A), not US QWERTY's `/` key
/// (0x2C), which types `é`. Accented letters the layout builds from a dead
/// key (`^` then `e` = `ê`) get that two-keystroke sequence. Return and Tab
/// come from `CGKeyMap.layoutIndependentKeys` on every layout. A character the
/// layout cannot type any of these ways has no sequence, and `typeText` sends
/// it through the clipboard.
struct IPhoneKeyboardLayout: Sendable {
    /// TIS source ID of the layout, or nil for US QWERTY.
    let sourceID: String?
    /// Keystrokes per character (one, or a dead key plus one), or nil for US
    /// QWERTY (`CGKeyMap`).
    private let strokes: [Character: CGKeySequence]?

    /// US QWERTY: keystrokes from `CGKeyMap`.
    static let usQWERTY = IPhoneKeyboardLayout(sourceID: nil, strokes: nil)

    private init(sourceID: String?, strokes: [Character: CGKeySequence]?) {
        self.sourceID = sourceID
        self.strokes = strokes
    }

    /// The layout from a layout name (`"Canadian-CSA"` or a full
    /// `com.apple.keylayout.` source ID). Empty or US names give `usQWERTY`;
    /// a name macOS has no layout for gives nil.
    static func named(_ layout: String) -> IPhoneKeyboardLayout? {
        if LayoutMapper.isUSLayout(layout) { return .usQWERTY }
        guard let (sourceID, data) = LayoutMapper.findNonUSLayout(layout: layout) else {
            return nil
        }
        var strokes = LayoutMapper.keyTable(layoutData: data).mapValues { keySequence([$0]) }
        for (char, pair) in LayoutMapper.deadKeyCompositions(layoutData: data) where strokes[char] == nil {
            strokes[char] = keySequence(pair)
        }
        for (char, mapping) in CGKeyMap.layoutIndependentKeys where strokes[char] == nil {
            strokes[char] = CGKeySequence(steps: [mapping])
        }
        return IPhoneKeyboardLayout(sourceID: sourceID, strokes: strokes)
    }

    private static func keySequence(_ strokes: [LayoutKeyStroke]) -> CGKeySequence {
        CGKeySequence(steps: strokes.map { stroke in
            CGKeyMapping(keycode: stroke.keycode, flags: stroke.shift ? .maskShift : CGEventFlags())
        })
    }

    /// The character `sequence` types on this layout, or nil when none does.
    func character(typedBy sequence: CGKeySequence) -> Character? {
        guard let strokes else { return CGKeyMap.character(typedBy: sequence) }
        return strokes.first { $0.value == sequence }?.key
    }

    /// Keystrokes that type `char` on this layout, or nil when it has none.
    func keySequence(for char: Character) -> CGKeySequence? {
        guard let strokes else { return CGKeyMap.lookupSequence(char) }
        return strokes[char]
    }
}
