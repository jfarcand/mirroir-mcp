// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Keyboard input, shake, and app-level operations for InputSimulation.
// ABOUTME: Split from InputSimulation.swift to stay under the 500-line limit.

import AppKit
import Carbon
import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Trigger a shake gesture on the mirrored iPhone.
    /// Sends Ctrl+Cmd+Z via CGEvent which triggers shake-to-undo in iOS apps.
    func shake() -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "shake") {
            return TypeResult(success: false, warning: nil, error: keyboardError)
        }

        DebugLog.log("shake", "sending shake gesture via CGEvent")
        ensureTargetFrontmost()

        let result = CGEventInput.shake()
        DebugLog.log("shake", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "CGEvent shake failed")
    }

    /// Launch an app by name using Spotlight search.
    /// Opens Spotlight, types the app name, waits for results, and presses Return.
    /// Returns nil on success, or an error message on failure.
    func launchApp(name: String) -> String? {
        if let stateError = ensureConnected(tag: "launchApp") {
            return stateError
        }
        DebugLog.log("launchApp", "launching '\(name)'")

        // Step 1: Open Spotlight via menu action (requires MenuActionCapable)
        guard let menuBridge = bridge as? (any MenuActionCapable),
              menuBridge.triggerMenuAction(menu: "View", item: "Spotlight") else {
            DebugLog.log("launchApp", "ERROR: failed to open Spotlight")
            return "Failed to open Spotlight. Is target '\(bridge.targetName)' running?"
        }
        usleep(EnvConfig.spotlightAppearanceUs)

        // Step 2: Type the app name
        let typeResult = typeText(name)
        guard typeResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to type app name")
            return typeResult.error ?? "Failed to type app name"
        }
        usleep(EnvConfig.searchResultsPopulateUs)

        // Step 3: Press Return to launch the top result
        let keyResult = pressKey(keyName: "return")
        guard keyResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to press Return")
            return keyResult.error ?? "Failed to press Return"
        }

        DebugLog.log("launchApp", "launched '\(name)' OK")
        return nil
    }

    /// Open a URL on the mirrored iPhone by launching Safari and navigating to it.
    /// Opens Safari via Spotlight, selects the address bar with Cmd+L, types the URL,
    /// and presses Return to navigate.
    /// Returns nil on success, or an error message on failure.
    func openURL(_ url: String) -> String? {
        DebugLog.log("openURL", "opening '\(url)'")

        // Step 1: Launch Safari
        if let error = launchApp(name: "Safari") {
            return error
        }
        usleep(EnvConfig.safariLoadUs)

        // Step 2: Select the address bar with Cmd+L (works whether Safari was
        // already open or just launched, and clears any existing URL)
        let selectResult = pressKey(keyName: "l", modifiers: ["command"])
        guard selectResult.success else {
            return selectResult.error ?? "Failed to select address bar"
        }
        usleep(EnvConfig.addressBarActivateUs)

        // Step 3: Type the URL
        let typeResult = typeText(url)
        guard typeResult.success else {
            return typeResult.error ?? "Failed to type URL"
        }
        usleep(EnvConfig.preReturnUs)

        // Step 4: Press Return to navigate
        let goResult = pressKey(keyName: "return")
        guard goResult.success else {
            return goResult.error ?? "Failed to press Return"
        }

        return nil
    }

    /// Type text via CGEvent keyboard events.
    ///
    /// CGEvent keycodes are layout-independent physical keys (same concept as
    /// USB HID keycodes). When `IPHONE_KEYBOARD_LAYOUT` is set to a non-US
    /// layout, characters are translated through a layout substitution table
    /// before mapping to keycodes. Characters with no CGKeyMap mapping are
    /// skipped and reported in the warning field of the result.
    func typeText(_ text: String) -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "typeText") {
            return TypeResult(success: false, warning: nil, error: keyboardError)
        }

        DebugLog.log("typeText", "typing \(text.count) char(s)")
        ensureTargetFrontmost()

        // Split text into segments: typeable via keycodes vs pasted via clipboard.
        let segments = buildTypeSegments(text)

        // One clipboard round-trip per call, never one per segment. Universal
        // Clipboard propagates asynchronously and slower than a keystroke, so
        // two writes in quick succession race: the second Cmd+V fires while the
        // device still holds the first value and pastes it AGAIN. Observed
        // on-device — "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c} \u{1f389}" arrived as the Japanese run twice with the
        // emoji missing. Pasting the whole string once cannot race itself, and a
        // wrong-but-plausible result is worse than a warned-about empty field.
        let unmappable = segments.filter { $0.method == .paste }
        if !unmappable.isEmpty {
            let result = pasteText(text)
            guard result.success else { return result }
            let count = unmappable.reduce(0) { $0 + $1.text.count }
            return TypeResult(success: true, warning: Self.pasteDependencyWarning(count),
                              error: nil)
        }

        for segment in segments {
            if let error = typeViaCGEvent(segment.text) {
                return error
            }
        }
        return TypeResult(success: true, warning: nil, error: nil)
    }

    /// Warning attached whenever some of the text had to go through the clipboard.
    ///
    /// The keystroke path is self-contained, but the clipboard path is not: it
    /// relies on Universal Clipboard to carry the Mac pasteboard to the device.
    /// Cmd+V itself is reliable — verified on-device to paste the *iPhone's*
    /// clipboard — so when the field ends up empty, the missing piece is the
    /// Mac-to-iPhone sync, not the keystroke. There is no API to read the
    /// device's pasteboard back, so this cannot be verified from here; saying so
    /// is better than reporting a success the caller cannot trust.
    static func pasteDependencyWarning(_ count: Int) -> String {
        """
        \(count) character(s) have no key mapping and were sent through the \
        clipboard with Cmd+V. That path needs Universal Clipboard: Handoff \
        enabled on both the Mac and the iPhone, Bluetooth and Wi-Fi on, and both \
        signed into the same iCloud account. If the field is still empty, \
        Handoff is the thing to check — verify before relying on this text.
        """
    }

    /// Enter text that has no keycode mapping by routing it through the shared
    /// pasteboard and pressing Cmd+V.
    ///
    /// CJK, emoji, and most non-Latin characters have no macOS virtual keycode:
    /// they are composed through an input method, which CGEvent cannot drive.
    /// The pasteboard is therefore the only path that enters them at all.
    /// iOS handles Cmd+V as a standard text-editing shortcut in a focused field
    /// — verified on-device, along with Cmd+A and Cmd+C, so Cmd-modified keys do
    /// reach iOS text fields through mirroring.
    ///
    /// What is NOT guaranteed is that the Mac pasteboard reaches the device at
    /// all: that is Universal Clipboard, which needs Handoff enabled on both
    /// ends. With Handoff off, Cmd+V still fires and still pastes — but it
    /// pastes the iPhone's own clipboard, so the text written here never
    /// arrives. The device pasteboard cannot be read back from here, so callers
    /// are warned rather than given a success they cannot trust.
    ///
    /// The previous pasteboard contents are restored afterwards so automation
    /// does not clobber what the user had copied. Only the plain-text
    /// representation is preserved — richer flavors (RTF, images) are lost, so
    /// the restore is a courtesy, not a guarantee.
    ///
    /// Requires a focused text field on the device; with nothing focused, iOS
    /// has nowhere to paste and the text is silently dropped.
    func pasteText(_ text: String) -> TypeResult {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return TypeResult(
                success: false, warning: nil,
                error: "Failed to place \(text.count) character(s) on the pasteboard")
        }
        usleep(EnvConfig.pasteboardSyncUs)

        DebugLog.log("pasteText", "pasting \(text.count) char(s) via Cmd+V")
        let result = pressKey(keyName: "v", modifiers: ["command"])
        usleep(EnvConfig.pasteCommitUs)

        if let saved {
            pasteboard.clearContents()
            _ = pasteboard.setString(saved, forType: .string)
        }

        guard result.success else {
            return TypeResult(
                success: false, warning: nil,
                error: result.error ?? "Cmd+V paste failed")
        }
        return TypeResult(success: true, warning: nil, error: nil)
    }

    /// A segment of text to be typed, with the method to use.
    enum TypeMethod { case keyEvent, paste }
    struct TypeSegment {
        let text: String
        let method: TypeMethod
    }

    /// Split text into segments based on whether each character can be typed
    /// via CGEvent key events (after layout substitution) or must be pasted.
    func buildTypeSegments(_ text: String) -> [TypeSegment] {
        var segments: [TypeSegment] = []
        var currentText = ""
        var currentMethod: TypeMethod = .keyEvent

        for char in text {
            let substituted = layoutSubstitution[char] ?? char
            let method: TypeMethod = CGKeyMap.lookupSequence(substituted) != nil ? .keyEvent : .paste
            // For key-event segments, use the substituted character (US QWERTY equivalent).
            // For paste segments, use the original character — the clipboard carries
            // it verbatim, so no layout substitution applies.
            let outputChar = method == .keyEvent ? substituted : char

            if method == currentMethod {
                currentText.append(outputChar)
            } else {
                if !currentText.isEmpty {
                    segments.append(TypeSegment(text: currentText, method: currentMethod))
                }
                currentText = String(outputChar)
                currentMethod = method
            }
        }
        if !currentText.isEmpty {
            segments.append(TypeSegment(text: currentText, method: currentMethod))
        }

        return segments
    }

    /// Type text by posting CGEvent keyboard events for each character.
    private func typeViaCGEvent(_ text: String) -> TypeResult? {
        for char in text {
            guard let sequence = CGKeyMap.lookupSequence(char) else {
                return TypeResult(
                    success: false,
                    warning: nil,
                    error: "No key mapping for character '\(char)'"
                )
            }
            guard CGEventInput.postKeySequence(sequence) else {
                return TypeResult(
                    success: false,
                    warning: nil,
                    error: "CGEvent key post failed for '\(char)'"
                )
            }
            usleep(EnvConfig.keystrokeDelayUs)
        }
        return nil // success
    }

    /// Send a special key press (Return, Escape, arrows, etc.) with optional modifiers
    /// via CGEvent keyboard events. Also handles single printable characters with modifiers
    /// (e.g., Cmd+L for Safari address bar).
    func pressKey(keyName: String, modifiers: [String] = []) -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "pressKey") {
            return TypeResult(success: false, warning: nil, error: keyboardError)
        }

        let modStr = modifiers.isEmpty ? "" : " modifiers=\(modifiers.joined(separator: "+"))"
        DebugLog.log("pressKey", "key=\(keyName)\(modStr)")
        ensureTargetFrontmost()

        // Resolve the virtual keycode: try special key names first, then single characters
        let keycode: UInt16
        if let specialCode = AppleScriptKeyMap.keyCode(for: keyName) {
            keycode = specialCode
        } else if keyName.count == 1, let char = keyName.first,
                  let mapping = CGKeyMap.lookup(Character(String(char).lowercased())) {
            keycode = mapping.keycode
        } else {
            return TypeResult(
                success: false, warning: nil,
                error: "Unknown key '\(keyName)'. Supported: \(AppleScriptKeyMap.supportedKeys.joined(separator: ", ")), or a single character.")
        }

        // Map modifier strings to CGEventFlags
        var flags = CGEventFlags()
        for mod in modifiers {
            guard let flag = CGEventInput.modifierFlag(named: mod.lowercased()) else {
                return TypeResult(
                    success: false, warning: nil,
                    error: "Unknown modifier '\(mod)'. Supported: \(CGEventInput.modifierNames.joined(separator: ", ")).")
            }
            flags.insert(flag)
        }

        let result = CGEventInput.postKey(keycode: keycode, flags: flags)
        DebugLog.log("pressKey", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "CGEvent press_key failed")
    }
}
