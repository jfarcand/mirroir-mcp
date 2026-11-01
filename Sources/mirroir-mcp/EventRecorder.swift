// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records user interactions with the iPhone Mirroring window via CGEvent tap.
// ABOUTME: Captures taps, swipes, and keyboard input, each with the OCR screen it acted on.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Records user interactions with the iPhone Mirroring window using a passive
/// CGEvent tap (`.listenOnly`). Classifies mouse clicks as taps/swipes/long-presses
/// and groups keyboard input into type/press_key events. Each recorded step
/// carries the OCR elements of the screen it acted on, and a tap or long press
/// is labeled with the nearest of those elements.
///
/// Usage: create, call `start()`, run CFRunLoop, call `stop()` to retrieve the steps.
final class EventRecorder {
    private let bridge: MirroringBridging
    private let describer: ScreenDescribing
    private(set) var steps: [RecordedStep] = []

    // Mouse tracking state
    private var mouseDownPos: CGPoint?
    private var mouseDownTimestamp: CGEventTimestamp = 0

    // Keyboard buffering: consecutive character keys are grouped into type events
    private var keyBuffer = ""
    // The screen the buffered characters were typed into, read on the first one
    private var keyBufferScreen: [TapPoint] = []

    // Cached window geometry (refreshed on each mouse event)
    private var windowOrigin: CGPoint = .zero
    private var windowSize: CGSize = .zero

    // Cached OCR elements: the screen the next step acts on, read on each
    // mouseDown, first buffered character, and special or modifier key
    private var cachedElements: [TapPoint] = []

    // CGEvent tap resources
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(bridge: MirroringBridging, describer: ScreenDescribing) {
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

    /// Stop recording and return every captured step, plus the screen the
    /// last one reached — nil when that final OCR read failed.
    func stop() -> (steps: [RecordedStep], finalScreen: [TapPoint]?) {
        flushKeyBuffer()

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        return (steps, describer.describe()?.elements)
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
        mouseDownTimestamp = event.timestamp

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

        let holdTime = EventClassifier.holdSeconds(
            downTimestamp: mouseDownTimestamp, upTimestamp: event.timestamp)

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
            appendStep(.tap(x: relDownX, y: relDownY, label: label))

        case .longPress:
            let label = findNearestLabel(x: relDownX, y: relDownY)
            appendStep(.longPress(x: relDownX, y: relDownY, label: label,
                                  durationMs: Int(holdTime * 1000)))

        case .swipe(let direction):
            appendStep(.swipe(direction: direction))

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
            refreshOCRCache()
            appendStep(.pressKey(keyName: keyName, modifiers: modifiers))
            return
        }

        // If command/option/control modifiers are held, treat as press_key
        if hasCommandModifiers {
            flushKeyBuffer()
            refreshOCRCache()
            let charName = unicodeCharacter(from: event) ?? "unknown"
            appendStep(.pressKey(keyName: charName, modifiers: modifiers))
            return
        }

        // Regular printable character — buffer for type event. The first one
        // reads the screen the text is typed into.
        if let char = unicodeCharacter(from: event) {
            if keyBuffer.isEmpty {
                refreshOCRCache()
                keyBufferScreen = cachedElements
            }
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
        // Safe here, unlike in the MCP server: recording only runs under
        // `RecordCommand`'s `CFRunLoopRun()` — the CGEvent tap needs it — so
        // NSWorkspace's snapshot is being refreshed. See `RunningAppLocator`.
        let frontApp = NSWorkspace.shared.frontmostApplication
        return frontApp?.bundleIdentifier == EnvConfig.mirroringBundleID
    }

    /// Flush the keyboard buffer as a single type step on the screen its
    /// first character was typed into.
    func flushKeyBuffer() {
        guard !keyBuffer.isEmpty else { return }
        steps.append(RecordedStep(kind: .type(text: keyBuffer), screenBefore: keyBufferScreen))
        keyBuffer = ""
        keyBufferScreen = []
    }

    /// Record `kind` on the cached screen — the snapshot its label came from.
    private func appendStep(_ kind: RecordedEventKind) {
        steps.append(RecordedStep(kind: kind, screenBefore: cachedElements))
    }

    /// Run OCR and cache the element positions for the next step. A failed
    /// read caches no elements, so a step recorded on it carries no label and
    /// no screen rather than a previous screen's.
    private func refreshOCRCache() {
        cachedElements = describer.describe()?.elements ?? []
    }

    /// Find the nearest OCR text label to the given window-relative coordinates.
    private func findNearestLabel(x: Double, y: Double) -> String? {
        EventClassifier.nearestLabel(x: x, y: y, in: cachedElements,
                                     maxDistance: EnvConfig.eventLabelMaxDistance)
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
