// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Stub implementations of protocol abstractions for MCP server unit tests.
// ABOUTME: Each stub returns configurable values, enabling tests without real macOS system APIs.

import AppKit
import CoreGraphics
import Foundation
import HelperLib
@testable import iphone_mirroir_mcp

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
        menuActionResult
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

    func tap(x: Double, y: Double) -> String? { tapResult }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) -> String? { swipeResult }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) -> String? { dragResult }
    func longPress(x: Double, y: Double, durationMs: Int) -> String? { longPressResult }
    func doubleTap(x: Double, y: Double) -> String? { doubleTapResult }
    func shake() -> TypeResult { shakeResult }
    func typeText(_ text: String) -> TypeResult { typeTextResult }
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult { pressKeyResult }
    func launchApp(name: String) -> String? { launchAppResult }
    func openURL(_ url: String) -> String? { openURLResult }
    func helperStatus() -> [String: Any]? { statusDict }
    var isHelperAvailable: Bool { helperAvailable }
}

// MARK: - StubCapture

final class StubCapture: ScreenCapturing, @unchecked Sendable {
    var captureResult: String?

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

// MARK: - StubDescriber

final class StubDescriber: ScreenDescribing, @unchecked Sendable {
    var describeResult: ScreenDescriber.DescribeResult?
    var lastSkipOCR: Bool = false

    func describe(skipOCR: Bool) -> ScreenDescriber.DescribeResult? {
        lastSkipOCR = skipOCR
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
        bridge: bridge,
        input: input,
        capture: capture,
        describer: describer,
        recorder: recorder,
        capabilities: [.menuActions, .spotlight, .home, .appSwitcher]
    )
    return TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone")
}
