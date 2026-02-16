// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Protocol abstractions for system boundaries (mirroring bridge, input, capture, recording, OCR).
// ABOUTME: Enables dependency injection for testing without requiring real macOS system APIs.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Abstracts the iPhone Mirroring app bridge for window discovery and menu actions.
protocol MirroringBridging: Sendable {
    func findProcess() -> NSRunningApplication?
    func getWindowInfo() -> WindowInfo?
    func getState() -> MirroringState
    func getOrientation() -> DeviceOrientation?
    func triggerMenuAction(menu: String, item: String) -> Bool
    func pressResume() -> Bool
}

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

extension MirroringBridge: MirroringBridging {}

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
