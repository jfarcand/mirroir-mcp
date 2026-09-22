// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Session accumulator for the one persistent touch contact (a held left button).
// ABOUTME: Owns begin/move/end/cancel, the inactivity watchdog, and the held-touch refusal for other tools.

import CoreGraphics
import Dispatch
import Foundation

/// The single persistent touch contact that spans MCP calls.
///
/// iPhone Mirroring turns a held left button into one real iOS touch, and every
/// mouse and trackpad on the Mac merges into that one pointer, so there is at
/// most one contact per process. A button left down breaks pointing for the
/// whole Mac, so the session releases it on its own when idle for
/// `inactivityTimeout` (a `DispatchSourceTimer` watchdog), and the server
/// releases it on exit (`HeldInputReleaseOnExit`). While a contact is held,
/// every other pointing operation refuses (`heldRefusal(tool:)`): a click would
/// lift the held button, and iOS drops a gesture posted during a held button.
///
/// The target window can move or resize while the contact is held (the iPhone
/// rotates, Mirroring is resized or restarts), so every `move` is placed
/// against the live frame it is handed. A size change means the iOS
/// coordinate space changed under the finger: the contact is released and the
/// move refused rather than posted at a point that no longer means anything.
///
/// Lifecycle: `begin` → any number of `move` → `end` (or `cancel`, or the
/// watchdog, or process exit). All state is guarded by `lock`, which is never
/// held while a move's frames are posted, so an exit release never waits on one.
final class TouchSession: @unchecked Sendable {

    /// Idle time after which the watchdog lifts a held contact.
    static let defaultInactivityTimeout: TimeInterval = 30

    /// Default duration of a `move`, in milliseconds.
    static let defaultMoveDurationMs = 100

    /// Shortest accepted `move` duration, in milliseconds.
    static let minMoveDurationMs = 1

    /// Longest accepted `move` duration, in milliseconds: far below the
    /// inactivity timeout, and short enough that a move never delays a
    /// client's shutdown. A longer slide is several moves.
    static let maxMoveDurationMs = 5_000

    /// The process-wide session every target's input shares: the Mac has one pointer.
    static let shared = TouchSession(poster: CGEventTouchContact())

    /// Why a move duration is refused, or nil when it is accepted. A nil
    /// duration is a value that is not a representable integer.
    static func moveDurationError(_ durationMs: Int?) -> String? {
        if let durationMs, durationMs >= minMoveDurationMs, durationMs <= maxMoveDurationMs {
            return nil
        }
        let got = durationMs.map(String.init) ?? "a value that is not an integer"
        return "touch move duration_ms must be between \(minMoveDurationMs) and "
            + "\(maxMoveDurationMs) (got \(got)). Split a longer slide into several moves."
    }

    /// Whether `live` has the size of `held`: the same iOS coordinate space,
    /// possibly at a different screen origin.
    static func sameSize(_ live: WindowInfo, _ held: WindowInfo) -> Bool {
        let tolerance = WindowListHelper.geometryMatchTolerance
        return abs(live.size.width - held.size.width) < tolerance
            && abs(live.size.height - held.size.height) < tolerance
    }

    /// A held contact.
    private struct Contact {
        /// Current point, window-relative.
        var windowPoint: CGPoint
        /// The latest known frame of the target window.
        var window: WindowInfo
        /// Screen point of the last event posted for this contact: where the
        /// button actually is, and where it is released.
        var screenPoint: CGPoint
        /// Process the events go to in cursor-free mode; nil for the HID tap.
        let targetPID: pid_t?
        /// Where to put the system pointer back once released (preserving mode).
        let restorePoint: CGPoint?
        /// Whether `engagePointer` hid the cursor for this contact.
        let pointerEngaged: Bool
        /// Monotonic time of the last begin or move.
        var lastActivity: DispatchTime
        /// Distinguishes this contact from a later one, so a move that
        /// posted without the lock never commits onto a newer contact.
        let generation: UInt64
        /// Whether a move is posting its frames right now.
        var moving = false

