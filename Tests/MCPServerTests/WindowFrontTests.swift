// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for WindowListHelper.isInFront over window lists shaped like a desktop Mac and a CI runner.
// ABOUTME: Pins that a floating target counts as front, and that menu bar and Dock overlays never decide it.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class WindowFrontTests: XCTestCase {

    private let target: pid_t = 100
    private let other: pid_t = 200
    private let dock: pid_t = 300
    private let menuBar: pid_t = 400

    private func entry(_ pid: pid_t, layer: Int) -> WindowListEntry {
        WindowListEntry(windowID: CGWindowID(Int(pid) * 100 + layer), ownerPID: pid, name: nil,
                        bounds: CGRect(x: 0, y: 0, width: 400, height: 800), layer: layer)
    }

    /// The menu bar and the Dock sit in front of every app window.
    private var overlays: [WindowListEntry] {
        [entry(menuBar, layer: 25), entry(dock, layer: 20)]
    }

    func testOwningTheFrontmostNormalWindowIsFront() {
        XCTAssertTrue(WindowListHelper.isInFront(
            pid: target, entries: overlays + [entry(target, layer: 0), entry(other, layer: 0)]))
    }

    func testAnotherAppsNormalWindowInFrontIsNotFront() {
        XCTAssertFalse(WindowListHelper.isInFront(
            pid: target, entries: overlays + [entry(other, layer: 0), entry(target, layer: 0)]))
    }

    /// CI runs FakeMirroring at the floating level with no layer-0 window at
    /// all: activating it must confirm, not read as "no visible app".
    func testAFloatingTargetWithNoNormalWindowsIsFront() {
        XCTAssertTrue(WindowListHelper.isInFront(
            pid: target, entries: overlays + [entry(target, layer: 3)]))
    }

    func testAFloatingTargetAboveAnotherAppsWindowIsFront() {
        XCTAssertTrue(WindowListHelper.isInFront(
            pid: target, entries: overlays + [entry(target, layer: 3), entry(other, layer: 0)]))
    }

    func testAWindowAtTheMenuBarLayerDoesNotMakeTheTargetFront() {
        let menuLayer = WindowListHelper.mainMenuLayer
        XCTAssertFalse(WindowListHelper.isInFront(
            pid: target, entries: [entry(target, layer: menuLayer), entry(other, layer: 0)]))
    }

    func testNoTargetWindowIsNotFront() {
        XCTAssertFalse(WindowListHelper.isInFront(pid: target, entries: overlays))
    }
}
