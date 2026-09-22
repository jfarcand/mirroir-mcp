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
    /// Whether the target owns the frontmost window right now, so keyboard
    /// events posted to the HID tap reach it rather than another Mac app.
    func isFrontmost() -> Bool
}

extension WindowBridging {
    /// Default: the target's process owns the frontmost normal-layer window,
    /// asked of the window server on every call rather than NSWorkspace's
    /// snapshot, which freezes in the server (see `RunningAppLocator`).
    func isFrontmost() -> Bool {
        guard let pid = findProcess()?.processIdentifier else { return false }
        return WindowListHelper.frontmostWindowOwnerPID() == pid
    }
}

/// Extends WindowBridging with menu bar actions available on iPhone Mirroring.
protocol MenuActionCapable: WindowBridging {
    func triggerMenuAction(menu: String, item: String) -> Bool
    func pressResume() -> Bool
    /// Screen-coordinate center of the dismiss button on a Continuity interruption
    /// overlay (e.g. the "iPhone camera is not available from Mac" OK dialog, or
    /// the plain "click to resume" overlay) while the session is paused. A real
    /// mouse click here frees the session even when CGEvent input to the iPhone is
    /// rejected and AX-press is inert. Returns nil when not paused / no button found.
    func pausedDismissButtonPoint() -> CGPoint?
}

extension MenuActionCapable {
    /// Default: no overlay button (non-mirroring bridges have no paused overlay).
    func pausedDismissButtonPoint() -> CGPoint? { nil }
}

/// Backward-compatible alias for code that references the old protocol name.
typealias MirroringBridging = MenuActionCapable

/// Live reads of the iPhone Mirroring process and window from macOS: Launch
/// Services for the process, Accessibility for the main window, the window
/// server for authoritative bounds. Every call answers from current system
/// state — implementations never cache — because the window moves and resizes
/// when the iPhone rotates or Mirroring is resized, and the process gets a new
/// PID when Mirroring restarts.
protocol MirroringSystemProbing: Sendable {
    /// PID of the running app with `bundleID`, or nil when it is not running.
    func processID(bundleID: String) -> pid_t?
    /// Snapshot of the app's AX main window, or nil when it exposes none.
    func mainWindow(pid: pid_t) -> MirroringAXWindow?
    /// The window server's current window list.
    func windowList() -> [WindowListEntry]
    /// Press the resume control of the paused overlay in the main window of
    /// `pid`: a button `MirroringWindowResolver.isResumeControl` accepts,
    /// directly under the hosting view. Returns whether a press succeeded.
    func pressResumeControl(pid: pid_t) -> Bool
    /// Screen centre of a resume or dismiss control anywhere in the main
    /// window of `pid`, or nil when no interruption overlay shows one.
    func dismissControlPoint(pid: pid_t) -> CGPoint?
}

/// A pluggable strategy for clearing a target interruption that blocks input —
/// for ANY target, not just iPhone Mirroring. Examples: a suspended iPhone
/// Mirroring session (Continuity camera dialog / resume overlay), or a modal
/// overlay on a generic window target. Registered plugins are tried in order
/// whenever input is blocked; the first that recognizes the current state and
/// acts wins, then the caller re-checks. Add a handler for a new target or
/// interruption by conforming a type and registering it in `SessionEscapeRegistry`.
///
/// Plugins receive the generic `WindowBridging` and narrow to a capability they
/// need (e.g. `as? MenuActionCapable` for iPhone Mirroring), returning false when
/// the target isn't theirs — so target-specific plugins coexist in one registry.
protocol SessionEscapePlugin: Sendable {
    /// Stable identifier for logging.
    var id: String { get }
    /// Attempt to clear the interruption this plugin handles. Returns true if it
    /// recognized the current state and performed its escape action; false if it
    /// does not apply (wrong target, or its interruption isn't shown). `click`
    /// posts a real mouse click at a screen point (which, on iPhone Mirroring,
    /// frees Continuity dialogs even while CGEvent input to the device is rejected).
    func attemptEscape(bridge: any WindowBridging, click: (CGPoint) -> Void, tag: String) -> Bool
}

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
    /// Drive the single persistent touch contact that spans calls (begin,
    /// move, end, cancel). While it is held, every other pointing operation
    /// refuses. Coordinates are window-relative, like `tap`.
    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError>
    /// Perform a validated two-finger pinch or rotate centred at the request's
    /// window-relative point. Returns nil on success, or an error message.
    func gesture(_ request: GestureRequest) -> String?
    /// Hold the request's keys for its duration, re-posting key downs as
    /// auto-repeat, optionally dragging a mouse button over the same time,
    /// then release everything in reverse order. Returns nil on success, or
    /// an error message.
    func holdKeys(_ request: HeldKeysRequest) -> String?
}

/// Hides the cursor and detaches it from the physical mouse while synthetic
/// pointing input holds a button or runs a gesture, so the user's own mouse
/// movement cannot drag the held contact elsewhere.
protocol PointerEngaging: Sendable {
    /// Engage the pointer for input going to `targetPID` (nil: the HID tap).
    /// Returns whether it did (false in cursor-free mode).
    func engagePointer(targetPID: pid_t?) -> Bool
    /// Undo `engagePointer` when it returned true.
    func disengagePointer(_ engaged: Bool)
}

/// The live pointer engagement through `CGEventInput`, shared by every live
/// CGEvent poster so there is one implementation of it.
protocol CGEventPointerEngaging: PointerEngaging {}

