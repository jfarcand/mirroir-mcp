// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Protocol abstractions for system boundaries (mirroring bridge, input, capture, recording, OCR).
// ABOUTME: Enables dependency injection for testing without requiring real macOS system APIs.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Abstracts window discovery and state detection for any target window.
protocol WindowBridging: Sendable {
    /// Display name of this target (e.g. "iphone", "android").
    var targetName: String { get }
    func findProcess() -> NSRunningApplication?
    func getWindowInfo() -> WindowInfo?
    func getState() -> WindowState
    func getOrientation() -> DeviceOrientation?
    /// Bring the target window to the front so it receives input.
    func activate()
}

/// Extends WindowBridging with menu bar actions available on iPhone Mirroring.
protocol MenuActionCapable: WindowBridging {
    func triggerMenuAction(menu: String, item: String) -> Bool
    func pressResume() -> Bool
}

/// Backward-compatible alias for code that references the old protocol name.
typealias MirroringBridging = MenuActionCapable

/// Abstracts user input simulation (tap, swipe, type, etc.) via the Karabiner helper.
protocol InputProviding: Sendable {
    func tap(x: Double, y: Double) -> String?
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) -> String?
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) -> String?
    func longPress(x: Double, y: Double, durationMs: Int) -> String?
    func doubleTap(x: Double, y: Double) -> String?
    func shake() -> TypeResult
    func typeText(_ text: String) -> TypeResult
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult
    func launchApp(name: String) -> String?
    func openURL(_ url: String) -> String?
    func helperStatus() -> [String: Any]?
    var isHelperAvailable: Bool { get }
}

/// Abstracts screenshot capture from the mirroring window.
protocol ScreenCapturing: Sendable {
    func captureBase64() -> String?
}

/// Abstracts video recording of the mirroring window.
protocol ScreenRecording: Sendable {
    func startRecording(outputPath: String?) -> String?
    func stopRecording() -> (filePath: String?, error: String?)
}

/// Abstracts OCR-based screen element detection.
protocol ScreenDescribing: Sendable {
    func describe(skipOCR: Bool) -> ScreenDescriber.DescribeResult?
}

// MARK: - Conformances

extension MirroringBridge: MenuActionCapable {}

extension InputSimulation: InputProviding {
    func helperStatus() -> [String: Any]? {
        helperClient.status()
    }

    var isHelperAvailable: Bool {
        helperClient.isAvailable
    }
}

extension ScreenCapture: ScreenCapturing {}

extension ScreenRecorder: ScreenRecording {}

extension ScreenDescriber: ScreenDescribing {}
