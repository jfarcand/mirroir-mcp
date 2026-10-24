// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that SkillStep.replayValue round-trips through SkillParser.parseStep for every step kind.
// ABOUTME: A compiled step stores replayValue as its label, so a lossy value would replay a different step.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SkillStepReplayValueTests: XCTestCase {

    /// Parse a step back from its type key and replay value.
    private func roundTrip(_ step: SkillStep) -> SkillStep {
        SkillParser.parseStep(key: step.typeKey, rawValue: step.replayValue ?? "")
    }

    private func assertRoundTrips(_ step: SkillStep, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(String(describing: roundTrip(step)), String(describing: step),
                       "replay value \(step.replayValue ?? "nil")", file: file, line: line)
    }

    func testEveryStepKindRoundTrips() {
        let steps: [SkillStep] = [
            .launch(appName: "Settings"),
            .tap(label: "Sign In"),
            .type(text: "hello world"),
            .pressKey(keyName: "return", modifiers: []),
            .pressKey(keyName: "l", modifiers: ["command"]),
            .pressKey(keyName: "z", modifiers: ["command", "shift"]),
            .pressKey(keyName: "+", modifiers: []),
            .swipe(direction: "left"),
            .waitFor(label: "General", timeoutSeconds: nil),
            .waitFor(label: "General", timeoutSeconds: 30),
            .assertVisible(label: "Model Name"),
            .assertNotVisible(label: "Error"),
            .screenshot(label: "about"),
            .home,
            .openURL(url: "https://example.com/a?b=c"),
            .shake,
            .resetApp(appName: "Notes"),
            .setNetwork(mode: "airplane_on"),
            .longPress(label: "Photo", durationMs: nil),
            .longPress(label: "Photo", durationMs: 1500),
            .drag(fromLabel: "Item A", toLabel: "Trash"),
            .drag(fromLabel: "Save, Exit", toLabel: "Trash"),
            .measure(name: "sync", action: .tap(label: "Sync"),
                     until: "Saved, synced", maxSeconds: nil),
            .measure(name: "login", action: .tap(label: "Sign in, Continue"),
                     until: "Home", maxSeconds: 5),
            .measure(name: "wait", action: .waitFor(label: "Ready", timeoutSeconds: 10),
                     until: "Done", maxSeconds: nil),
            .measure(name: "wipe", action: .longPress(label: "Delete, all", durationMs: 800),
                     until: "Deleted", maxSeconds: nil),
            .measure(name: "signin", action: .waitFor(label: "Sign in, now", timeoutSeconds: 10),
                     until: "Home", maxSeconds: nil),
            .measure(name: "m", action: .tap(label: "{Cancel, Done}"), until: "Home", maxSeconds: nil),
            .measure(name: "q", action: .tap(label: "\"x\""), until: "y", maxSeconds: nil),
            .measure(name: "s", action: .tap(label: "'x'"), until: "y", maxSeconds: nil),
            .measure(name: "k", action: .pressKey(keyName: "l", modifiers: ["command"]),
                     until: "Address", maxSeconds: nil),
            .measure(name: "zoom", action: .pressKey(keyName: "+", modifiers: ["command", "shift"]),
                     until: "Zoomed", maxSeconds: nil),
            .pressKey(keyName: "+", modifiers: ["command", "shift"]),
            .switchTarget(.ios(app: "Notes")),
            .switchTarget(.ios(app: nil)),
            .switchTarget(.macos(name: "TextEdit")),
            .measure(name: "login_time", action: .tap(label: "Login"),
                     until: "Dashboard", maxSeconds: 5),
            .measure(name: "measure", action: .home, until: "Home", maxSeconds: nil),
            .measure(name: "undo_time", action: .pressKey(keyName: "z", modifiers: ["command", "shift"]),
                     until: "Redo", maxSeconds: 3),
            .measure(name: "measure",
                     action: .skipped(stepType: "measure", reason: "No action found in measure step"),
                     until: "Done", maxSeconds: nil),
            .type(text: "\""),
            .pressKey(keyName: "'", modifiers: []),
        ]
        for step in steps {
            assertRoundTrips(step)
        }
    }

    func testScrollToKeepsItsLabel() {
        let step = SkillStep.scrollTo(label: "Privacy", direction: "up",
                                      maxScrolls: EnvConfig.defaultScrollMaxAttempts)
        assertRoundTrips(step)
    }

    func testStructuredValuesHoldingAQuoteRoundTrip() {
        assertRoundTrips(.drag(fromLabel: "5\" Disk", toLabel: "Trash"))
        assertRoundTrips(.drag(fromLabel: "Don't Allow", toLabel: "Trash"))
        assertRoundTrips(.waitFor(label: "5\" Disk", timeoutSeconds: 5))
        assertRoundTrips(.measure(name: "t", action: .tap(label: "5\" Disk"),
                                  until: "Done", maxSeconds: nil))
        XCTAssertNil(SkillStep.drag(fromLabel: "a\"b'c", toLabel: "x").replayValue)
        // A trailing backslash would escape the closing quote: no form, not a wrong one.
        XCTAssertNil(SkillStep.drag(fromLabel: "C:\\", toLabel: "Desktop").replayValue)
        assertRoundTrips(.drag(fromLabel: "C:\\Users", toLabel: "Desktop"))
        assertRoundTrips(.switchTarget(.macos(name: "a\", b")))
        assertRoundTrips(.switchTarget(.ios(app: "Don't Panic")))
    }

    func testMirroirRunSingleQuotedValuesAndBareApostrophesSplitCorrectly() {
        XCTAssertEqual(String(describing: SkillParser.parseStep(
            key: "drag", rawValue: "{ from: '5\" Disk', to: \"Trash\" }")),
            String(describing: SkillStep.drag(fromLabel: "5\" Disk", toLabel: "Trash")))
        XCTAssertEqual(String(describing: SkillParser.parseStep(
            key: "drag", rawValue: "{ from: Don't Allow, to: Trash }")),
            String(describing: SkillStep.drag(fromLabel: "Don't Allow", toLabel: "Trash")))
    }

    func testValueWrappedInQuotesKeepsThem() {
        assertRoundTrips(.type(text: "\"quoted\""))
        assertRoundTrips(.tap(label: "'single'"))
    }

    func testPlainValuesStayBareForScreenMatching() {
        XCTAssertEqual(SkillStep.tap(label: "Sign In").replayValue, "Sign In")
        XCTAssertEqual(SkillStep.waitFor(label: "General", timeoutSeconds: nil).replayValue, "General")
        XCTAssertNil(SkillStep.home.replayValue)
    }

    func testThePlusKeyWithInlineModifiers() {
        guard case .pressKey(let key, let modifiers) =
                SkillParser.parseStep(key: "press_key", rawValue: "++command") else {
            return XCTFail("expected a press_key step")
        }
        XCTAssertEqual(key, "+")
        XCTAssertEqual(modifiers, ["command"])
        assertRoundTrips(.pressKey(keyName: "+", modifiers: ["command"]))
    }

    func testPressKeyMadeOfPlusDoesNotCrash() {
        guard case .pressKey(let key, let modifiers) =
                SkillParser.parseStep(key: "press_key", rawValue: "+") else {
            return XCTFail("expected a press_key step")
        }
        XCTAssertEqual(key, "+")
        XCTAssertEqual(modifiers, [])
    }
}
