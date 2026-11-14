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
// ABOUTME: Maps iPhone Mirroring's three navigation menu items (Home Screen, App Switcher, Spotlight) to their Cmd+digit shortcuts.
// ABOUTME: Used as a locale-invariant fallback when AX menu lookup fails because macOS has localized the menu titles.

import Foundation

/// MenuShortcuts — locale-invariant keyboard shortcut for iPhone Mirroring's
/// View-menu navigation items.
///
/// `MirroringBridge.triggerMenuAction` matches menu and item titles by exact
/// string. On non-English macOS locales the iPhone Mirroring menu titles are
/// translated, so the AX lookup misses. The keyboard shortcuts Cmd+1/2/3 are
/// not localized — they map to the same physical key positions regardless of
/// system language. This enum lets the bridge fall back to CGEvent when the
/// AX path fails.
enum MenuShortcuts {

    struct Shortcut: Sendable {
        /// Carbon virtual keycode (kVK_ANSI_1 = 0x12, _2 = 0x13, _3 = 0x14).
        let keycode: UInt16
        /// Human label for debug logs (e.g. "1").
        let label: String
    }

    /// Returns the Cmd+digit shortcut for a known View-menu navigation item,
    /// or nil if `itemName` is not one of the three nav items.
    ///
    /// Match is case-insensitive on the English title. Localized titles will
    /// not match here — callers fall back to this shortcut only after the
    /// AX-by-title lookup misses, so the English name is still the entry key.
    static func viewNavShortcut(for itemName: String) -> Shortcut? {
        switch itemName.lowercased() {
        case "home screen":  return Shortcut(keycode: 0x12, label: "1")
        case "app switcher": return Shortcut(keycode: 0x13, label: "2")
        case "spotlight":    return Shortcut(keycode: 0x14, label: "3")
        default:             return nil
        }
    }
}
