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
// ABOUTME: The iPhone keyboard layouts this Mac's phones may use, and which characters their keys agree on.
// ABOUTME: A character the layouts type with different keys is typed only once the connected phone's layout is known.

import Foundation
import HelperLib

/// The hardware-keyboard layouts `keyboardLayout` names: one per iPhone that
/// takes turns on this Mac. Nothing tells which phone is connected, so a
/// character is typed by key only when every layout types it with the same
/// keys, or when the connected phone's layout was given (`chosen`). A
/// character the layouts disagree on is disputed: typed by its keys on one
/// phone, it types something else on the other (`'` on Canadian-CSA is
/// Shift+0x2B, which is `<` on US), so it is pasted instead.
struct KeyboardLayoutSet: Sendable {

    /// One layout and the name `keyboardLayout` gave it.
    struct Named: Sendable {
        let name: String
        let layout: IPhoneKeyboardLayout
    }

    let layouts: [Named]

    /// US QWERTY alone.
    static let usQWERTY = KeyboardLayoutSet(single: .usQWERTY)

    /// One layout, for a caller (and the tests) that knows the phone's layout.
    init(single layout: IPhoneKeyboardLayout, name: String = "US") {
        layouts = [Named(name: name, layout: layout)]
    }

    init(layouts: [Named]) {
        self.layouts = layouts.isEmpty ? [Named(name: "US", layout: .usQWERTY)] : layouts
    }

    /// The layouts `keyboardLayout` (settings.json) or `IPHONE_KEYBOARD_LAYOUT`
    /// names. A name macOS does not know is reported on stderr and left out;
    /// with none left, typing uses US QWERTY keystrokes.
    static func configured(names: [String] = EnvConfig.keyboardLayouts) -> KeyboardLayoutSet {
        let known = names.compactMap { name -> Named? in
            guard let layout = IPhoneKeyboardLayout.named(name) else {
                fputs("Keyboard layout '\(name)' is not a macOS keyboard layout; it is "
                    + "ignored. Run `mirroir-mcp configure` to pick the iPhone's layout.\n", stderr)
                return nil
            }
            return Named(name: name, layout: layout)
        }
        let set = KeyboardLayoutSet(layouts: known)
        DebugLog.persist("keyboard", "iPhone keyboard layouts: \(set.names.joined(separator: ", "))")
        return set
    }

    var names: [String] { layouts.map(\.name) }

    /// The layout named `name` (case ignored), or nil when it is not one of these.
    func layout(named name: String) -> Named? {
        layouts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Keystrokes for `char`: on `chosen` when the phone's layout is known,
    /// otherwise the keys every layout agrees on. Nil means paste it.
    func keySequence(for char: Character, chosen: IPhoneKeyboardLayout?) -> CGKeySequence? {
        if let chosen { return chosen.keySequence(for: char) }
        let sequences = layouts.map { $0.layout.keySequence(for: char) }
        guard let first = sequences.first ?? nil,
              sequences.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// What `text` typed with `chosen`'s keys shows on each other layout that
    /// types it differently: the evidence that `chosen` was the wrong answer
    /// ("J<arrive" for "J'arrive" typed with Canadian-CSA keys on a US phone).
    func misreadings(of text: String, chosen: IPhoneKeyboardLayout) -> [String] {
        let others = layouts.map(\.layout).filter { $0.sourceID != chosen.sourceID }
        return others.compactMap { other -> String? in
            var shown = ""
            for char in text {
                guard let keys = chosen.keySequence(for: char) else { shown.append(char); continue }
                guard let typed = other.character(typedBy: keys) else { return nil }
                shown.append(typed)
            }
            return shown == text ? nil : shown
        }
    }

    /// The characters of `text`, in order and once each, that some layout
    /// types with other keys than another layout does.
    func disputed(in text: String) -> [Character] {
        guard layouts.count > 1 else { return [] }
        var seen = Set<Character>()
        return text.filter { char in
            let sequences = layouts.map { $0.layout.keySequence(for: char) }
            let typable = sequences.contains { $0 != nil }
            let differs = sequences.contains { $0 != sequences[0] }
            return typable && differs && seen.insert(char).inserted
        }.map { $0 }
    }
}

/// What a `type_text` says about the characters the layouts disagree on
/// (pure transformation). Without an answer the text was pasted, and the
/// caller is told how to answer; with one it was typed by key, and a screen
/// newly showing what another layout types instead is a failure that forgets
/// the answer. Autocorrect rewriting the text is not that evidence: the
/// answer is kept and the usual notice stands.
struct DisputedKeysReport {
    let text: String
    let disputed: [Character]
    /// The layout name given for the connected phone, or nil.
    let chosen: String?
    let layouts: [String]

    /// Whether `result` shows the given layout typed other characters.
    func answerFailed(_ result: TypeResult) -> Bool {
        chosen != nil && !disputed.isEmpty && result.success && result.misreadingShown
    }

    /// The failure for a `chosen` layout the screen shows was wrong.
    private func wrongAnswer(_ chosen: String) -> String {
        let names: String = layouts.joined(separator: ", ")
        let shown = "Typed \"\(text)\" with the \(chosen) keyboard layout, but the screen shows "
        let other = "what another layout types instead: the connected iPhone uses another layout. "
        let forgot = "The \(chosen) answer for this phone is forgotten. Clear the field, then retry "
        let retry = "with keyboard_layout set to the iPhone's hardware keyboard (one of: \(names))."
        return shown + other + forgot + retry
    }

    /// `result` with what the caller needs to know about the disputed characters.
    func apply(to result: TypeResult) -> TypeResult {
        guard !disputed.isEmpty else { return result }
        if let chosen {
            guard answerFailed(result) else { return result }
            return TypeResult(
                success: false,
                error: wrongAnswer(chosen))
        }
        let chars: String = disputed.map { "'\($0)'" }.joined(separator: " ")
        let names: String = layouts.joined(separator: ", ")
        let unknown = "The text holds \(chars), which the keyboard layouts in settings (\(names)) "
        let how = "type with different keys, and which one the connected iPhone uses is not known, "
        let pass = "so it goes through the clipboard. Pass keyboard_layout with its hardware keyboard "
        let onPhone = "(Settings › General › Keyboard › Hardware Keyboard on the iPhone; ask the user) "
        let then = "and it is typed by key from then on, remembered for this phone."
        let hint: String = unknown + how + pass + onPhone + then
        var reported = result
        if result.success {
            reported.notice = result.notice.map { "\(hint)\n\n\($0)" } ?? hint
        } else {
            reported = TypeResult(success: false, error: (result.error ?? "Typing failed") + "\n\n" + hint)
        }
        return reported
    }
}
