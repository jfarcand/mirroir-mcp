// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared enum of special key names used by both AppleScriptKeyMap and HIDSpecialKeyMap.
// ABOUTME: Provides compile-time safety ensuring both maps handle the same set of keys.

/// Canonical names for special (non-printable) keyboard keys.
/// Both `AppleScriptKeyMap` (macOS virtual codes) and `HIDSpecialKeyMap` (USB HID codes)
/// use this enum as their key type, ensuring that adding a new key in one map
/// requires updating the other — a compile-time guarantee that the key sets stay in sync.
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
