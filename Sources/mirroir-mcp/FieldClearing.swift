// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Empties the focused text field (Cmd+A, then Delete) before typing into it.
// ABOUTME: Shared by the type_text tool, the clear_field skill step and run_steps.

import Foundation
import HelperLib

/// Typing appends to whatever a field holds: a pre-filled search field given
/// "Burger" reads "PizzaBurger". Clearing selects everything in the focused
/// field with Cmd+A and deletes it, the two iOS text-editing shortcuts measured
/// to reach the iPhone through mirroring (AGENTS.md, keyboard shortcuts).
/// With no text field focused, Cmd+A acts on whatever the app selects, so a
/// caller clears only a field it has just focused.
enum FieldClearing {
    /// Select-all: Cmd+A.
    static let selectAllKey = "a"
    static let selectAllModifiers = ["command"]
    /// Deletes the selection.
    static let deleteKey = KeyName.delete.rawValue

    /// Select everything in the focused field and delete it. The first key that
    /// fails is the result: nothing is deleted after a select-all that failed.
    static func clear(using input: any InputProviding) -> TypeResult {
        let selected = input.pressKey(keyName: selectAllKey, modifiers: selectAllModifiers)
        guard selected.success else {
            return TypeResult(success: false,
                              error: "Could not select the field's text (Cmd+A): "
                                  + (selected.error ?? "key not delivered"))
        }
        let deleted = input.pressKey(keyName: deleteKey, modifiers: [])
        guard deleted.success else {
            return TypeResult(success: false,
                              error: "Could not delete the field's text (Delete): "
                                  + (deleted.error ?? "key not delivered"))
        }
        return TypeResult(success: true, error: nil)
    }

    /// Type `text`, first clearing the field when `clearFirst` is true. A
    /// clear that failed is returned and nothing is typed.
    static func type(_ text: String, clearFirst: Bool, using input: any InputProviding) -> TypeResult {
        if clearFirst {
            let cleared = clear(using: input)
            guard cleared.success else { return cleared }
        }
        return input.typeText(text)
    }
}
