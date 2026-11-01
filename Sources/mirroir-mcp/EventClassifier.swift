// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pure classification of recorded mouse gestures and key events for the recorder.
// ABOUTME: Maps down/up positions to tap/long-press/swipe and key codes/flags to skill key names.

import CoreGraphics
import Foundation
import HelperLib

/// Pure classification logic for recorded events. Testable without CGEvent dependencies.
enum EventClassifier {

    /// Mouse gesture classification result.
    enum MouseClassification {
        case tap
        case longPress
        case swipe(direction: String)
        case ignored
    }

    /// Tap distance threshold in points — clicks within this distance are taps.
    static var tapDistanceThreshold: Double { EnvConfig.eventTapDistanceThreshold }

    /// Swipe distance threshold in points — drags beyond this distance are swipes.
    static var swipeDistanceThreshold: Double { EnvConfig.eventSwipeDistanceThreshold }

    /// Long press threshold in seconds.
    static var longPressThreshold: Double { EnvConfig.eventLongPressThreshold }

    /// Classify a mouse gesture from down/up positions and hold duration.
    /// Coordinates are window-relative.
    static func classifyMouse(
        downX: Double, downY: Double,
        upX: Double, upY: Double,
        holdSeconds: CFAbsoluteTime
    ) -> MouseClassification {
        let dx = upX - downX
        let dy = upY - downY
        let distance = sqrt(dx * dx + dy * dy)

        if distance < tapDistanceThreshold {
            return holdSeconds >= longPressThreshold ? .longPress : .tap
        }

        if distance >= swipeDistanceThreshold {
            let direction: String
            if abs(dx) > abs(dy) {
                direction = dx > 0 ? "right" : "left"
            } else {
                direction = dy > 0 ? "down" : "up"
            }
            return .swipe(direction: direction)
        }

        // Small movement — likely a slightly imprecise tap
        return .tap
    }

    /// Seconds between two events' own timestamps (`CGEvent.timestamp`,
    /// nanoseconds since boot). The recorder reads the screen while handling a
    /// mouse-down, so the time the mouse-up is handled includes that read; only
    /// the events' timestamps give the hold the user (or a posted tap) made.
    /// Zero when the timestamps are out of order.
    static func holdSeconds(downTimestamp: CGEventTimestamp,
                            upTimestamp: CGEventTimestamp) -> CFAbsoluteTime {
        guard upTimestamp > downTimestamp else { return 0 }
        return Double(upTimestamp - downTimestamp) / nanosecondsPerSecond
    }

    /// The text of the element nearest (x, y) within `maxDistance` points, or
    /// nil when none is that close. The element detector's placeholder text for
    /// an unlabeled icon (`CoreMLElementDetector.iconLabel`) names nothing a
    /// replay could find, so it is never a label.
    static func nearestLabel(x: Double, y: Double, in elements: [TapPoint],
                             maxDistance: Double) -> String? {
        var bestLabel: String?
        var bestDistance = Double.infinity
        for element in elements where element.text != CoreMLElementDetector.iconLabel {
            let dx = element.tapX - x
            let dy = element.tapY - y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < bestDistance && distance <= maxDistance {
                bestDistance = distance
                bestLabel = element.text
            }
        }
        return bestLabel
    }

    private static let nanosecondsPerSecond = 1_000_000_000.0

    /// Map macOS virtual key codes to skill key names.
    /// Returns nil for regular printable keys.
    static func specialKeyName(for keyCode: UInt16) -> String? {
        specialKeyMap[keyCode]
    }

    /// Extract modifier names from CGEvent flags.
    /// Only includes non-lock modifiers relevant to key shortcuts.
    static func extractModifiers(_ flags: CGEventFlags) -> [String] {
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("command") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskAlternate) { mods.append("option") }
        if flags.contains(.maskControl) { mods.append("control") }
        return mods
    }

    /// Reverse map from macOS virtual key codes to key names.
    private static let specialKeyMap: [UInt16: String] = [
        36: "return",
        53: "escape",
        48: "tab",
        51: "delete",
        49: "space",
        126: "up",
        125: "down",
        123: "left",
        124: "right",
        117: "forwarddelete",
    ]
}
