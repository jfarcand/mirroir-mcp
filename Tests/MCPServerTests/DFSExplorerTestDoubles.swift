// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared test doubles for DFSExplorer tests: mock describer, mock input, and element factory.
// ABOUTME: These are used across multiple DFSExplorer test files.

import AppKit
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

/// Factory for creating TapPoint arrays with evenly spaced Y coordinates.
func makeExplorerElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
    texts.enumerated().map { (i, text) in
        TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
    }
}

/// Mock screen describer that returns a sequence of pre-defined screens.
/// Each call to describe() returns the next screen in the sequence.
final class MockExplorerDescriber: ScreenDescribing, @unchecked Sendable {
    private var screens: [ScreenDescriber.DescribeResult]
    private var index = 0
    private let lock = NSLock()

    init(screens: [ScreenDescriber.DescribeResult]) {
        self.screens = screens
    }

    func describe() -> ScreenDescriber.DescribeResult? {
        lock.lock()
        defer { lock.unlock() }
        guard index < screens.count else {
            // Return last screen if exhausted (for repeated OCR calls)
            return screens.last
        }
        let result = screens[index]
        index += 1
        return result
    }

    /// Reset the index to replay the sequence.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        index = 0
    }

    /// Number of describe() calls made so far.
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

/// Stub window bridge reporting a fixed connected window. Lets explorer tests
/// exercise the CalibrationScroller (bridge) path without a real target window.
final class StubWindowBridge: WindowBridging, @unchecked Sendable {
    let targetName = "stub"
    private let size: CGSize

    init(size: CGSize = CGSize(width: 410, height: 890)) {
        self.size = size
    }

    func findProcess() -> NSRunningApplication? { nil }
    func getWindowInfo() -> WindowInfo? {
        WindowInfo(windowID: 0, position: .zero, size: size, pid: 0)
    }
    func getState() -> WindowState { .connected }
    func getOrientation() -> DeviceOrientation? { .portrait }
    func activate() {}
}

/// Mock input provider that records actions without performing them.
final class MockExplorerInput: InputProviding, @unchecked Sendable {
    private var tapLog: [(x: Double, y: Double)] = []
    private var keyLog: [(key: String, modifiers: [String])] = []
    private var swipeLog: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    private var launchLog: [String] = []
    private let lock = NSLock()

    func tap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        tapLog.append((x: x, y: y))
        return nil
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        swipeLog.append((fromX: fromX, fromY: fromY, toX: toX, toY: toY))
        return nil
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode?) -> String? { nil }
    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode?) -> String? { nil }
    func doubleTap(x: Double, y: Double, cursorMode: CursorMode?) -> String? { nil }
    func shake() -> TypeResult { TypeResult(success: true, warning: nil, error: nil) }
    func typeText(_ text: String) -> TypeResult { TypeResult(success: true, warning: nil, error: nil) }

    func pressKey(keyName: String, modifiers: [String]) -> TypeResult {
        lock.lock()
        defer { lock.unlock() }
        keyLog.append((key: keyName, modifiers: modifiers))
        return TypeResult(success: true, warning: nil, error: nil)
    }

    func launchApp(name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        launchLog.append(name)
        return nil
    }
    func openURL(_ url: String) -> String? { nil }
    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError> {
        .failure(.rejected("MockExplorerInput does not hold touches"))
    }
    func gesture(_ request: GestureRequest) -> String? { nil }
    func holdKeys(_ request: HeldKeysRequest) -> String? { nil }

    var taps: [(x: Double, y: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return tapLog
    }

    var keys: [(key: String, modifiers: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return keyLog
    }

    var swipes: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return swipeLog
    }

    var launches: [String] {
        lock.lock()
        defer { lock.unlock() }
        return launchLog
    }
}
