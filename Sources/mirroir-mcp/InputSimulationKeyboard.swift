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
        if let stateError = checkMirroringConnected(tag: "launchApp") {
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

        // Split text into segments: typeable (substituted) vs skip (no mapping).
        let segments = buildTypeSegments(text)
        var skippedChars = ""

        for segment in segments {
            switch segment.method {
            case .keyEvent:
                if let error = typeViaCGEvent(segment.text) {
                    return error
                }
            case .skip:
                // No working paste mechanism — collect skipped characters for the warning
                skippedChars += segment.text
                fputs("InputSimulation: skipping \(segment.text.count) char(s) with no key mapping\n", stderr)
            }
        }

        if !skippedChars.isEmpty {
            return TypeResult(
                success: true,
                warning: "Skipped \(skippedChars.count) character(s) with no key mapping",
                error: nil
            )
        }
        return TypeResult(success: true, warning: nil, error: nil)
    }

    /// A segment of text to be typed, with the method to use.
    enum TypeMethod { case keyEvent, skip }
    struct TypeSegment {
        let text: String
        let method: TypeMethod
    }

    /// Split text into segments based on whether each character can be typed
    /// via CGEvent key events (after layout substitution) or must be skipped.
    func buildTypeSegments(_ text: String) -> [TypeSegment] {
        var segments: [TypeSegment] = []
        var currentText = ""
        var currentMethod: TypeMethod = .keyEvent

        for char in text {
            let substituted = layoutSubstitution[char] ?? char
            let method: TypeMethod = CGKeyMap.lookupSequence(substituted) != nil ? .keyEvent : .skip
            // For key-event segments, use the substituted character (US QWERTY equivalent).
            // For skip segments, use the original character.
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
            switch mod.lowercased() {
            case "shift": flags.insert(.maskShift)
            case "command": flags.insert(.maskCommand)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default:
                return TypeResult(
                    success: false, warning: nil,
                    error: "Unknown modifier '\(mod)'. Supported: shift, command, option, control.")
            }
        }

        let result = CGEventInput.postKey(keycode: keycode, flags: flags)
        DebugLog.log("pressKey", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, warning: nil, error: nil)
        }
        return TypeResult(success: false, warning: nil, error: "CGEvent press_key failed")
    }
}
