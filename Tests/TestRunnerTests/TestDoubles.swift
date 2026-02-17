// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Stub implementations of protocol abstractions for test runner unit tests.
// ABOUTME: Each stub returns configurable values, enabling tests without real macOS system APIs.

import AppKit
import CoreGraphics
import Foundation
@testable import HelperLib
@testable import iphone_mirroir_mcp

// MARK: - StubBridge

final class StubBridge: MirroringBridging, @unchecked Sendable {
    var windowInfo: WindowInfo? = WindowInfo(
        windowID: 1,
        position: .zero,
        size: CGSize(width: 410, height: 898),
        pid: 1
    )
    var state: MirroringState = .connected
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

    func getState() -> MirroringState {
        state
    }

    func getOrientation() -> DeviceOrientation? {
        orientation
    }

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

// MARK: - StubDescriber

final class StubDescriber: ScreenDescribing, @unchecked Sendable {
    var describeResult: ScreenDescriber.DescribeResult?
    var lastSkipOCR: Bool = false

    func describe(skipOCR: Bool) -> ScreenDescriber.DescribeResult? {
        lastSkipOCR = skipOCR
        return describeResult
    }
}
