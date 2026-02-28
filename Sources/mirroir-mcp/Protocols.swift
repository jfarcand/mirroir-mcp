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

/// Abstracts user input simulation (tap, swipe, type, etc.) via CGEvent.
protocol InputProviding: Sendable {
    func tap(x: Double, y: Double, cursorMode: CursorMode?) -> String?
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode?) -> String?
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode?) -> String?
    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode?) -> String?
    func doubleTap(x: Double, y: Double, cursorMode: CursorMode?) -> String?
    func shake() -> TypeResult
    func typeText(_ text: String) -> TypeResult
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult
    func launchApp(name: String) -> String?
    func openURL(_ url: String) -> String?
}

/// Default nil cursorMode for backward compatibility.
extension InputProviding {
    func tap(x: Double, y: Double) -> String? {
        tap(x: x, y: y, cursorMode: nil)
    }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int) -> String? {
        swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
              durationMs: durationMs, cursorMode: nil)
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int) -> String? {
        drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
             durationMs: durationMs, cursorMode: nil)
    }
    func longPress(x: Double, y: Double, durationMs: Int) -> String? {
        longPress(x: x, y: y, durationMs: durationMs, cursorMode: nil)
    }
    func doubleTap(x: Double, y: Double) -> String? {
        doubleTap(x: x, y: y, cursorMode: nil)
    }
}

/// Abstracts screenshot capture from the mirroring window.
protocol ScreenCapturing: Sendable {
    /// Capture the target window and return raw PNG data.
    func captureData() -> Data?
    /// Capture the target window and return base64-encoded PNG.
    func captureBase64() -> String?
}

/// Abstracts video recording of the mirroring window.
protocol ScreenRecording: Sendable {
    func startRecording(outputPath: String?) -> String?
    func stopRecording() -> (filePath: String?, error: String?)
}

/// Abstracts raw text recognition from a screenshot image.
/// Implementations produce `[RawTextElement]` in window-point space,
/// decoupling the OCR engine from the rest of the describe pipeline.
protocol TextRecognizing: Sendable {
    /// Recognize text elements in a screenshot.
    ///
    /// - Parameters:
    ///   - image: The raw screenshot as a `CGImage`.
    ///   - windowSize: Size of the target window in points (for coordinate scaling).
    ///   - contentBounds: Pixel-space rect from `ContentBoundsDetector`
    ///     (caller computes this before invoking).
    /// - Returns: Text elements with coordinates in window-point space.
    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) -> [RawTextElement]
}

/// Abstracts OCR-based screen element detection.
protocol ScreenDescribing: Sendable {
    func describe(skipOCR: Bool) -> ScreenDescriber.DescribeResult?
}

/// Strategy for customizing autonomous app exploration behavior.
/// Different app types (mobile, social, desktop) can provide tailored
/// element ranking, backtracking, and screen classification logic.
/// All methods are static because strategies are stateless enum namespaces.
protocol ExplorationStrategy: Sendable {
    /// Classify a screen based on its elements and hints.
    static func classifyScreen(elements: [TapPoint], hints: [String]) -> ScreenType

    /// Rank elements for exploration priority.
    /// Returns elements sorted by exploration value (most interesting first).
    static func rankElements(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        visitedElements: Set<String>,
        depth: Int,
        screenType: ScreenType
    ) -> [TapPoint]

    /// Determine how to backtrack from the current screen.
    static func backtrackMethod(currentHints: [String], depth: Int) -> BacktrackAction

    /// Check if an element should be skipped during exploration.
    /// Skip patterns are loaded from the budget (sourced from permissions.json).
    static func shouldSkip(elementText: String, budget: ExplorationBudget) -> Bool

    /// Check if a screen is a terminal node (no further exploration needed).
    static func isTerminal(
        elements: [TapPoint],
        depth: Int,
        budget: ExplorationBudget,
        screenType: ScreenType
    ) -> Bool

    /// Compute a structural fingerprint for screen identity.
    static func extractFingerprint(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon]
    ) -> String
}

/// Classifies OCR elements into UI components for exploration planning.
/// Abstracts the boundary between heuristic and LLM-based component detection.
protocol ComponentClassifying: Sendable {
    /// Classify OCR elements into screen components.
    ///
    /// - Parameters:
    ///   - classified: Pre-classified OCR elements.
    ///   - definitions: Available component definitions.
    ///   - screenHeight: Height of the target window.
    /// - Returns: Detected screen components, or nil if classification failed.
    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]?
}

// MARK: - Conformances

extension MirroringBridge: MenuActionCapable {}

extension InputSimulation: InputProviding {}

extension ScreenCapture: ScreenCapturing {}

extension ScreenRecorder: ScreenRecording {}

extension AppleVisionTextRecognizer: TextRecognizing {}

extension CoreMLElementDetector: TextRecognizing {}

extension CompositeTextRecognizer: TextRecognizing {}

extension ScreenDescriber: ScreenDescribing {}
