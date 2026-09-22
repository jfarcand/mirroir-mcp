// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for MirroringWindowResolver's window identification and overlay classification.
// ABOUTME: Covers title vs size matching, AX-only geometry, paused detection and resume-control safety.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class MirroringWindowResolverTests: XCTestCase {

    private let pid: pid_t = 42

    private func axWindow(
        title: String? = "iPhone Mirroring", frame: CGRect?, hosting: AXNodeSnapshot? = nil
    ) -> MirroringAXWindow {
        MirroringAXWindow(title: title, frame: frame, hostingView: hosting)
    }

    // MARK: - windowInfo

    func testUntitledListMatchesBySizeWithinTolerance() {
        let cg = CGRect(x: 10, y: 20, width: 412, height: 900)
        let info = MirroringWindowResolver.windowInfo(
            pid: pid,
            axWindow: axWindow(frame: CGRect(x: 0, y: 0, width: 410, height: 898)),
            windowList: [WindowListEntry(windowID: 7, ownerPID: pid, name: nil, bounds: cg)])
        XCTAssertEqual(info?.windowID, 7)
        XCTAssertEqual(info?.position, cg.origin)
        XCTAssertEqual(info?.size, cg.size)
    }

    func testUnmatchedWindowReportsAXGeometry() {
        let ax = CGRect(x: 5, y: 6, width: 410, height: 898)
        let info = MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: axWindow(title: nil, frame: ax),
            windowList: [WindowListEntry(
                windowID: 7, ownerPID: pid, name: nil,
                bounds: CGRect(x: 0, y: 0, width: 868, height: 440))])
        XCTAssertEqual(info?.windowID, 0)
        XCTAssertEqual(info?.position, ax.origin)
        XCTAssertEqual(info?.size, ax.size)
    }

    func testTitleMatchNeedsNoAXFrame() {
        let cg = CGRect(x: 1, y: 2, width: 868, height: 440)
        let info = MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: axWindow(frame: nil),
            windowList: [WindowListEntry(
                windowID: 3, ownerPID: pid, name: "iPhone Mirroring", bounds: cg)])
        XCTAssertEqual(info?.size, cg.size)
    }

    func testNothingIdentifiedAndNoAXFrameIsNil() {
        XCTAssertNil(MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: axWindow(title: nil, frame: nil), windowList: []))
    }

    // MARK: - orientation

    func testOrientationFromSize() {
        XCTAssertEqual(DeviceOrientation(size: CGSize(width: 410, height: 898)), .portrait)
        XCTAssertEqual(DeviceOrientation(size: CGSize(width: 868, height: 440)), .landscape)
        XCTAssertEqual(DeviceOrientation(size: CGSize(width: 671, height: 348)), .landscape)
        XCTAssertEqual(DeviceOrientation(size: CGSize(width: 318, height: 701)), .portrait)
    }

    // MARK: - state

    func testNoHostingViewIsNoWindow() {
        XCTAssertEqual(MirroringWindowResolver.state(of: axWindow(frame: nil)), .noWindow)
    }

    func testEmptyHostingViewIsConnected() {
        let window = axWindow(frame: nil, hosting: AXNodeSnapshot(role: "AXGroup"))
        XCTAssertEqual(MirroringWindowResolver.state(of: window), .connected)
    }

    func testChildrenWithoutButtonAreConnected() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXGroup", children: [AXNodeSnapshot(role: "AXStaticText")]),
        ])
        XCTAssertEqual(
            MirroringWindowResolver.state(of: axWindow(frame: nil, hosting: hosting)),
            .connected)
    }

    func testButtonlessOverlayWithTextIsPaused() {
        // Locked / connecting / in-use overlays carry words but nothing to press.
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXImage"),
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone is locked"),
            ]),
        ])
        XCTAssertEqual(
            MirroringWindowResolver.state(of: axWindow(frame: nil, hosting: hosting)),
            .paused)
    }

    func testUnlabeledStructuralChildrenAreConnected() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXImage"),
            AXNodeSnapshot(role: "AXGroup", children: [AXNodeSnapshot(role: "AXStaticText", label: " ")]),
        ])
        XCTAssertEqual(
            MirroringWindowResolver.state(of: axWindow(frame: nil, hosting: hosting)),
            .connected)
    }

    func testNestedButtonIsPaused() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton", label: "OK"),
            ]),
        ])
        XCTAssertEqual(
            MirroringWindowResolver.state(of: axWindow(frame: nil, hosting: hosting)),
            .paused)
    }

    // MARK: - resume control

    func testResumeControlAcceptsUnlabeledAndKnownTitles() {
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: nil))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: "  "))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: "Resume"))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: " OK "))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: "Réessayer"))
    }

    func testResumeControlRejectsOtherTitledButtons() {
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Close"))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Quit"))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Disconnect"))
    }
}
