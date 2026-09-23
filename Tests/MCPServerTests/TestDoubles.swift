// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Stub implementations of protocol abstractions for MCP server unit tests.
// ABOUTME: Each stub returns configurable values, enabling tests without real macOS system APIs.

import AppKit
import CoreGraphics
import Foundation
import HelperLib
@testable import mirroir_mcp

// MARK: - StubBridge

final class StubBridge: MenuActionCapable, @unchecked Sendable {
    var targetName: String = "iphone"
    var windowInfo: WindowInfo? = WindowInfo(
        windowID: 1,
        position: .zero,
        size: CGSize(width: 410, height: 898),
        pid: 1
    )
    var state: WindowState = .connected
    var orientation: DeviceOrientation? = .portrait
    var menuActionResult = true
    var pressResumeResult = true
    var processRunning = true
    /// When true, a `pressResume()` call flips `state` to `.connected` (simulates
    /// the plain resume overlay being dismissed by AX-press).
    var connectOnResume = false
    /// Screen point returned for the paused-overlay dismiss button (nil = none).
    var pausedButtonPoint: CGPoint?
    /// Whether the target reports owning the frontmost window.
    var frontmost = true
    /// Records menu action calls for verification.
    var menuActionCalls: [(menu: String, item: String)] = []

    func findProcess() -> NSRunningApplication? {
        processRunning ? NSRunningApplication.current : nil
    }

    func getWindowInfo() -> WindowInfo? {
        windowInfo
    }

    /// When set, `getState()` reports `.connected` from this instant on
    /// (simulates an overlay that fades a moment after the session resumed).
    var connectsAt: Date?

    func getState() -> WindowState {
        if let connectsAt, Date() >= connectsAt { state = .connected }
        return state
    }

    func getOrientation() -> DeviceOrientation? {
        orientation
    }

    func activate() {}

    func isFrontmost() -> Bool {
        frontmost
    }

    func triggerMenuAction(menu: String, item: String) -> Bool {
        menuActionCalls.append((menu: menu, item: item))
        return menuActionResult
    }

    /// Successive `pressResume()` results; when empty, `pressResumeResult` answers.
    var pressResumeResults: [Bool] = []

    func pressResume() -> Bool {
        if connectOnResume { state = .connected }
        if !pressResumeResults.isEmpty { return pressResumeResults.removeFirst() }
        return pressResumeResult
    }

    func pausedDismissButtonPoint() -> CGPoint? {
        pausedButtonPoint
    }
}

// MARK: - StubInput

/// Recorded arguments from a single swipe() call.
struct SwipeCall {
    let fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int
}

final class StubInput: InputProviding, @unchecked Sendable {
    var tapResult: String?
    var swipeResult: String?
    var dragResult: String?
    var longPressResult: String?
    var doubleTapResult: String?
    var shakeResult = TypeResult(success: true, warning: nil, error: nil)
    var typeTextResult = TypeResult(success: true, warning: nil, error: nil)
    var pressKeyResult = TypeResult(success: true, warning: nil, error: nil)
    var launchAppResult: String?
    var openURLResult: String?

    /// Records every swipe() invocation for coordinate verification.
    var swipeCalls: [SwipeCall] = []
    /// Records every tap() invocation for verification.
    var tapCalls: [(x: Double, y: Double)] = []
    /// Records every typeText() invocation.
    var typeCalls: [String] = []
    /// Records every launchApp() invocation.
    var launchAppCalls: [String] = []

