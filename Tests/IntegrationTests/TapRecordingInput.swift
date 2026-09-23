// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Test-only InputProviding decorator that records tap coordinates while forwarding every call.
// ABOUTME: Lets FakeMirroring end-to-end tests assert on the physical tap sequence.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Test-only decorator over the real `InputSimulation`: records every tap
/// coordinate while forwarding all calls unchanged (not a mock — every gesture
/// still reaches FakeMirroring). No production type exposes the physical tap
/// sequence, which the tab-return tests must assert on.
final class TapRecordingInput: InputProviding, @unchecked Sendable {
    private let base: any InputProviding
    private let lock = NSLock()
    private var tapLog: [CGPoint] = []

    init(wrapping base: any InputProviding) {
        self.base = base
    }

    /// Ordered tap coordinates observed so far.
    var recordedTaps: [CGPoint] {
        lock.lock()
        defer { lock.unlock() }
        return tapLog
    }

    func tap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        lock.lock()
        tapLog.append(CGPoint(x: x, y: y))
        lock.unlock()
        return base.tap(x: x, y: y, cursorMode: cursorMode)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode?) -> String? {
        base.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                   durationMs: durationMs, cursorMode: cursorMode)
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode?) -> String? {
        base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                  durationMs: durationMs, cursorMode: cursorMode)
    }

    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode?) -> String? {
        base.longPress(x: x, y: y, durationMs: durationMs, cursorMode: cursorMode)
    }

    func doubleTap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        base.doubleTap(x: x, y: y, cursorMode: cursorMode)
    }

    func shake() -> TypeResult { base.shake() }
    func typeText(_ text: String) -> TypeResult { base.typeText(text) }
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult {
        base.pressKey(keyName: keyName, modifiers: modifiers)
    }
    func launchApp(name: String) -> String? { base.launchApp(name: name) }
    func openURL(_ url: String) -> String? { base.openURL(url) }
    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError> {
        base.touch(command)
    }
    func gesture(_ request: GestureRequest) -> String? { base.gesture(request) }
    func holdKeys(_ request: HeldKeysRequest) -> String? { base.holdKeys(request) }
}
