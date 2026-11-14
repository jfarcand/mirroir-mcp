/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Standalone test script to verify CGEvent mouse input works with iPhone Mirroring.
// ABOUTME: Posts click and scroll events via CGEvent to verify pointing works with iPhone Mirroring.

import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Find iPhone Mirroring Window

func findMirroringWindow() -> (position: CGPoint, size: CGSize)? {
    let bundleID = ProcessInfo.processInfo.environment["IPHONE_MIRROIR_BUNDLE_ID"]
        ?? "com.apple.ScreenContinuity"

    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleID
    }) else {
        print("ERROR: iPhone Mirroring not running (bundle: \(bundleID))")
        return nil
    }

    let pid = app.processIdentifier
    let appRef = AXUIElementCreateApplication(pid)

    var windowValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appRef, kAXMainWindowAttribute as CFString, &windowValue)
    guard result == .success, let window = windowValue else {
        print("ERROR: Could not get main window (AX result: \(result.rawValue))")
        return nil
    }

    let axWindow = unsafeDowncast(window as AnyObject, to: AXUIElement.self)

    var posValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue)
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)

    var position = CGPoint.zero
    var size = CGSize.zero
    if let pv = posValue {
        AXValueGetValue(pv as! AXValue, .cgPoint, &position)
    }
    if let sv = sizeValue {
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
    }

    print("Window: position=(\(Int(position.x)),\(Int(position.y))) size=\(Int(size.width))x\(Int(size.height))")
    return (position, size)
}

// MARK: - CGEvent Tests

func testClick(at screenPoint: CGPoint) -> Bool {
    print("\n--- Test 1: CGEvent Click at (\(Int(screenPoint.x)),\(Int(screenPoint.y))) ---")

    // Warp cursor to target position
    CGWarpMouseCursorPosition(screenPoint)
    usleep(50_000) // 50ms settle

    // Post left mouse down
    guard let mouseDown = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: screenPoint,
        mouseButton: .left
    ) else {
        print("FAIL: Could not create mouseDown event")
        return false
    }
    mouseDown.post(tap: .cghidEventTap)
    print("  Posted leftMouseDown")

    usleep(50_000) // 50ms hold

    // Post left mouse up
    guard let mouseUp = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: screenPoint,
        mouseButton: .left
    ) else {
        print("FAIL: Could not create mouseUp event")
        return false
    }
    mouseUp.post(tap: .cghidEventTap)
    print("  Posted leftMouseUp")
    print("  OK — check iPhone Mirroring for tap response")
    return true
}

func testScroll(at screenPoint: CGPoint) -> Bool {
    print("\n--- Test 2: CGEvent Scroll at (\(Int(screenPoint.x)),\(Int(screenPoint.y))) ---")

    // Warp cursor to target position
    CGWarpMouseCursorPosition(screenPoint)
    usleep(50_000)

    // Post scroll wheel event (scroll down = negative wheel1)
    guard let scroll = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: -100,
        wheel2: 0,
        wheel3: 0
    ) else {
        print("FAIL: Could not create scroll event")
        return false
    }
    scroll.location = screenPoint
    scroll.post(tap: .cghidEventTap)
    print("  Posted scroll (pixel, wheel1=-100)")
    print("  OK — check iPhone Mirroring for scroll response")
    return true
}

func testDrag(from start: CGPoint, to end: CGPoint) -> Bool {
    print("\n--- Test 3: CGEvent Drag from (\(Int(start.x)),\(Int(start.y))) to (\(Int(end.x)),\(Int(end.y))) ---")

    CGWarpMouseCursorPosition(start)
    usleep(50_000)

    // Mouse down
    guard let mouseDown = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: start,
        mouseButton: .left
    ) else {
        print("FAIL: Could not create mouseDown event")
        return false
    }
    mouseDown.post(tap: .cghidEventTap)

    // Interpolate drag movement
    let steps = 20
    let durationUs: UInt32 = 500_000 // 500ms total
    let stepDelay = durationUs / UInt32(steps)

    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = start.x + (end.x - start.x) * t
        let y = start.y + (end.y - start.y) * t
        let point = CGPoint(x: x, y: y)

        guard let dragEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { continue }
        dragEvent.post(tap: .cghidEventTap)
        usleep(stepDelay)
    }

    // Mouse up
    guard let mouseUp = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: end,
        mouseButton: .left
    ) else {
        print("FAIL: Could not create mouseUp event")
        return false
    }
    mouseUp.post(tap: .cghidEventTap)
    print("  Posted drag sequence (\(steps) steps, 500ms)")
    print("  OK — check iPhone Mirroring for drag response")
    return true
}

// MARK: - Main

print("CGEvent iPhone Mirroring Test")
print("=============================")
print("This script tests whether CGEvent mouse/scroll events work with iPhone Mirroring.")
print("Watch the mirrored iPhone screen to see if interactions register.\n")

guard let window = findMirroringWindow() else {
    exit(1)
}

// Activate iPhone Mirroring so it's frontmost
let bundleID = ProcessInfo.processInfo.environment["IPHONE_MIRROIR_BUNDLE_ID"]
    ?? "com.apple.ScreenContinuity"
if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
    app.activate()
    usleep(500_000) // 500ms to let it come to front
}

// Click at the center of the window
let centerX = window.position.x + window.size.width / 2
let centerY = window.position.y + window.size.height / 2
let center = CGPoint(x: centerX, y: centerY)

let clickOK = testClick(at: center)
usleep(1_000_000) // 1s pause between tests

let scrollOK = testScroll(at: center)
usleep(1_000_000)

// Drag from center upward (simulates swipe-up scroll)
let dragStart = CGPoint(x: centerX, y: centerY + 100)
let dragEnd = CGPoint(x: centerX, y: centerY - 100)
let dragOK = testDrag(from: dragStart, to: dragEnd)

print("\n=============================")
print("Results:")
print("  Click:  \(clickOK ? "POSTED" : "FAILED")")
print("  Scroll: \(scrollOK ? "POSTED" : "FAILED")")
print("  Drag:   \(dragOK ? "POSTED" : "FAILED")")
print("\nIf iPhone Mirroring responded to these events, CGEvent pointing works!")
print("If nothing happened, CGEvent does not reach iPhone Mirroring.")
print("Check that Accessibility permissions are granted.")
