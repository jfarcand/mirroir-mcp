// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records user interactions with the iPhone Mirroring window via CGEvent tap.
// ABOUTME: Captures taps, swipes, and keyboard input for scenario YAML generation.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// A single recorded user interaction with timestamp.
struct RecordedEvent {
    let timestamp: CFAbsoluteTime
    let kind: RecordedEventKind
}

/// The type of user interaction that was recorded.
enum RecordedEventKind {
    case tap(x: Double, y: Double, label: String?)
    case swipe(direction: String)
    case longPress(x: Double, y: Double, label: String?, durationMs: Int)
    case type(text: String)
    case pressKey(keyName: String, modifiers: [String])
}

/// Records user interactions with the iPhone Mirroring window using a passive
/// CGEvent tap (`.listenOnly`). Classifies mouse clicks as taps/swipes/long-presses
/// and groups keyboard input into type/press_key events. Optionally labels taps
/// with the nearest OCR text element.
///
/// Usage: create, call `start()`, run CFRunLoop, call `stop()` to retrieve events.
final class EventRecorder {
    private let bridge: MirroringBridging
    private let describer: ScreenDescribing?
    private(set) var events: [RecordedEvent] = []

    // Mouse tracking state
    private var mouseDownPos: CGPoint?
    private var mouseDownTime: CFAbsoluteTime = 0

    // Keyboard buffering: consecutive character keys are grouped into type events
    private var keyBuffer = ""

    // Cached window geometry (refreshed on each mouse event)
    private var windowOrigin: CGPoint = .zero
    private var windowSize: CGSize = .zero

    // Cached OCR elements (refreshed on each mouseDown for label lookup)
    private var cachedElements: [TapPoint] = []

    // CGEvent tap resources
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(bridge: MirroringBridging, describer: ScreenDescribing? = nil) {
        self.bridge = bridge
        self.describer = describer
    }

    /// Install a passive CGEvent tap and prepare for recording.
    /// Returns false if the tap cannot be created (missing accessibility permissions).
    func start() -> Bool {
        guard let info = bridge.getWindowInfo() else { return false }
        windowOrigin = info.position
        windowSize = info.size

        // Run initial OCR to cache element positions
        refreshOCRCache()

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        return true
    }

    /// Stop recording and return all captured events.
    func stop() -> [RecordedEvent] {
        flushKeyBuffer()

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        return events
    }

    // MARK: - Event Handling

    /// Called from the CGEvent tap callback for each observed event.
    func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        // Re-enable tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        // Refresh window geometry
        if let info = bridge.getWindowInfo() {
            windowOrigin = info.position
            windowSize = info.size
        }

        switch type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseUp:
            handleMouseUp(event)
        case .keyDown:
            handleKeyDown(event)
        default:
            break
        }
    }

    private func handleMouseDown(_ event: CGEvent) {
        let pos = event.location
        guard isInsideWindow(pos) else { return }

        mouseDownPos = pos
        mouseDownTime = CFAbsoluteTimeGetCurrent()

        // Run OCR now while the screen still shows the state the user sees.
        // In .listenOnly mode, this doesn't block event delivery to the app.
        refreshOCRCache()
    }

    private func handleMouseUp(_ event: CGEvent) {
        guard let downPos = mouseDownPos else { return }
        let upPos = event.location

        // At least one endpoint must be inside the window
        guard isInsideWindow(downPos) || isInsideWindow(upPos) else {
            mouseDownPos = nil
            return
        }

        let holdTime = CFAbsoluteTimeGetCurrent() - mouseDownTime

        // Convert to window-relative coordinates
        let relDownX = Double(downPos.x - windowOrigin.x)
        let relDownY = Double(downPos.y - windowOrigin.y)

        let classified = EventClassifier.classifyMouse(
            downX: relDownX, downY: relDownY,
            upX: Double(upPos.x - windowOrigin.x),
            upY: Double(upPos.y - windowOrigin.y),
            holdSeconds: holdTime
        )

        // Flush any pending key buffer before recording a mouse event
        flushKeyBuffer()

        switch classified {
        case .tap:
            let label = findNearestLabel(x: relDownX, y: relDownY)
            events.append(RecordedEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                kind: .tap(x: relDownX, y: relDownY, label: label)
            ))

        case .longPress:
            let label = findNearestLabel(x: relDownX, y: relDownY)
            events.append(RecordedEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                kind: .longPress(x: relDownX, y: relDownY, label: label,
                                 durationMs: Int(holdTime * 1000))
            ))

        case .swipe(let direction):
            events.append(RecordedEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                kind: .swipe(direction: direction)
            ))

        case .ignored:
            break
        }

        mouseDownPos = nil
    }

    private func handleKeyDown(_ event: CGEvent) {
        // Only capture keys when mirroring window is frontmost
        guard isMirroringFrontmost() else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Extract modifier state (ignoring Shift for printable characters)
        let modifiers = EventClassifier.extractModifiers(flags)
        let hasCommandModifiers = modifiers.contains(where: { $0 != "shift" })

        // Check if it's a special key
        if let keyName = EventClassifier.specialKeyName(for: keyCode) {
            flushKeyBuffer()
            events.append(RecordedEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                kind: .pressKey(keyName: keyName, modifiers: modifiers)
            ))
            return
        }

        // If command/option/control modifiers are held, treat as press_key
        if hasCommandModifiers {
            flushKeyBuffer()
            let charName = unicodeCharacter(from: event) ?? "unknown"
            events.append(RecordedEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                kind: .pressKey(keyName: charName, modifiers: modifiers)
            ))
            return
        }

        // Regular printable character — buffer for type event
        if let char = unicodeCharacter(from: event) {
            keyBuffer.append(char)
        }
    }

    // MARK: - Helpers

    private func isInsideWindow(_ point: CGPoint) -> Bool {
        let relX = point.x - windowOrigin.x
        let relY = point.y - windowOrigin.y
        return relX >= 0 && relX <= windowSize.width
            && relY >= 0 && relY <= windowSize.height
    }

    private func isMirroringFrontmost() -> Bool {
        let frontApp = NSWorkspace.shared.frontmostApplication
        return frontApp?.bundleIdentifier == EnvConfig.mirroringBundleID
    }

    /// Flush the keyboard buffer as a single type event.
    func flushKeyBuffer() {
        guard !keyBuffer.isEmpty else { return }
        events.append(RecordedEvent(
            timestamp: CFAbsoluteTimeGetCurrent(),
            kind: .type(text: keyBuffer)
        ))
        keyBuffer = ""
    }

    /// Run OCR and cache the element positions for tap label lookup.
    private func refreshOCRCache() {
        guard let describer = describer,
              let result = describer.describe(skipOCR: false)
        else { return }
        cachedElements = result.elements
    }

    /// Find the nearest OCR text label to the given window-relative coordinates.
    private func findNearestLabel(x: Double, y: Double) -> String? {
        let maxDistance = EnvConfig.eventLabelMaxDistance
        var bestLabel: String?
        var bestDistance = Double.infinity

        for element in cachedElements {
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

    /// Extract the Unicode character string from a keyDown CGEvent.
    private func unicodeCharacter(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &chars
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - CGEvent Tap Callback

/// Global C callback for the CGEvent tap. Dispatches to the EventRecorder instance.
private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<EventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handleEvent(type, event)
    return Unmanaged.passUnretained(event)
}

// MARK: - Event Classification (Pure Logic)

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

    /// Map macOS virtual key codes to scenario key names.
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
