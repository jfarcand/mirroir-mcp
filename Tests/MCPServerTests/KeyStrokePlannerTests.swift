// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Proves that every key press ends with no modifier held, on the plan and on the CGEvents built from it.
// ABOUTME: Nothing is posted: the plan is a value, and events are created but never sent.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

final class KeyStrokePlannerTests: XCTestCase {

    private static let modifiers: [CGEventFlags] = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// All 16 combinations of the four modifiers.
    private static var modifierSubsets: [CGEventFlags] {
        (0 ..< 1 << modifiers.count).map { bits in
            modifiers.enumerated().reduce(into: CGEventFlags()) { flags, entry in
                if bits & (1 << entry.offset) != 0 { flags.insert(entry.element) }
            }
        }
    }

    /// The modifier flags an event carries, read from the plan.
    private func flags(of event: HeldInputEvent) -> CGEventFlags {
        switch event {
        case .modifierDown(_, let flags), .modifierUp(_, let flags),
             .keyDown(_, let flags, _), .keyUp(_, let flags):
            return flags
        case .buttonDown, .buttonDragged, .buttonUp:
            return CGEventFlags()
        }
    }

    private func assertEndsClean(
        keycode: UInt16, flags: CGEventFlags, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let events = KeyStrokePlanner.events(keycode: keycode, flags: flags)
        XCTAssertTrue(KeyStrokePlanner.heldModifiers(after: events).isEmpty, what, file: file, line: line)
        let last = events.last.map(self.flags(of:)) ?? CGEventFlags()
        for modifier in Self.modifiers {
            XCTAssertFalse(last.contains(modifier), "\(what): the last event still carries a modifier",
                           file: file, line: line)
        }
    }

    func testEveryModifierSubsetEndsWithNothingHeld() {
        XCTAssertEqual(Self.modifierSubsets.count, 16)
        for subset in Self.modifierSubsets {
            let events = KeyStrokePlanner.events(keycode: 0x06, flags: subset)
            assertEndsClean(keycode: 0x06, flags: subset, "flags \(subset.rawValue)")
            let downs = events.filter { if case .modifierDown = $0 { return true } else { return false } }
            let ups = events.filter { if case .modifierUp = $0 { return true } else { return false } }
            XCTAssertEqual(downs.count, ups.count, "flags \(subset.rawValue)")
            XCTAssertEqual(KeyStrokePlanner.isChord(events), !subset.isEmpty)
        }
    }

    func testModifiersComeUpInReverseOrder() {
        let control = HeldKey.unnamed(keycode: 0x3B, modifier: .maskControl)
        let command = HeldKey.unnamed(keycode: 0x37, modifier: .maskCommand)
        let z = HeldKey.unnamed(keycode: 0x06, modifier: nil)
        let both: CGEventFlags = [.maskControl, .maskCommand]

        XCTAssertEqual(KeyStrokePlanner.events(keycode: 0x06, flags: both), [
            .modifierDown(control, flags: .maskControl),
            .modifierDown(command, flags: both),
            .keyDown(z, flags: both, isRepeat: false),
            .keyUp(z, flags: both),
            .modifierUp(command, flags: .maskControl),
            .modifierUp(control, flags: CGEventFlags()),
        ])
    }

    func testAnUnmodifiedKeyIsDownThenUpWithNoFlags() {
        let key = HeldKey.unnamed(keycode: 0x24, modifier: nil)
        XCTAssertEqual(KeyStrokePlanner.events(keycode: 0x24, flags: CGEventFlags()), [
            .keyDown(key, flags: CGEventFlags(), isRepeat: false),
            .keyUp(key, flags: CGEventFlags()),
        ])
    }

    /// Every step of every character a layout can type ends clean: a dead
    /// key's Option is up before its base key goes down.
    func testEveryTypeableCharacterEndsClean() throws {
        let characters = (32 ... 126).compactMap(UnicodeScalar.init).map(Character.init)
            + Array("éèêëàâäùûüîïôöçñÉÀÇ\n\t")
        let csa = try XCTUnwrap(IPhoneKeyboardLayout.named("Canadian-CSA"),
                                "Canadian-CSA layout not available on this system")
        let layouts: [(String, IPhoneKeyboardLayout)] = [("US", .usQWERTY), ("CSA", csa)]
        var checked = 0
        for (name, layout) in layouts {
            for character in characters {
                guard let sequence = layout.keySequence(for: character) else { continue }
                for step in sequence.steps {
                    assertEndsClean(keycode: step.keycode, flags: step.flags, "\(name) '\(character)'")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 190, "the loop must see both layouts")
    }

    func testEveryNamedKeyWithEveryModifierEndsClean() {
        XCTAssertFalse(AppleScriptKeyMap.supportedKeys.isEmpty)
        for name in AppleScriptKeyMap.supportedKeys {
            guard let keycode = AppleScriptKeyMap.keyCode(for: name) else {
                XCTFail("\(name) has no keycode")
                continue
            }
            for subset in Self.modifierSubsets {
                assertEndsClean(keycode: keycode, flags: subset, "\(name) with \(subset.rawValue)")
            }
        }
    }

    /// The CGEvents built from the plan say the same thing as the plan.
    func testLiveEventsFollowThePlan() throws {
        let plan = KeyStrokePlanner.events(keycode: 0x14, flags: .maskCommand)
        let events = plan.compactMap(CGEventHeldInputPoster.makeEvent)
        XCTAssertEqual(events.count, plan.count)
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertTrue(events[1].flags.contains(.maskCommand))
        let last = try XCTUnwrap(events.last)
        for modifier in Self.modifiers {
            XCTAssertFalse(last.flags.contains(modifier))
        }
    }

    /// Once shutdown has started nothing goes down, so nothing can be left down.
    func testAKeyIsRefusedOnceShutdownStarted() {
        let interruption = PlaybackInterruption()
        XCTAssertTrue(interruption.interruptAndWait(timeout: 0))
        XCTAssertFalse(CGEventInput.postKey(keycode: 0x06, flags: .maskCommand,
                                            targetPID: nil, interruption: interruption))
    }
}