extension CGEventPointerEngaging {
    func engagePointer(targetPID: pid_t?) -> Bool {
        CGEventInput.engageCursor(targetPID: targetPID)
    }

    func disengagePointer(_ engaged: Bool) {
        CGEventInput.disengageCursor(engaged)
    }
}

/// Posts the keyboard and mouse events of one hold_keys call. Mouse points are
/// screen-absolute; `targetPID` routes button events to one process
/// (cursor-free mode) instead of the HID event tap.
protocol HeldInputPosting: PointerEngaging {
    /// Post one key, modifier or button event. Returns false when the event
    /// could not be created.
    func post(_ event: HeldInputEvent, targetPID: pid_t?) -> Bool
    /// Wait between events.
    func pause(microseconds: UInt32)
}

/// Posts the CGEvents of a two-finger trackpad gesture (pinch, rotate) that
/// iPhone Mirroring forwards to iOS as a UIKit two-finger gesture. Points are
/// screen-absolute; `targetPID` routes events to one process (cursor-free
/// mode) instead of the HID event tap.
protocol GestureEventPosting: PointerEngaging {
    /// Post one gesture event at `centre`, stamped with the trackpad `senderID`.
    /// Returns false when the event could not be created.
    func post(_ event: GestureEvent, at centre: CGPoint, senderID: UInt64, targetPID: pid_t?) -> Bool
    /// Wait between gesture frames.
    func pause(microseconds: UInt32)
}

/// Finds the multitouch trackpad whose HID service a gesture event must name
/// as its sender: iPhone Mirroring ignores a gesture event whose sender is not
/// a real multitouch trackpad.
protocol MultitouchSenderResolving: Sendable {
    /// IORegistry entry ID of the Mac's multitouch trackpad (built-in first,
    /// then a Magic Trackpad), or nil when the Mac has none.
    func multitouchSenderID() -> UInt64?
}

/// Posts the CGEvent primitives of one persistent touch contact: a held left
/// button is one real iOS touch, and it stays down across calls until released.
/// All points are screen-absolute. `targetPID` routes events to one process
/// (cursor-free mode) instead of the HID event tap.
protocol TouchContactPosting: PointerEngaging {
    /// Press the left button at `point` (touch down).
    func press(at point: CGPoint, targetPID: pid_t?) -> Bool
    /// Move the held button from `start` to `end` over `durationMs`.
    func move(from start: CGPoint, to end: CGPoint, durationMs: Int, targetPID: pid_t?) -> Bool
    /// Release the left button at `point` (touch up).
    func release(at point: CGPoint, targetPID: pid_t?) -> Bool
    /// Where the system pointer is right now.
    func pointerLocation() -> CGPoint
    /// Put the system pointer back at `point`.
    func warpPointer(to point: CGPoint)
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

/// Bundled capture output: screenshot data + the window info used to capture it.
/// Eliminates redundant getWindowInfo() calls when the caller needs both.
struct CaptureResult: Sendable {
    let data: Data
    let info: WindowInfo
}

/// Abstracts screenshot capture from the mirroring window.
protocol ScreenCapturing: Sendable {
    /// Capture the target window returning screenshot data + window info in one call.
    /// Single source of truth — eliminates duplicate getWindowInfo() calls.
    func captureWithInfo() -> CaptureResult?
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
    /// - Returns: Text elements with coordinates in window-point space. An empty
    ///   array means the image held no text.
    /// - Throws: `TextRecognitionError` when the engine itself failed, which is
    ///   a different answer from "no text" and must reach the caller as one.
    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) throws -> [RawTextElement]
}

/// A text recognition engine failed to produce an answer.
///
/// Distinct from recognizing nothing: a blank screen legitimately yields zero
/// elements, while these cases mean the pipeline is broken and the caller is
/// looking at an absence of information rather than information about absence.
enum TextRecognitionError: Error, CustomStringConvertible {
    /// The Vision request failed, including after retry and CPU fallback.
    case visionRequestFailed(underlying: any Error)
    /// A backend inside a composite failed; the others may have succeeded.
    case backendFailed(name: String, underlying: any Error)

    var description: String {
        switch self {
        case .visionRequestFailed(let underlying):
            return "Vision text recognition failed: \(underlying)"
        case .backendFailed(let name, let underlying):
            return "\(name) failed: \(underlying)"
        }
    }
}

/// Abstracts OCR-based screen element detection.
protocol ScreenDescribing: Sendable {
    func describe() -> ScreenDescriber.DescribeResult?

    /// Describe the full page by scrolling through all viewports.
    /// Delegates to `CalibrationScroller.collectFullPage()` for element collection.
    ///
    /// - Parameters:
    ///   - input: Input provider for scroll gestures.
    ///   - bridge: Window bridge for getting window dimensions.
    ///   - maxScrolls: Maximum number of scroll attempts.
    /// - Returns: The scroll result with all unique elements, or nil if OCR failed.
    func describeFullPage(
        input: any InputProviding,
        bridge: any WindowBridging,
        maxScrolls: Int
    ) -> CalibrationScroller.ScrollResult?
}

extension ScreenDescribing {
    func describeFullPage(
        input: any InputProviding,
        bridge: any WindowBridging,
        maxScrolls: Int = EnvConfig.defaultScrollMaxAttempts
    ) -> CalibrationScroller.ScrollResult? {
        CalibrationScroller.collectFullPage(
            describer: self, input: input,
            bridge: bridge, maxScrolls: maxScrolls
        )
    }
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

extension VisionScreenDescriber: ScreenDescribing {}
