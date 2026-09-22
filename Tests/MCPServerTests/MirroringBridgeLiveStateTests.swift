// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that MirroringBridge resolves geometry, orientation, state and PID live on every call.
// ABOUTME: A scripted probe changes the system between two calls: rotation, resize, AX lag, restart.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

/// Scripted `MirroringSystemProbing`. Mock rationale: rotating the iPhone,
/// resizing iPhone Mirroring and restarting its process cannot be driven from
/// a unit test; the fake stands in for Launch Services, AX and the window
/// server, and each test mutates it between two bridge calls.
/// `TargetRestartRecoveryTests` covers the real process restart end to end.
private final class ScriptedMirroringProbe: MirroringSystemProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var axWindow: MirroringAXWindow?
    private var entries: [WindowListEntry] = []

    func set(pid: pid_t?, axWindow: MirroringAXWindow?, entries: [WindowListEntry]) {
        lock.withLock {
            self.pid = pid
            self.axWindow = axWindow
            self.entries = entries
        }
    }

    func processID(bundleID: String) -> pid_t? { lock.withLock { pid } }

    func mainWindow(pid requested: pid_t) -> MirroringAXWindow? {
        lock.withLock { requested == pid ? axWindow : nil }
    }

    func windowList() -> [WindowListEntry] { lock.withLock { entries } }

    /// Resume control point the scripted overlay shows (nil = none).
    private var resumePoint: CGPoint?
    private var presses: [pid_t] = []

    func set(resumePoint: CGPoint?) { lock.withLock { self.resumePoint = resumePoint } }
    var resumePresses: [pid_t] { lock.withLock { presses } }

    func pressResumeControl(pid requested: pid_t) -> Bool {
        lock.withLock {
            presses.append(requested)
            return requested == pid && resumePoint != nil
        }
    }

    func dismissControlPoint(pid requested: pid_t) -> CGPoint? {
        lock.withLock { requested == pid ? resumePoint : nil }
    }
}

final class MirroringBridgeLiveStateTests: XCTestCase {

    private static let title = "iPhone Mirroring"
    private static let portrait = CGRect(x: 1293, y: 120, width: 410, height: 898)
    private static let landscape = CGRect(x: 1040, y: 347, width: 868, height: 440)
    private static let resized = CGRect(x: 1200, y: 288, width: 318, height: 701)
    private static let welcome = CGRect(x: 562, y: 240, width: 640, height: 662)
    private static let menuSliver = CGRect(x: 0, y: 0, width: 1710, height: 34)

    private let probe = ScriptedMirroringProbe()
    private lazy var bridge = MirroringBridge(bundleID: "com.example.mirroring", probe: probe)

    /// A connected mirroring window: the hosting view has no children.
    private func liveWindow(_ frame: CGRect) -> MirroringAXWindow {
        MirroringAXWindow(
            title: Self.title, frame: frame,
            hostingView: AXNodeSnapshot(role: "AXGroup"))
    }

    /// The window server's list for `pid`, shaped like the one measured on a
    /// real Mac: the titled mirroring window, a larger titled welcome window,
    /// and full-width menu-bar slivers.
    private func windowList(pid: pid_t, mirroring frame: CGRect, windowID: CGWindowID = 11)
        -> [WindowListEntry] {
        [
            WindowListEntry(windowID: 90, ownerPID: pid, name: "", bounds: Self.menuSliver),
            WindowListEntry(windowID: windowID, ownerPID: pid, name: Self.title, bounds: frame),
            WindowListEntry(
                windowID: 91, ownerPID: pid, name: "Welcome to iPhone Mirroring",
                bounds: Self.welcome),
        ]
    }

    private func show(pid: pid_t, frame: CGRect, axFrame: CGRect? = nil) {
        probe.set(
            pid: pid, axWindow: liveWindow(axFrame ?? frame),
            entries: windowList(pid: pid, mirroring: frame))
    }

    // MARK: - Geometry across calls

    func testRotationBetweenCallsIsReflected() throws {
        show(pid: 100, frame: Self.portrait)
        let first = try XCTUnwrap(bridge.getWindowInfo())
        XCTAssertEqual(first.size, Self.portrait.size)
        XCTAssertEqual(bridge.getOrientation(), .portrait)

        show(pid: 100, frame: Self.landscape)
        let second = try XCTUnwrap(bridge.getWindowInfo())
        XCTAssertEqual(second.position, Self.landscape.origin)
        XCTAssertEqual(second.size, Self.landscape.size)
        XCTAssertEqual(second.orientation, .landscape)
        XCTAssertEqual(bridge.getOrientation(), .landscape)
    }