    func tap(x: Double, y: Double, cursorMode: CursorMode? = nil) -> String? {
        tapCalls.append((x: x, y: y))
        return tapResult
    }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode? = nil) -> String? {
        swipeCalls.append(SwipeCall(fromX: fromX, fromY: fromY,
                                    toX: toX, toY: toY, durationMs: durationMs))
        return swipeResult
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode? = nil) -> String? { dragResult }
    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode? = nil) -> String? { longPressResult }
    func doubleTap(x: Double, y: Double, cursorMode: CursorMode? = nil) -> String? { doubleTapResult }
    func shake() -> TypeResult { shakeResult }
    func typeText(_ text: String) -> TypeResult {
        typeCalls.append(text)
        return typeTextResult
    }
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult { pressKeyResult }
    func launchApp(name: String) -> String? {
        launchAppCalls.append(name)
        return launchAppResult
    }
    func openURL(_ url: String) -> String? { openURLResult }

    /// Result returned by touch(); nil answers with the outcome the command implies.
    var touchResult: Result<TouchOutcome, TouchSessionError>?
    /// Records every touch() invocation.
    var touchCalls: [TouchCommand] = []

    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError> {
        touchCalls.append(command)
        if let touchResult { return touchResult }
        switch command {
        case .begin(let x, let y): return .success(.began(at: CGPoint(x: x, y: y)))
        case .move(let x, let y, _): return .success(.moved(to: CGPoint(x: x, y: y)))
        case .end: return .success(.ended(at: .zero))
        case .cancel: return .success(.cancelled(releasedAt: nil))
        }
    }

    /// Result returned by gesture().
    var gestureResult: String?
    /// Records every gesture() invocation.
    var gestureCalls: [GestureRequest] = []

    func gesture(_ request: GestureRequest) -> String? {
        gestureCalls.append(request)
        return gestureResult
    }

    /// Result returned by holdKeys().
    var holdKeysResult: String?
    /// Records every holdKeys() invocation.
    var holdKeysCalls: [HeldKeysRequest] = []

    func holdKeys(_ request: HeldKeysRequest) -> String? {
        holdKeysCalls.append(request)
        return holdKeysResult
    }
}

// MARK: - StubCapture

final class StubCapture: ScreenCapturing, @unchecked Sendable {
    var captureResult: String?
    var windowInfo: WindowInfo = WindowInfo(
        windowID: 1, position: .zero, size: CGSize(width: 410, height: 898), pid: 1
    )

    func captureWithInfo() -> CaptureResult? {
        guard let data = captureData() else { return nil }
        return CaptureResult(data: data, info: windowInfo)
    }

    func captureData() -> Data? {
        guard let captureResult else { return nil }
        return Data(base64Encoded: captureResult)
    }

    func captureBase64() -> String? {
        captureResult
    }
}

// MARK: - StubRecorder

final class StubRecorder: ScreenRecording, @unchecked Sendable {
    var startResult: String?
    var stopResult: (filePath: String?, error: String?) = ("/tmp/test.mov", nil)

    func startRecording(outputPath: String?) -> String? {
        startResult
    }

    func stopRecording() -> (filePath: String?, error: String?) {
        stopResult
    }
}

// MARK: - StubTextRecognizer

/// Stub for TextRecognizing that returns configurable elements without
/// running real Vision OCR, enabling deterministic unit tests.
///
/// Set `failure` to make it behave like an engine that broke rather than a
/// screen that held no text — the distinction issue #36 turned on.
final class StubTextRecognizer: TextRecognizing, @unchecked Sendable {
    var elements: [RawTextElement] = []
    var failure: (any Error)?

    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) throws -> [RawTextElement] {
        if let failure { throw failure }
        return elements
    }
}

// MARK: - StubDescriber

final class StubDescriber: ScreenDescribing, @unchecked Sendable {
    var describeResult: ScreenDescriber.DescribeResult?

    /// Sequential results returned by successive describe() calls.
    /// When set, each call returns the next result (falling back to the last).
    var describeResults: [ScreenDescriber.DescribeResult?] = []
    private var describeIndex = 0

    func describe() -> ScreenDescriber.DescribeResult? {
        if !describeResults.isEmpty {
            let result = describeResults[min(describeIndex, describeResults.count - 1)]
            describeIndex += 1
            return result
        }
        return describeResult
    }
}

// MARK: - TargetRegistry helpers for tests

/// Creates a TargetRegistry with a single "iphone" target from the given stubs.
func makeTestRegistry(
    bridge: StubBridge,
    input: StubInput,
    capture: StubCapture = StubCapture(),
    recorder: StubRecorder = StubRecorder(),
    describer: StubDescriber = StubDescriber()
) -> TargetRegistry {
    let ctx = TargetContext(
        name: "iphone",
        targetType: "iphone-mirroring",
        bundleID: nil,
        bridge: bridge,
        input: input,
        capture: capture,
        describer: describer,
        recorder: recorder,
        capabilities: [.menuActions, .spotlight, .home, .appSwitcher]
    )
    return TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone")
}
