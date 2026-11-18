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
// ABOUTME: Keyboard input, shake, and app-level operations for InputSimulation.
// ABOUTME: Split from InputSimulation.swift to stay under the 500-line limit.

import AppKit
import Carbon
import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Trigger a shake gesture on the mirrored iPhone.
    /// Sends Ctrl+Cmd+Z through the key poster, which triggers shake-to-undo in iOS apps.
    func shake() -> TypeResult {
        let prep = prepareWindowKeyboardInput(tag: "shake")
        if let keyboardError = prep.error {
            return TypeResult(success: false, error: keyboardError)
        }

        DebugLog.log("shake", "sending shake gesture via CGEvent")

        let result = keyPoster.postKey(
            keycode: CGEventInput.shakeKeycode, flags: CGEventInput.shakeFlags,
            targetPID: prep.targetPID)
        DebugLog.log("shake", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, error: nil)
        }
        return TypeResult(success: false, error: "CGEvent shake failed")
    }

    /// The app open_url opens, as launch_app opens it.
    static let openURLAppName = "Safari"

    /// Open a URL on the mirrored iPhone by launching Safari and navigating to it.
    /// Opens Safari via Spotlight, selects the address bar with Cmd+L, types the URL,
    /// and presses Return to navigate.
    /// Returns nil on success, or an error message on failure.
    func openURL(_ url: String) -> String? {
        DebugLog.log("openURL", "opening '\(url)'")

        // Step 1: Launch Safari
        if let error = launchApp(name: Self.openURLAppName) {
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
    /// on the iPhone's layout (`keyboardLayouts`, from `keyboardLayout` /
    /// `IPHONE_KEYBOARD_LAYOUT`). Runs that layout cannot type go through the
    /// clipboard one run at a time, and `VerifiedTextEntry` confirms each paste
    /// on screen with `pasteVerifier` before the next clipboard write: Universal
    /// Clipboard is asynchronous, and two unconfirmed writes race so the device
    /// re-pastes the stale value. A paste that is not seen — or cannot be read
    /// back, like emoji — fails the call instead of passing silently.
    func typeText(_ text: String) -> TypeResult {
        let prep = prepareWindowKeyboardInput(tag: "typeText")
        if let keyboardError = prep.error {
            return TypeResult(success: false, error: keyboardError)
        }

        DebugLog.log("typeText", "typing \(text.count) char(s)")

        let size = bridge.getWindowInfo()?.size
        let chosen = size.flatMap(layoutAnswers.answer(for:)).flatMap(keyboardLayouts.layout(named:))
        let disputed = keyboardLayouts.disputed(in: text)
        let result: TypeResult
        if let chosen {
            result = enter(buildTypeSegments(text, chosen: chosen.layout), targetPID: prep.targetPID,
                           chosen: chosen.layout,
                           misreadings: keyboardLayouts.misreadings(of: text, chosen: chosen.layout))
        } else if !disputed.isEmpty {
            // One paste for the whole text: a paste per disputed character
            // costs a clipboard round trip each, and a lone glyph is the
            // hardest thing for OCR to confirm.
            result = enter([TypeSegment(text: text, method: .paste)], targetPID: prep.targetPID, chosen: nil)
        } else {
            result = enter(buildTypeSegments(text), targetPID: prep.targetPID, chosen: nil)
        }
        let report = DisputedKeysReport(text: text, disputed: disputed, chosen: chosen?.name,
                                        layouts: keyboardLayouts.names)
        if report.answerFailed(result), let size {
            layoutAnswers.forget(for: size)
            DebugLog.log("typeText", "forgot the \(chosen?.name ?? "") answer: typed text not on screen")
        }
        return report.apply(to: result)
    }

    /// Remember that the connected iPhone's hardware keyboard uses `name`, one
    /// of the configured layouts. Nil when remembered, else why not.
    func rememberKeyboardLayout(_ name: String) -> String? {
        guard let layout = keyboardLayouts.layout(named: name) else {
            return "keyboard_layout '\(name)' is not one of the layouts in settings: "
                + keyboardLayouts.names.joined(separator: ", ") + ". Nothing was typed."
        }
        guard let size = bridge.getWindowInfo()?.size else {
            return "The '\(bridge.targetName)' window is not available, so keyboard_layout "
                + "cannot be remembered for it. Nothing was typed."
        }
        layoutAnswers.remember(layout.name, for: size)
        DebugLog.log("typeText", "remembered \(layout.name) for \(KeyboardLayoutAnswers.key(size))")
        return nil
    }

    /// Paste `text` verbatim through the clipboard into the focused field and
    /// confirm it on screen. No keyboard layout or input method can change
    /// pasted text, which is why a query that typing garbled is pasted.
    func pasteText(_ text: String) -> TypeResult {
        let prep = prepareWindowKeyboardInput(tag: "pasteText")
        if let keyboardError = prep.error {
            return TypeResult(success: false, error: keyboardError)
        }
        DebugLog.log("pasteText", "pasting \(text.count) char(s)")
        return enter([TypeSegment(text: text, method: .paste)], targetPID: prep.targetPID, chosen: nil)
    }

    /// Enter `segments` through `VerifiedTextEntry`, then restore the pasteboard
    /// a paste replaced.
    private func enter(_ segments: [TypeSegment], targetPID: pid_t?,
                       chosen: IPhoneKeyboardLayout?, misreadings: [String] = []) -> TypeResult {
        let saved = pasteboard.string()
        let pastes = segments.contains { $0.method == .paste }

        let entry = VerifiedTextEntry(
            typeKeys: { [self] run in typeViaCGEvent(run, targetPID: targetPID, chosen: chosen) },
            paste: { [self] run in pasteRun(run) },
            readScreen: { [self] in screenLines() },
            sleep: { usleep($0) },
            verifyTimeoutUs: EnvConfig.pasteVerifyTimeoutUs,
            verifyPollUs: EnvConfig.pasteVerifyPollUs,
            windowChars: EnvConfig.pasteVerifyWindowChars
        )
        let result = entry.enter(segments, misreadings: misreadings)

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
    /// kinds carry the original characters: key events look up their keys in
    /// `keyboardLayouts` (on `chosen` when the phone's layout is known), and
    /// the clipboard carries text verbatim.
    func buildTypeSegments(_ text: String, chosen: IPhoneKeyboardLayout? = nil) -> [TypeSegment] {
        var segments: [TypeSegment] = []
        var currentText = ""
        var currentMethod: TypeMethod = .keyEvent

        for char in text {
            let method: TypeMethod =
                keyboardLayouts.keySequence(for: char, chosen: chosen) != nil ? .keyEvent : .paste

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
    private func typeViaCGEvent(_ text: String, targetPID: pid_t?,
                                chosen: IPhoneKeyboardLayout?) -> TypeResult? {
        for char in text {
            guard let sequence = keyboardLayouts.keySequence(for: char, chosen: chosen) else {
                return TypeResult(
                    success: false,
                    error: "No key mapping for character '\(char)'"
                )
            }
            guard keyPoster.postKeySequence(sequence, targetPID: targetPID) else {
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
        let prep = prepareWindowKeyboardInput(tag: "pressKey")
        if let keyboardError = prep.error {
            return TypeResult(success: false, error: keyboardError)
        }

        let modStr = modifiers.isEmpty ? "" : " modifiers=\(modifiers.joined(separator: "+"))"
        DebugLog.log("pressKey", "key=\(keyName)\(modStr)")

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

        let result = keyPoster.postKey(keycode: keycode, flags: flags, targetPID: prep.targetPID)
        DebugLog.log("pressKey", "CGEvent=\(result ? "OK" : "FAILED")")
        if result {
            return TypeResult(success: true, error: nil)
        }
        return TypeResult(success: false, error: "CGEvent press_key failed")
    }
}
