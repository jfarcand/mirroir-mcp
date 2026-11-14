// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Concrete Backtracking implementations: OCR-chevron tap for iPhone Mirroring, keyboard shortcut for macOS apps.
// ABOUTME: Delegates to ExplorerUtilities.tapBackButton for OCR-based back navigation; wraps pressKey for keyboard shortcuts.

import CoreGraphics
import Foundation
import HelperLib

/// Tap the "<" back chevron detected in the top navigation bar, falling back to
/// a canonical position in the top-left corner. Used by iPhone Mirroring because
/// iOS apps do not implement Cmd+[: the key arrives and nothing handles it.
struct OCRChevronBacktracker: Backtracking {
    @discardableResult
    func tapBack(
        elements: [TapPoint],
        input: any InputProviding,
        windowSize: CGSize,
        fallback: BackButtonFallback
    ) -> BackOutcome {
        ExplorerUtilities.tapBackButton(
            elements: elements, input: input,
            windowSize: windowSize, fallback: fallback
        )
    }
}

/// Issue a keyboard shortcut (default Cmd+[) to navigate back. Used by native
/// macOS apps where the app's own menu handles back navigation. Targets may
/// override the key and modifiers for apps that use different shortcuts
/// (e.g. Escape for a modal-heavy app).
struct KeyboardShortcutBacktracker: Backtracking {
    /// The key name (matches `InputProviding.pressKey` naming: "[", "escape", etc.).
    let keyName: String
    /// Modifier names (matches `InputProviding.pressKey` naming: "command", "shift", etc.).
    let modifiers: [String]

    /// Default: Cmd+[ — works for Safari, Finder, and most AppKit navigation stacks.
    static let cmdBracket = KeyboardShortcutBacktracker(keyName: "[", modifiers: ["command"])

    /// Alternative: Escape — dismisses modals, often serves as back in simple apps.
    static let escape = KeyboardShortcutBacktracker(keyName: "escape", modifiers: [])

    /// The shortcut as people write it: "Cmd+[", "escape".
    var displayName: String {
        let names = ["command": "Cmd", "shift": "Shift", "option": "Option", "control": "Ctrl"]
        return (modifiers.map { names[$0] ?? $0 } + [keyName]).joined(separator: "+")
    }

    @discardableResult
    func tapBack(
        elements: [TapPoint],
        input: any InputProviding,
        windowSize: CGSize,
        fallback: BackButtonFallback
    ) -> BackOutcome {
        let result = input.pressKey(keyName: keyName, modifiers: modifiers)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        return BackOutcome(action: .shortcut(displayName), error: result.error)
    }
}
