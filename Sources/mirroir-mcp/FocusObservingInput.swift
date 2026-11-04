// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decorator over InputProviding that samples the Mac's focus around every action and records the outcome.
// ABOUTME: Forwards each call unchanged; only observes whether driving the target stole focus or raised its window.

import CoreGraphics
import Foundation

/// Wraps an `InputProviding` and judges each action with `FocusProbe`,
/// recording the outcome into `FocusStats`. Behavior is the wrapped
/// provider's, untouched; this type only watches.
final class FocusObservingInput: InputProviding, @unchecked Sendable {
    private let wrapped: InputProviding
    private let bridge: WindowBridging
    private let stats: FocusStats
    private let entries: @Sendable () -> [WindowListEntry]

    /// - Parameters:
    ///   - entries: on-screen window entries in front-to-back order; injectable
    ///     so tests can script the window server.
    init(wrapping input: InputProviding, bridge: WindowBridging,
         stats: FocusStats = .shared,
         entries: @escaping @Sendable () -> [WindowListEntry] = {
             WindowListHelper.windowEntries(onScreenOnly: true)
         }) {
        self.wrapped = input
        self.bridge = bridge
        self.stats = stats
        self.entries = entries
    }

    /// Run `action`, sampling focus before and after it, and record the outcome.
    private func observe<T>(_ kind: FocusActionKind, _ action: () -> T) -> T {
        let pidBefore = bridge.getWindowInfo()?.pid
        let before = pidBefore.map { FocusProbe.sample(entries: entries(), targetPID: $0) }
        let result = action()
        let pid = pidBefore ?? bridge.getWindowInfo()?.pid
        let outcome: FocusInterruption
        if let pid {
            let after = FocusProbe.sample(entries: entries(), targetPID: pid)
            // A target that had no window before the action (a launch) is judged
            // as if it sat nowhere: anything it took is attributable to the action.
            let start = before ?? FocusSample(frontmostPID: nil, targetDepth: nil)
            outcome = FocusProbe.interruption(before: start, after: after, targetPID: pid)
        } else {
            outcome = .unmeasured
        }
        stats.record(outcome, kind: kind)
        DebugLog.log("focus", "\(kind.rawValue): \(outcome)")
        return result
    }

    func tap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        observe(.tap) { wrapped.tap(x: x, y: y, cursorMode: cursorMode) }
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode?) -> String? {
        observe(.swipe) {
            wrapped.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                          durationMs: durationMs, cursorMode: cursorMode)
        }
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode?) -> String? {
        observe(.drag) {
            wrapped.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                         durationMs: durationMs, cursorMode: cursorMode)
        }
    }

    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode?) -> String? {
        observe(.longPress) {
            wrapped.longPress(x: x, y: y, durationMs: durationMs, cursorMode: cursorMode)
        }
    }

    func doubleTap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        observe(.doubleTap) { wrapped.doubleTap(x: x, y: y, cursorMode: cursorMode) }
    }

    func shake() -> TypeResult {
        observe(.shake) { wrapped.shake() }
    }

    func typeText(_ text: String) -> TypeResult {
        observe(.type) { wrapped.typeText(text) }
    }

    func pressKey(keyName: String, modifiers: [String]) -> TypeResult {
        observe(.key) { wrapped.pressKey(keyName: keyName, modifiers: modifiers) }
    }

    func launchApp(name: String) -> String? {
        observe(.launch) { wrapped.launchApp(name: name) }
    }

    func openURL(_ url: String) -> String? {
        observe(.openURL) { wrapped.openURL(url) }
    }

    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError> {
        observe(.touch) { wrapped.touch(command) }
    }

    func gesture(_ request: GestureRequest) -> String? {
        observe(.gesture) { wrapped.gesture(request) }
    }

    func holdKeys(_ request: HeldKeysRequest) -> String? {
        observe(.holdKeys) { wrapped.holdKeys(request) }
    }
}
