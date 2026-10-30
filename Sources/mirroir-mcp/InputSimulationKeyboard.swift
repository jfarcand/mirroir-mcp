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
            return TypeResult(success: false, error: keyboardError)
        }

        DebugLog.log("shake", "sending shake gesture via CGEvent")
        ensureTargetFrontmost()

        let result = CGEventInput.shake()
        DebugLog.log("shake", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, error: nil)
        }
        return TypeResult(success: false, error: "CGEvent shake failed")
    }

    /// Launch an app by name using Spotlight search.
    /// Opens Spotlight, types the app name, waits for results, and presses Return.
    /// Returns nil on success, or an error message on failure.
    func launchApp(name: String) -> String? {
        if let stateError = ensureConnected(tag: "launchApp") {
            return stateError
        }
        DebugLog.log("launchApp", "launching '\(name)'")

        // Step 1: Open Spotlight via menu action (requires MenuActionCapable). The
        // screen before it is kept to tell when Spotlight has opened.
        let beforeOpen = pasteVerifier?.describe(settleTimeoutUs: 0)?.elements ?? []
        guard let menuBridge = bridge as? (any MenuActionCapable),
              menuBridge.triggerMenuAction(menu: "View", item: "Spotlight") else {
            DebugLog.log("launchApp", "ERROR: failed to open Spotlight")
            return "Failed to open Spotlight. Is target '\(bridge.targetName)' running?"
        }
        usleep(EnvConfig.spotlightAppearanceUs)

        // Step 2: Type the app name, and confirm Spotlight shows it before Return.
        // Spotlight can reopen holding the previous query in a state that swallows
        // keystrokes; Return would then launch the previous result.
        // Spotlight opened while a Home transition finishes is closed again by it,
        // so a Spotlight that never shows is opened once more before giving up.
        guard let opened = spotlightScreen(replacing: beforeOpen)
                ?? (menuBridge.triggerMenuAction(menu: "View", item: "Spotlight")
                    ? spotlightScreen(replacing: beforeOpen) : nil) else {
            return "Spotlight did not open (or the screen could not be read), so " +
                "'\(name)' was not searched for; Return was not pressed."
        }
        // An app tile already showing the app (the held query's top hit, or a Siri
        // suggestion) is tapped instead: typing into a held query is ignored.
        if let tile = SpotlightAppTile.label(for: name, in: opened.elements) {
            return openTile(tile, name: name, spotlight: opened.elements)
        }
        let before = opened.elements.map(\.text)
        let typeResult = typeText(name)
        guard typeResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to type app name")
            return typeResult.error ?? "Failed to type app name"
        }
        usleep(EnvConfig.searchResultsPopulateUs)
        guard spotlightShows(name, comparedTo: before) else {
            // Spotlight can open on its idle page, then restore the held query that
            // swallowed the typing: its tile for this app still opens it.
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               let tile = SpotlightAppTile.label(for: name, in: screen.elements) {
                return openTile(tile, name: name, spotlight: screen.elements)
            }
            DebugLog.log("launchApp", "ERROR: '\(name)' never appeared in Spotlight")
            return "Typed '\(name)' into Spotlight but it never appeared on screen, so " +
                "Return was not pressed. Spotlight may be holding a previous query, or " +
                "keystrokes are not reaching the iPhone."
        }

        // Step 3: Press Return to launch the top result
        let keyResult = pressKey(keyName: "return")
        guard keyResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to press Return")
            return keyResult.error ?? "Failed to press Return"
        }

        DebugLog.log("launchApp", "launched '\(name)' OK")
        return nil
    }

    /// Every text line on screen, read once through `pasteVerifier`. Nil when
    /// there is no reader or the screen cannot be read.
    private func screenLines() -> [String]? {
        guard let result = pasteVerifier?.describe(settleTimeoutUs: 0),
              result.ocrFailure == nil else { return nil }
        return result.elements.map(\.text)
    }

    /// The screen once Spotlight shows on it, polling for up to
    /// `pasteVerifyTimeoutUs`; nil when it never does or cannot be read. Spotlight
    /// shows when its known headings appear or the screen no longer matches
    /// `previous` (the headings are localized, and only some locales are known).
    private func spotlightScreen(replacing previous: [TapPoint]) -> ScreenDescriber.DescribeResult? {
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               screen.ocrFailure == nil,
               SpotlightDetector.isSpotlightVisible(elements: screen.elements)
                || !StructuralFingerprint.areEquivalent(previous, screen.elements) {
                return screen
            }
        }
        return nil
    }

    /// Tap the Spotlight tile showing `name`, then confirm Spotlight closed: its
    /// known headings are gone and the screen no longer matches `spotlight`,
    /// polling for up to `pasteVerifyTimeoutUs`. Nil on success, else why it failed.
    private func openTile(_ tile: TapPoint, name: String, spotlight: [TapPoint]) -> String? {
        DebugLog.log("launchApp", "tapping the '\(name)' tile Spotlight already shows")
        if let tapError = tap(x: tile.tapX, y: tile.tapY) {
            return "Failed to tap the '\(name)' tile in Spotlight: \(tapError)"
        }
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               screen.ocrFailure == nil,
               !SpotlightDetector.isSpotlightVisible(elements: screen.elements),
               !StructuralFingerprint.areEquivalent(spotlight, screen.elements) {
                return nil
            }
        }
        return "Tapped the '\(name)' tile in Spotlight but Spotlight is still open, so " +
            "'\(name)' did not launch."
    }

    /// Whether `name` shows up on screen more often than in `before`, polling
    /// for up to `pasteVerifyTimeoutUs`.
    private func spotlightShows(_ name: String, comparedTo before: [String]) -> Bool {
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let lines = screenLines(),
               PasteNeedle.appearedAgain(name, before: before, after: lines) {
                return true
            }
        }
        return false
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

    /// Type text via CGEvent keyboard events, pasting only what has no key.
    ///
    /// CGEvent keycodes are layout-independent physical keys (same concept as
    /// USB HID keycodes). Each character is typed with the key that produces it
    /// on the iPhone's layout (`keyboardLayout`, from `keyboardLayout` /
    /// `IPHONE_KEYBOARD_LAYOUT`). Runs that layout cannot type go through the
    /// clipboard one run at a time, and `VerifiedTextEntry` confirms each paste
    /// on screen with `pasteVerifier` before the next clipboard write: Universal
    /// Clipboard is asynchronous, and two unconfirmed writes race so the device
    /// re-pastes the stale value. A paste that is not seen — or cannot be read
    /// back, like emoji — fails the call instead of passing silently.
    func typeText(_ text: String) -> TypeResult {
        if let keyboardError = prepareKeyboardInput(tag: "typeText") {
            return TypeResult(success: false, error: keyboardError)
        }

        DebugLog.log("typeText", "typing \(text.count) char(s)")
        ensureTargetFrontmost()

        let segments = buildTypeSegments(text)
        let saved = pasteboard.string()
        let pastes = segments.contains { $0.method == .paste }

        let entry = VerifiedTextEntry(
            typeKeys: { [self] run in typeViaCGEvent(run) },
            paste: { [self] run in pasteRun(run) },
            readScreen: { [self] in screenLines() },
            sleep: { usleep($0) },
            verifyTimeoutUs: EnvConfig.pasteVerifyTimeoutUs,
            verifyPollUs: EnvConfig.pasteVerifyPollUs,
            windowChars: EnvConfig.pasteVerifyWindowChars
        )
        let result = entry.enter(segments)

        // Restored once, after every paste is confirmed or abandoned, so the
        // restore is never a clipboard write racing a paste still in flight.
        // Only the plain-text flavor survives — the restore is a courtesy.
        if pastes, let saved {
            _ = pasteboard.replaceContents(with: saved)
        }
        return result
    }

    /// Put one unmappable run on the pasteboard and press Cmd+V.
    ///
    /// CJK, emoji, and most non-Latin characters have no macOS virtual keycode:
    /// they are composed through an input method, which CGEvent cannot drive.
    /// The pasteboard is therefore the only path that enters them at all.
    /// iOS handles Cmd+V as a standard text-editing shortcut in a focused field
    /// — verified on-device, along with Cmd+A and Cmd+C. What Cmd+V pastes is
    /// the *iPhone's* clipboard: the Mac pasteboard written here only gets there
    /// through Universal Clipboard, which is why the caller verifies the result
    /// on screen rather than trusting this keystroke.
    private func pasteRun(_ run: String) -> TypeResult {
        guard pasteboard.replaceContents(with: run) else {
            return TypeResult(
                success: false,
                error: "Failed to place \(run.count) character(s) on the pasteboard")
        }
        usleep(EnvConfig.pasteboardSyncUs)

        DebugLog.log("typeText", "pasting \(run.count) char(s) via Cmd+V")
        let result = pressKey(keyName: "v", modifiers: ["command"])
        guard result.success else {
            return TypeResult(success: false, error: result.error ?? "Cmd+V paste failed")
        }
        return TypeResult(success: true, error: nil)
    }

    /// A segment of text to be typed, with the method to use.
    enum TypeMethod { case keyEvent, paste }
    struct TypeSegment {
        let text: String
        let method: TypeMethod
    }

    /// Split text into segments based on whether each character can be typed
    /// via CGEvent key events on the iPhone's layout or must be pasted. Both
    /// kinds carry the original characters: key events look up their keys on
    /// `keyboardLayout`, and the clipboard carries text verbatim.
    func buildTypeSegments(_ text: String) -> [TypeSegment] {
        var segments: [TypeSegment] = []
        var currentText = ""
        var currentMethod: TypeMethod = .keyEvent

        for char in text {
            let method: TypeMethod = keyboardLayout.keySequence(for: char) != nil ? .keyEvent : .paste

            if method == currentMethod {
                currentText.append(char)
            } else {
                if !currentText.isEmpty {
                    segments.append(TypeSegment(text: currentText, method: currentMethod))
                }
                currentText = String(char)
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
            guard let sequence = keyboardLayout.keySequence(for: char) else {
                return TypeResult(
                    success: false,
                    error: "No key mapping for character '\(char)'"
                )
            }
            guard keyPoster.postKeySequence(sequence) else {
                return TypeResult(
                    success: false,
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
            return TypeResult(success: false, error: keyboardError)
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
                success: false,
                error: "Unknown key '\(keyName)'. Supported: \(AppleScriptKeyMap.supportedKeys.joined(separator: ", ")), or a single character.")
        }

        // Map modifier strings to CGEventFlags
        var flags = CGEventFlags()
        for mod in modifiers {
            guard let flag = CGEventInput.modifierFlag(named: mod.lowercased()) else {
                return TypeResult(
                    success: false,
                    error: "Unknown modifier '\(mod)'. Supported: \(CGEventInput.modifierNames.joined(separator: ", ")).")
            }
            flags.insert(flag)
        }

        let result = keyPoster.postKey(keycode: keycode, flags: flags)
        DebugLog.log("pressKey", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, error: nil)
        }
        return TypeResult(success: false, error: "CGEvent press_key failed")
    }
}
