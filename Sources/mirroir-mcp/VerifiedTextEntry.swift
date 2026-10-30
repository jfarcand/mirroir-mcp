// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Enters segmented text — keystrokes for keyed runs, one clipboard paste per unmappable run.
// ABOUTME: Each paste is confirmed on screen by OCR before the next clipboard write, or entry stops with an error.

import Foundation
import HelperLib

/// Enters text segment by segment and refuses to report a paste it did not see.
///
/// Keyed runs are posted as keystrokes, which are self-contained. Unmappable
/// runs (emoji, CJK, characters the iPhone's layout lacks) go through Universal
/// Clipboard, which can deliver nothing — Handoff off — or the device's
/// previous clipboard value when the sync lags. Two clipboard writes in one call
/// race each other through that asynchronous sync, so a second paste is only
/// safe once the first is known to have landed. Every paste is therefore read
/// back from the screen: the entry waits until the pasted run's tail (with the
/// characters typed just before it) appears one more time than it did before
/// the paste. A paste not seen within `verifyTimeoutUs` — or one that has no
/// OCR-readable character to look for — stops the entry with an error naming
/// what was and was not confirmed.
struct VerifiedTextEntry {
    /// Posts keystrokes for a keyed run. Nil on success, the failure otherwise.
    let typeKeys: (String) -> TypeResult?
    /// Writes a run to the pasteboard, waits for the sync, and presses Cmd+V.
    let paste: (String) -> TypeResult
    /// Reads every text line on screen once. Nil when the screen cannot be read.
    let readScreen: () -> [String]?
    /// Sleeps for the given number of microseconds between screen reads.
    let sleep: (UInt32) -> Void
    /// Longest wait for a paste to appear on screen (microseconds).
    let verifyTimeoutUs: UInt32
    /// Gap between screen reads while waiting for a paste (microseconds).
    let verifyPollUs: UInt32
    /// Trailing characters of entered text that must appear on screen.
    let windowChars: Int

    /// Enter every segment in order. Success only when every keyed run was
    /// posted and every pasted run was seen on screen.
    func enter(_ segments: [InputSimulation.TypeSegment]) -> TypeResult {
        var entered = ""
        for (index, segment) in segments.enumerated() {
            let remaining = segments[index...].map(\.text).joined()
            switch segment.method {
            case .keyEvent:
                if let failure = typeKeys(segment.text) {
                    return Self.failure(failure.error ?? "Keystroke failed",
                                        entered: entered, remaining: remaining)
                }
                entered += segment.text
            case .paste:
                if let error = pasteAndVerify(segment.text, after: entered) {
                    return Self.failure(error, entered: entered, remaining: remaining)
                }
                entered += segment.text
            }
        }
        return TypeResult(success: true, error: nil)
    }

    /// Paste one run and wait until it is on screen. Nil when seen, the reason otherwise.
    private func pasteAndVerify(_ run: String, after entered: String) -> String? {
        guard let needle = PasteNeedle.make(entered: entered, run: run,
                                            windowChars: windowChars) else {
            let result = paste(run)
            guard result.success else { return result.error ?? "Cmd+V paste failed" }
            return "\(run.count) character(s) were pasted through the clipboard but " +
                "OCR cannot read them back (the run holds emoji or symbols with no " +
                "readable text), " +
                "so their delivery is unverified and not reported as success. " +
                "Check the screen before relying on them."
        }
        guard let before = readScreen() else {
            return "Could not read the screen before pasting, so the paste could not be verified"
        }
        let baseline = PasteNeedle.occurrences(of: needle, in: before)

        let result = paste(run)
        guard result.success else { return result.error ?? "Cmd+V paste failed" }

        let attempts = max(1, Int(verifyTimeoutUs / max(1, verifyPollUs)))
        for _ in 0 ..< attempts {
            sleep(verifyPollUs)
            if let lines = readScreen(),
               PasteNeedle.occurrences(of: needle, in: lines) > baseline {
                return nil
            }
        }
        let seconds = Double(verifyTimeoutUs) / 1_000_000
        return "\(run.count) character(s) pasted with Cmd+V were not seen on screen " +
            "within \(seconds)s. The clipboard path needs Universal Clipboard (Handoff " +
            "on the Mac and the iPhone, Bluetooth and Wi-Fi on, same iCloud account); " +
            "a lagging sync pastes the device's previous clipboard instead. Non-Latin " +
            "scripts are only readable when `ocrLanguages` includes them."
    }

    /// A failure naming what was confirmed delivered and what was not.
    private static func failure(_ reason: String, entered: String,
                                remaining: String) -> TypeResult {
        TypeResult(
            success: false,
            error: "\(reason) — confirmed \(entered.count) character(s) \"\(entered)\"; " +
                "not confirmed: \"\(remaining)\".")
    }
}

/// The on-screen evidence a paste must produce, and how to count it.
enum PasteNeedle {

    /// The text to look for once `run` is pasted after `entered`: the last
    /// `windowChars` OCR-readable characters of the current line, ending with
    /// the run's own last readable character. Nil when any visible character of
    /// the run is unreadable: a stale clipboard holding only the readable part
    /// would match, so nothing on screen could prove the whole run arrived.
    static func make(entered: String, run: String, windowChars: Int) -> String? {
        let runReadable = readable(run)
        let visible = run.filter { !$0.isWhitespace && !$0.isNewline }
        guard !runReadable.isEmpty, runReadable.count == visible.count else { return nil }
        let currentLine = entered.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let line = readable(currentLine) + runReadable
        return String(line.suffix(max(windowChars, 1)))
    }

    /// Whether `text` appears in `after` more often than in `before`. False when
    /// `text` has no readable character, since nothing on screen could show it.
    static func appearedAgain(_ text: String, before: [String], after: [String]) -> Bool {
        let needle = readable(text)
        guard !needle.isEmpty else { return false }
        return occurrences(of: needle, in: after) > occurrences(of: needle, in: before)
    }

    /// How many times `needle` appears across `lines`, each line normalized
    /// the same way as the needle.
    static func occurrences(of needle: String, in lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + readable(line).components(separatedBy: needle).count - 1
        }
    }

    /// Lowercased text without the characters OCR cannot be trusted to report:
    /// whitespace (recognition inserts and drops spaces), control characters,
    /// and emoji or pictographic symbols (no recognizable glyph).
    static func readable(_ text: String) -> String {
        String(text.lowercased().filter(isReadable))
    }

    private static func isReadable(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return false }
        return !character.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
                || (scalar.properties.isEmoji && scalar.value > latin1Max)
        }
    }

    /// Last Latin-1 code point. Above it, an emoji-capable scalar (😀, ™, ↔) is
    /// a pictograph; within it, `#`, digits, `©` and `®` are ordinary text.
    private static let latin1Max: UInt32 = 0xFF
}
