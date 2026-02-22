// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Stub implementations of protocol abstractions for test runner unit tests.
// ABOUTME: Each stub returns configurable values, enabling tests without real macOS system APIs.

import AppKit
import CoreGraphics
import Foundation
@testable import HelperLib
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
    var menuActionCalls: [(menu: String, item: String)] = []

    func findProcess() -> NSRunningApplication? {
        processRunning ? NSRunningApplication.current : nil
    }

    func getWindowInfo() -> WindowInfo? {
        windowInfo
    }

    func getState() -> WindowState {
        state
    }

    func getOrientation() -> DeviceOrientation? {
        orientation
    }

    func activate() {}

    func triggerMenuAction(menu: String, item: String) -> Bool {
        menuActionCalls.append((menu: menu, item: item))
        return menuActionResult
    }

    func pressResume() -> Bool {
        pressResumeResult
    }
}

// MARK: - StubInput

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
    var statusDict: [String: Any]? = [
        "ok": true, "keyboard_ready": true, "pointing_ready": true,
    ]
    var helperAvailable = true

    var tapCalls: [(x: Double, y: Double)] = []
    var swipeCalls: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    var dragCalls: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    var launchAppCalls: [String] = []

    func tap(x: Double, y: Double, cursorMode: CursorMode? = nil) -> String? {
        tapCalls.append((x: x, y: y))
        return tapResult
    }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode? = nil) -> String? {
        swipeCalls.append((fromX: fromX, fromY: fromY, toX: toX, toY: toY))
        return swipeResult
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode? = nil) -> String? {
        dragCalls.append((fromX: fromX, fromY: fromY, toX: toX, toY: toY))
        return dragResult
    }
    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode? = nil) -> String? { longPressResult }
    func doubleTap(x: Double, y: Double, cursorMode: CursorMode? = nil) -> String? { doubleTapResult }
    func shake() -> TypeResult { shakeResult }
    func typeText(_ text: String) -> TypeResult { typeTextResult }
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult { pressKeyResult }
    func launchApp(name: String) -> String? {
        launchAppCalls.append(name)
        return launchAppResult
    }
    func openURL(_ url: String) -> String? { openURLResult }
    func helperStatus() -> [String: Any]? { statusDict }
    var isHelperAvailable: Bool { helperAvailable }
}

// MARK: - StubCapture

final class StubCapture: ScreenCapturing, @unchecked Sendable {
    var captureResult: String?

    func captureData() -> Data? {
        guard let captureResult else { return nil }
        return Data(base64Encoded: captureResult)
    }

    func captureBase64() -> String? {
        captureResult
    }
}

// MARK: - StubAIProvider

final class StubAIProvider: AIAgentProviding, @unchecked Sendable {
    var diagnosisResult: AIDiagnosis?
    var lastPayload: DiagnosticPayload?

    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis? {
        lastPayload = payload
        return diagnosisResult
    }
}

// MARK: - StubDescriber

final class StubDescriber: ScreenDescribing, @unchecked Sendable {
    var describeResult: ScreenDescriber.DescribeResult?
    /// Sequential results returned one per call. When exhausted, repeats the last one.
    var describeResults: [ScreenDescriber.DescribeResult?] = []
    private var callCount = 0
    var lastSkipOCR: Bool = false

    func describe(skipOCR: Bool) -> ScreenDescriber.DescribeResult? {
        lastSkipOCR = skipOCR
        if !describeResults.isEmpty {
            let result = describeResults[min(callCount, describeResults.count - 1)]
            callCount += 1
            return result
        }
        return describeResult
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
