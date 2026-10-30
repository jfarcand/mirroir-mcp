// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for VerifiedTextEntry and PasteNeedle: keyed runs, OCR-confirmed pastes, and honest failures.
// ABOUTME: A scripted screen stands in for OCR so paste arrival, loss, and ordering are deterministic.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class VerifiedTextEntryTests: XCTestCase {

    /// A field on a scripted screen. Keystrokes land in it immediately; a paste
    /// lands only when `pasteArrives` says so, mirroring Universal Clipboard
    /// that either delivers or silently does not. Every effect is logged in
    /// order so tests can check that no clipboard write overtakes a check.
    private final class ScriptedField {
        var field = ""
        var log: [String] = []
        var pasteArrives: (String) -> Bool = { _ in true }
        /// Screen reads a pasted run takes to appear, by run; absent means at once.
        var readsBeforeArrival: [String: Int] = [:]
        var pending: (run: String, reads: Int)?
        var screenReadable = true
        var otherLines: [String] = []

        func entry(timeoutUs: UInt32 = 1_000, pollUs: UInt32 = 250) -> VerifiedTextEntry {
            VerifiedTextEntry(
                typeKeys: { run in
                    self.log.append("keys:\(run)")
                    self.field += run
                    return nil
                },
                paste: { run in
                    self.log.append("paste:\(run)")
                    guard self.pasteArrives(run) else {
                        return TypeResult(success: true, error: nil)
                    }
                    if let reads = self.readsBeforeArrival[run] {
                        self.pending = (run, reads)
                    } else {
                        self.field += run
                    }
                    return TypeResult(success: true, error: nil)
                },
                readScreen: {
                    self.log.append("read")
                    if let pending = self.pending {
                        if pending.reads <= 1 {
                            self.field += pending.run
                            self.pending = nil
                        } else {
                            self.pending = (pending.run, pending.reads - 1)
                        }
                    }
                    return self.screenReadable ? self.otherLines + [self.field] : nil
                },
                sleep: { _ in },
                verifyTimeoutUs: timeoutUs,
                verifyPollUs: pollUs,
                windowChars: TimingConstants.pasteVerifyWindowChars
            )
        }
    }

    private func segments(_ parts: [(String, InputSimulation.TypeMethod)]) -> [InputSimulation.TypeSegment] {
        parts.map { InputSimulation.TypeSegment(text: $0.0, method: $0.1) }
    }

    // MARK: - Entry

    func testAllKeyedTextNeverTouchesTheClipboardOrTheScreen() {
        let screen = ScriptedField()
        let result = screen.entry().enter(segments([("hello world", .keyEvent)]))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(screen.log, ["keys:hello world"])
        XCTAssertEqual(screen.field, "hello world")
    }

    func testPasteThatArrivesIsConfirmedAndTypingContinues() {
        let screen = ScriptedField()
        let result = screen.entry().enter(segments([
            ("a ", .keyEvent), ("<", .paste), (" b", .keyEvent),
        ]))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(screen.field, "a < b")
        XCTAssertEqual(screen.log, ["keys:a ", "read", "paste:<", "read", "keys: b"])
    }

    func testMissingPasteFailsAndNamesWhatWasNotConfirmed() {
        let screen = ScriptedField()
        screen.pasteArrives = { _ in false }
        let result = screen.entry(timeoutUs: 1_000, pollUs: 250).enter(segments([
            ("hi ", .keyEvent), ("\u{4e16}\u{754c}", .paste), (" ok", .keyEvent),
        ]))
        XCTAssertFalse(result.success, "a paste never seen must not pass")
        let error = result.error ?? ""
        XCTAssertTrue(error.contains("not seen on screen"), error)
        XCTAssertTrue(error.contains("Universal Clipboard"), error)
        XCTAssertTrue(error.contains("confirmed 3 character(s) \"hi \""), error)
        XCTAssertTrue(error.contains("not confirmed: \"\u{4e16}\u{754c} ok\""), error)
        XCTAssertFalse(screen.log.contains("keys: ok"), "entry stops at the lost paste")
        XCTAssertEqual(screen.log.filter { $0 == "read" }.count, 1 + 4,
                       "one baseline read, then one read per poll until the bounded wait ends")
    }

    func testStalePasteOfAnotherValueIsNotMistakenForDelivery() {
        // A lagging sync pastes the device's previous clipboard: something
        // arrives, but not the run that was sent.
        let screen = ScriptedField()
        var firstPaste = true
        let entry = VerifiedTextEntry(
            typeKeys: { run in screen.field += run; return nil },
            paste: { run in
                screen.field += firstPaste ? run : "\u{4e16}\u{754c}"
                firstPaste = false
                return TypeResult(success: true, error: nil)
            },
            readScreen: { return [screen.field] },
            sleep: { _ in },
            verifyTimeoutUs: 1_000, verifyPollUs: 250,
            windowChars: TimingConstants.pasteVerifyWindowChars)
        let result = entry.enter(segments([
            ("\u{4e16}\u{754c}", .paste), (" ", .keyEvent), ("\u{3053}\u{3093}", .paste),
        ]))
        XCTAssertFalse(result.success, "the stale value re-pasted must fail the second run")
        XCTAssertTrue(result.error?.contains("not confirmed: \"\u{3053}\u{3093}\"") ?? false,
                      result.error ?? "")
    }

    func testSecondPasteIsWrittenOnlyAfterTheFirstIsSeen() {
        let screen = ScriptedField()
        screen.readsBeforeArrival = ["\u{4e16}": 2]
        let result = screen.entry().enter(segments([
            ("\u{4e16}", .paste), (" ", .keyEvent), ("\u{754c}", .paste),
        ]))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(screen.field, "\u{4e16} \u{754c}")
        XCTAssertEqual(screen.log, [
            "read", "paste:\u{4e16}", "read", "read",
            "keys: ",
            "read", "paste:\u{754c}", "read",
        ], "the second clipboard write waits until the first paste is seen")
    }

    func testEmojiPasteIsUnverifiableAndNeverReportedAsSuccess() {
        let screen = ScriptedField()
        let result = screen.entry().enter(segments([("party ", .keyEvent), ("\u{1f389}", .paste)]))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("OCR cannot read them back") ?? false,
                      result.error ?? "")
        XCTAssertEqual(screen.log, ["keys:party ", "paste:\u{1f389}"],
                       "the emoji is still sent, then reported unverified")
    }

    func testUnreadableScreenFailsBeforePasting() {
        let screen = ScriptedField()
        screen.screenReadable = false
        let result = screen.entry().enter(segments([("\u{4e16}", .paste)]))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Could not read the screen") ?? false,
                      result.error ?? "")
        XCTAssertFalse(screen.log.contains { $0.hasPrefix("paste:") },
                       "no clipboard write when the result could never be confirmed")
    }

    func testRunAlreadyOnScreenElsewhereStillNeedsANewOccurrence() {
        // A label already showing the same text must not confirm the paste.
        let screen = ScriptedField()
        screen.otherLines = ["Search \u{4e16}\u{754c}"]
        screen.pasteArrives = { _ in false }
        let result = screen.entry().enter(segments([("\u{4e16}\u{754c}", .paste)]))
        XCTAssertFalse(result.success)
    }

    // MARK: - PasteNeedle

    func testNeedleIncludesTheTextTypedJustBeforeALoneGlyph() {
        XCTAssertEqual(PasteNeedle.make(entered: "if a ", run: "<", windowChars: 6), "ifa<")
        XCTAssertEqual(PasteNeedle.make(entered: "value is ", run: "<", windowChars: 6), "lueis<")
    }

    func testNeedleKeepsOnlyTheTailOfALongRun() {
        let run = "\u{3053}\u{3093}\u{306b}\u{3061}\u{306f}\u{4e16}\u{754c}"
        XCTAssertEqual(PasteNeedle.make(entered: "", run: run, windowChars: 6),
                       String(run.suffix(6)))
    }

    func testNeedleStopsAtTheLastNewline() {
        XCTAssertEqual(PasteNeedle.make(entered: "first\nx", run: "<", windowChars: 6), "x<")
    }

    func testNeedleIsNilForEmojiOnlyRuns() {
        XCTAssertNil(PasteNeedle.make(entered: "abc", run: "\u{1f389}\u{1f600}", windowChars: 6))
    }

    func testNeedleIsNilWhenARunMixesReadableAndEmoji() {
        // "完了🎉": a stale clipboard holding "完了" would match a needle of the
        // readable part alone, so the run as a whole is unverifiable.
        XCTAssertNil(PasteNeedle.make(entered: "", run: "\u{5b8c}\u{4e86}\u{1f389}", windowChars: 6))
    }

    func testStaleReadablePartOfAMixedRunIsNotReportedAsSuccess() {
        let screen = ScriptedField()
        screen.pasteArrives = { _ in false }
        screen.field = "\u{5b8c}\u{4e86}"
        let result = screen.entry().enter(segments([("\u{5b8c}\u{4e86}\u{1f389}", .paste)]))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("OCR cannot read them back") ?? false,
                      result.error ?? "")
    }

    func testTypedSpotlightQueryAppearsAgain() {
        // Spotlight's recent searches may already list the name; typing must add one.
        let before = ["Recherches récentes", "Horloge"]
        XCTAssertTrue(PasteNeedle.appearedAgain(
            "Horloge", before: before, after: before + ["Horloge — Ouvrir"]))
    }

    func testStaleSpotlightQueryIsNotTakenForTheTypedName() {
        // The previous query swallowed the keystrokes: only "Safari" is shown.
        let stale = ["Safari — Ouvrir", "Meilleur résultat", "Safari"]
        XCTAssertFalse(PasteNeedle.appearedAgain("Horloge", before: stale, after: stale))
        XCTAssertFalse(PasteNeedle.appearedAgain(
            "Horloge", before: ["Horloge"], after: ["Horloge"]),
            "a name already on screen does not prove the keystrokes landed")
    }

    func testOccurrencesIgnoreSpacingAndCase() {
        XCTAssertEqual(PasteNeedle.occurrences(of: "ifa<", in: ["If a <", "if  A<b"]), 2)
        XCTAssertEqual(PasteNeedle.occurrences(of: "ifa<", in: ["nothing"]), 0)
    }
}