        static func screenPoint(_ point: CGPoint, in window: WindowInfo) -> CGPoint {
            CGPoint(x: window.position.x + point.x, y: window.position.y + point.y)
        }
    }

    private let poster: any TouchContactPosting
    private let inactivityTimeout: TimeInterval
    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "mirroir.touch.watchdog")
    private var contact: Contact?
    private var watchdog: DispatchSourceTimer?
    private var lastReleaseReason: String?
    private var generation: UInt64 = 0

    init(poster: any TouchContactPosting,
         inactivityTimeout: TimeInterval = TouchSession.defaultInactivityTimeout) {
        self.poster = poster
        self.inactivityTimeout = inactivityTimeout
    }

    /// Whether a contact is held right now.
    var isHeld: Bool {
        lock.withLock { contact != nil }
    }

    /// The held contact's window-relative point and the latest known window
    /// frame it is placed against, or nil when idle.
    var heldPosition: (windowPoint: CGPoint, window: WindowInfo)? {
        lock.withLock { contact.map { ($0.windowPoint, $0.window) } }
    }

    /// The error a pointing operation named `tool` returns while a contact is
    /// held, or nil when it may proceed.
    func heldRefusal(tool: String) -> String? {
        guard let point = lock.withLock({ contact?.windowPoint }) else { return nil }
        return "A touch is held at (\(Int(point.x)), \(Int(point.y))), so \(tool) is refused: "
            + "a click would lift it. Finish it with touch(action:\"end\") or release it "
            + "with touch(action:\"cancel\") first."
    }

    /// Press at `windowPoint` of `window` and keep the contact held.
    func begin(at windowPoint: CGPoint, window: WindowInfo, targetPID: pid_t?,
               restorePoint: CGPoint?) -> Result<TouchOutcome, TouchSessionError> {
        lock.lock()
        defer { lock.unlock() }
        if let held = contact {
            return .failure(.alreadyHeld(at: held.windowPoint))
        }
        let engaged = poster.engagePointer(targetPID: targetPID)
        let screenPoint = Contact.screenPoint(windowPoint, in: window)
        guard poster.press(at: screenPoint, targetPID: targetPID) else {
            poster.disengagePointer(engaged)
            return .failure(.eventPostFailed(action: "begin"))
        }
        generation += 1
        contact = Contact(windowPoint: windowPoint, window: window, screenPoint: screenPoint,
                          targetPID: targetPID, restorePoint: restorePoint,
                          pointerEngaged: engaged, lastActivity: .now(), generation: generation)
        lastReleaseReason = nil
        armWatchdogLocked(after: inactivityTimeout)
        DebugLog.log("touch", "began at window=(\(Int(windowPoint.x)),\(Int(windowPoint.y)))")
        return .success(.began(at: windowPoint))
    }

    /// Move the held contact to `windowPoint` of `liveWindow`, the target
    /// window's frame read just now, over `durationMs`.
    ///
    /// A moved origin is followed. A changed size (rotation, resize) or a
    /// missing window releases the contact and refuses the move. The frames
    /// are posted without holding `lock`; a release that lands meanwhile
    /// (exit, watchdog, cancel) wins, and the move then reports the contact
    /// as no longer held.
    func move(to windowPoint: CGPoint, durationMs: Int,
              liveWindow: WindowInfo?) -> Result<TouchOutcome, TouchSessionError> {
        if let durationError = Self.moveDurationError(durationMs) {
            return .failure(.rejected(durationError))
        }
        lock.lock()
        guard var held = contact else {
            defer { lock.unlock() }
            return .failure(.notHeld(lastRelease: lastReleaseReason))
        }
        guard !held.moving else {
            lock.unlock()
            return .failure(.rejected("A touch move is already in progress."))
        }
        guard let liveWindow, Self.sameSize(liveWindow, held.window) else {
            defer { lock.unlock() }
            let change = TouchWindowChange(held: held.window, live: liveWindow)
            releaseLocked(reason: change.description)
            return .failure(.windowChanged(change))
        }
        let start = held.screenPoint
        let target = Contact.screenPoint(windowPoint, in: liveWindow)
        held.window = liveWindow
        held.moving = true
        held.lastActivity = .now()
        contact = held
        lock.unlock()

        let moved = poster.move(from: start, to: target, durationMs: durationMs,
                                targetPID: held.targetPID)

        lock.lock()
        defer { lock.unlock() }
        guard var current = contact, current.generation == held.generation else {
            return .failure(.notHeld(lastRelease: lastReleaseReason))
        }
        current.moving = false
        current.lastActivity = .now()
        current.screenPoint = target
        guard moved else {
            contact = current
            return .failure(.eventPostFailed(action: "move"))
        }
        current.windowPoint = windowPoint
        contact = current
        armWatchdogLocked(after: inactivityTimeout)
        return .success(.moved(to: windowPoint))
    }

    /// Lift the held contact where it is.
    func end() -> Result<TouchOutcome, TouchSessionError> {
        lock.lock()
        defer { lock.unlock() }
        guard let held = contact else {
            return .failure(.notHeld(lastRelease: lastReleaseReason))
        }
        guard releaseLocked(reason: nil) else {
            return .failure(.eventPostFailed(action: "end"))
        }
        return .success(.ended(at: held.windowPoint))
    }

    /// Release the left button unconditionally. With a contact held, it is
    /// lifted where it is; with none, a button-up is still posted at the
    /// pointer so a button stuck by anything else gets released too.
    func cancel() -> Result<TouchOutcome, TouchSessionError> {
        lock.lock()
        defer { lock.unlock() }
        if let held = contact {
            guard releaseLocked(reason: nil) else {
                return .failure(.eventPostFailed(action: "cancel"))
            }
            return .success(.cancelled(releasedAt: held.windowPoint))
        }
        guard poster.release(at: poster.pointerLocation(), targetPID: nil) else {
            return .failure(.eventPostFailed(action: "cancel"))
        }
        return .success(.cancelled(releasedAt: nil))
    }

    /// Lift a held contact on behalf of the server itself (exit, signal).
    /// Returns whether a contact was held.
    @discardableResult
    func releaseIfHeld(reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard contact != nil else { return false }
        DebugLog.persist("touch", "releasing held touch: \(reason)")
        releaseLocked(reason: reason)
        return true
    }

    // MARK: - Private

    /// Post the button-up for the held contact and return to idle: the
    /// watchdog stops and the pointer is restored whether or not the post
    /// succeeded. Returns whether the button-up was posted.
    @discardableResult
    private func releaseLocked(reason: String?) -> Bool {
        guard let held = contact else { return true }
        let released = poster.release(at: held.screenPoint, targetPID: held.targetPID)
        poster.disengagePointer(held.pointerEngaged)
        if let restorePoint = held.restorePoint {
            poster.warpPointer(to: restorePoint)
        }
        contact = nil
        lastReleaseReason = reason
        watchdog?.cancel()
        watchdog = nil
        DebugLog.log("touch", "released (\(reason ?? "caller")) posted=\(released)")
        return released
    }

    /// Fire the watchdog `interval` seconds from now, creating it on first use.
    private func armWatchdogLocked(after interval: TimeInterval) {
        if watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            timer.setEventHandler { [weak self] in self?.watchdogFired() }
            timer.schedule(deadline: .now() + interval)
            timer.resume()
            watchdog = timer
            return
        }
        watchdog?.schedule(deadline: .now() + interval)
    }

    /// Lift the contact when it has been idle for the full timeout; otherwise
    /// re-arm for the idle time that remains.
    private func watchdogFired() {
        lock.lock()
        defer { lock.unlock() }
        guard let held = contact else { return }
        let idleNs = DispatchTime.now().uptimeNanoseconds - held.lastActivity.uptimeNanoseconds
        let idle = TimeInterval(idleNs) / TimeInterval(NSEC_PER_SEC)
        guard idle >= inactivityTimeout else {
            armWatchdogLocked(after: inactivityTimeout - idle)
            return
        }
        let reason = "watchdog lifted it after \(Int(inactivityTimeout))s without a touch call"
        DebugLog.persist("touch", reason)
        releaseLocked(reason: reason)
    }
}
