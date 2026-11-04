// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Chooses between posting input to the target's window directly and the HID path that brings it to the front.
// ABOUTME: Taps, keystrokes and escape clicks go to the window when a poster can address it; the rest keeps HID.

import CoreGraphics
import Foundation

extension InputSimulation {

    /// The poster that can deliver to `info`'s window directly, or nil when
    /// input to it goes through the HID path: no window poster is configured,
    /// or the window server gave no window ID to address.
    func windowDelivery(for info: WindowInfo) -> (any WindowEventPosting)? {
        guard let windowPoster, info.windowID != 0, info.pid > 0 else { return nil }
        return windowPoster
    }

    /// Keyboard preamble for type_text, press_key and shake. Checks that the
    /// target is connected, then makes its window the key window of its own
    /// app without activating it, and returns the process to post key events
    /// to. A target with no window to address goes through
    /// `prepareKeyboardInput`, which brings it to the front, and its events
    /// go through the HID tap (`targetPID` nil).
    func prepareWindowKeyboardInput(tag: String) -> (targetPID: pid_t?, error: String?) {
        guard windowPoster != nil else { return (nil, prepareKeyboardInput(tag: tag)) }
        if let stateError = ensureConnected(tag: tag) {
            return (nil, stateError)
        }
        // Read after the connection check: freeing a paused session can move the window.
        guard let info = bridge.getWindowInfo(), let poster = windowDelivery(for: info) else {
            return (nil, prepareKeyboardInput(tag: tag))
        }
        guard poster.focusKeys(in: info) else {
            DebugLog.log(tag, "REJECTED: key focus record not posted")
            return (nil, "Could not give '\(bridge.targetName)' keyboard focus. No input was sent.")
        }
        DebugLog.log(tag, "keys to pid \(info.pid), window \(info.windowID); front app untouched")
        return (info.pid, nil)
    }

    /// The click the session-escape plugins free a paused session with, at a
    /// screen point. It goes to the window by record when the window can be
    /// addressed, so freeing the session does not take the front either;
    /// otherwise it is a HID click.
    func escapeClick() -> (CGPoint) -> Void {
        let pid = cursorFreePID
        return { [self] point in
            if let info = bridge.getWindowInfo(), let poster = windowDelivery(for: info) {
                let local = CGPoint(x: point.x - info.position.x, y: point.y - info.position.y)
                _ = poster.click(at: local, holdUs: CGEventInput.clickHoldUs, in: info)
            } else {
                _ = CGEventInput.click(at: point, targetPID: pid)
            }
        }
    }
}