    func testResizeBetweenCallsIsReflected() throws {
        show(pid: 100, frame: Self.portrait)
        XCTAssertEqual(bridge.getWindowInfo()?.size, Self.portrait.size)

        show(pid: 100, frame: Self.resized)
        let second = try XCTUnwrap(bridge.getWindowInfo())
        XCTAssertEqual(second.position, Self.resized.origin)
        XCTAssertEqual(second.size, Self.resized.size)
        XCTAssertEqual(second.windowID, 11)
        XCTAssertEqual(bridge.getOrientation(), .portrait)
    }

    func testLaggingAXGeometryDoesNotHideTheLiveBounds() throws {
        // AX still reports the pre-rotation frame; the window server already
        // has the rotated window. The title identifies it regardless of size.
        show(pid: 100, frame: Self.landscape, axFrame: Self.portrait)
        let info = try XCTUnwrap(bridge.getWindowInfo())
        XCTAssertEqual(info.position, Self.landscape.origin)
        XCTAssertEqual(info.size, Self.landscape.size)
        XCTAssertEqual(bridge.getOrientation(), .landscape)
    }

    // MARK: - Process across calls

    func testProcessRestartUnderNewPIDIsFollowed() throws {
        show(pid: 100, frame: Self.portrait)
        XCTAssertEqual(bridge.getWindowInfo()?.pid, 100)
        XCTAssertEqual(bridge.getState(), .connected)

        probe.set(pid: nil, axWindow: nil, entries: [])
        XCTAssertEqual(bridge.getState(), .notRunning)
        XCTAssertNil(bridge.getWindowInfo())

        show(pid: 200, frame: Self.resized)
        let info = try XCTUnwrap(bridge.getWindowInfo())
        XCTAssertEqual(info.pid, 200)
        XCTAssertEqual(info.size, Self.resized.size)
        XCTAssertEqual(bridge.getState(), .connected)
    }

    func testWindowsOfTheDeadPIDAreIgnored() {
        // The new process has not drawn its window yet; the old PID's window
        // is still listed. The bridge must not report the dead window's bounds.
        probe.set(
            pid: 200, axWindow: liveWindow(Self.resized),
            entries: windowList(pid: 100, mirroring: Self.portrait))
        let info = bridge.getWindowInfo()
        XCTAssertEqual(info?.pid, 200)
        XCTAssertEqual(info?.windowID, 0)
        XCTAssertEqual(info?.size, Self.resized.size)
    }

    // MARK: - State across calls

    func testStateFollowsOverlayAppearingAndClearing() {
        show(pid: 100, frame: Self.portrait)
        XCTAssertEqual(bridge.getState(), .connected)

        let overlay = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXStaticText", label: "iPhone Mirroring Paused"),
            AXNodeSnapshot(role: "AXButton"),
        ])
        probe.set(
            pid: 100,
            axWindow: MirroringAXWindow(
                title: Self.title, frame: Self.portrait, hostingView: overlay),
            entries: windowList(pid: 100, mirroring: Self.portrait))
        XCTAssertEqual(bridge.getState(), .paused)

        show(pid: 100, frame: Self.portrait)
        XCTAssertEqual(bridge.getState(), .connected)
    }

    func testResumeAndDismissGoThroughTheProbeOfTheLivePID() {
        let point = CGPoint(x: 1498, y: 569)
        probe.set(pid: 300, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.portrait,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton", label: "OK"),
            ])), entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(resumePoint: point)
        XCTAssertEqual(bridge.getState(), .paused)
        XCTAssertEqual(bridge.pausedDismissButtonPoint(), point)
        XCTAssertTrue(bridge.pressResume())
        XCTAssertEqual(probe.resumePresses, [300])

        probe.set(pid: nil, axWindow: nil, entries: [])
        XCTAssertNil(bridge.pausedDismissButtonPoint())
        XCTAssertFalse(bridge.pressResume())
        XCTAssertEqual(probe.resumePresses, [300], "no press without a running process")
    }

    func testNoWindowWhenAXExposesNoMainWindow() {
        probe.set(pid: 100, axWindow: nil, entries: [])
        XCTAssertEqual(bridge.getState(), .noWindow)
        XCTAssertNil(bridge.getWindowInfo())
    }
}
