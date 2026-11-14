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
// ABOUTME: Shared enum of special key names for keyboard operations.
// ABOUTME: Used by AppleScriptKeyMap and CGEvent-based key press handling.

/// Canonical names for special (non-printable) keyboard keys.
/// Used as the key type for `AppleScriptKeyMap` (macOS virtual key codes)
/// and referenced by CGEvent key press operations.
public enum KeyName: String, CaseIterable, Sendable {
    case `return` = "return"
    case escape = "escape"
    case delete = "delete"
    case tab = "tab"
    case space = "space"
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"

    /// All key names sorted alphabetically, for display in help text and error messages.
    public static var sortedNames: [String] {
        allCases.map(\.rawValue).sorted()
    }
}
