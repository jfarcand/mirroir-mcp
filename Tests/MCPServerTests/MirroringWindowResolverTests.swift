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

    /// State with a frame check that fails the test when asked: only an
    /// overlay of unlabeled controls may consult the frame.
    private func state(_ window: MirroringAXWindow) -> WindowState {
        MirroringWindowResolver.state(of: window) {
            XCTFail("the frame was consulted for an unambiguous window")
            return true
        }
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
        XCTAssertEqual(state(axWindow(frame: nil)), .noWindow)
    }

    func testEmptyHostingViewIsConnected() {
        let window = axWindow(frame: nil, hosting: AXNodeSnapshot(role: "AXGroup"))
        XCTAssertEqual(state(window), .connected)
    }

    func testChildrenWithoutButtonAreConnected() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXGroup", children: [AXNodeSnapshot(role: "AXStaticText")]),
        ])
        XCTAssertEqual(
            state(axWindow(frame: nil, hosting: hosting)),
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
            state(axWindow(frame: nil, hosting: hosting)),
            .paused)
    }

    func testUnlabeledStructuralChildrenAreConnected() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXImage"),
            AXNodeSnapshot(role: "AXGroup", children: [AXNodeSnapshot(role: "AXStaticText", label: " ")]),
        ])
        XCTAssertEqual(
            state(axWindow(frame: nil, hosting: hosting)),
            .connected)
    }

    func testNestedButtonIsPaused() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton", label: "OK"),
            ]),
        ])
        XCTAssertEqual(
            state(axWindow(frame: nil, hosting: hosting)),
            .paused)
    }

    func testRevealedToolbarOverLiveSessionIsConnected() {
        // The AX tree captured with the toolbar hovered (issue #78): window
        // controls and the Home / App Switcher buttons inside the hosting view.
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXButton", subrole: "AXCloseButton"),
            AXNodeSnapshot(role: "AXButton", subrole: "AXZoomButton", children: [
                AXNodeSnapshot(role: "AXGroup", children: [AXNodeSnapshot(role: "AXGroup")]),
            ]),
            AXNodeSnapshot(role: "AXButton", subrole: "AXMinimizeButton"),
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton", identifier: "app.grid.3x3", label: "ホーム画面"),
                AXNodeSnapshot(
                    role: "AXButton", identifier: "iphone.app.switcher", label: "アプリスイッチャー"),
            ]),
        ])
        XCTAssertEqual(
            state(axWindow(frame: nil, hosting: hosting)),
            .connected)
    }

    func testRevealedToolbarDoesNotHideAnOverlay() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXButton", subrole: "AXCloseButton"),
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton", identifier: "iphone.app.switcher", label: "App Switcher"),
            ]),
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone Mirroring Paused"),
                AXNodeSnapshot(role: "AXButton", label: "Resume"),
            ]),
        ])
        XCTAssertEqual(
            state(axWindow(frame: nil, hosting: hosting)),
            .paused)
    }

    func testToolbarButtonWithoutSubroleOrIdentifierStillReadsAsOverlay() {
        // Only known chrome is exempt; an unknown button keeps the safe answer.
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXButton", label: "Home Screen"),
        ])
        XCTAssertEqual(
            state(axWindow(frame: nil, hosting: hosting)),
            .paused)
    }

    // MARK: - resume control

    func testResumeControlAcceptsOnlyKnownTitles() {
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: "Resume"))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: " OK "))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: "Réessayer"))
    }

    func testResumeControlRejectsUnlabeledButtons() {
        // An unlabeled button is never a resume control: AX-pressing it can hit a
        // close/quit control and terminate iPhone Mirroring (the crash vector).
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: nil))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "  "))
    }

    func testResumeControlRejectsOtherTitledButtons() {
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Close"))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Quit"))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Disconnect"))
    }

    // MARK: - Credential prompts

    private let liveSurface = AXNodeSnapshot(role: "AXGroup")

    func testAnAttachedSheetReadsAsPaused() {
        let touchID = AXNodeSnapshot(role: "AXSheet", children: [
            AXNodeSnapshot(role: "AXButton", label: "Use Password…"),
            AXNodeSnapshot(role: "AXButton", label: "Cancel"),
        ])
        let window = MirroringAXWindow(title: "iPhone Mirroring", frame: nil,
                                       hostingView: liveSurface, sheets: [touchID])
        XCTAssertEqual(state(window), .paused)
    }

    func testASecureFieldInASheetIsACredentialPrompt() {
        let sheet = AXNodeSnapshot(role: "AXSheet", children: [
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXTextField", subrole: "AXSecureTextField"),
            ]),
        ])
        let window = MirroringAXWindow(title: nil, frame: nil, hostingView: liveSurface,
                                       sheets: [sheet])
        XCTAssertTrue(SessionBlockClassifier.hasCredentialPrompt(window))
    }

    func testATextFieldInTheOverlayIsACredentialPrompt() {
        let overlay = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXStaticText", label: "Sign in to continue"),
            AXNodeSnapshot(role: "AXTextField"),
            AXNodeSnapshot(role: "AXButton", label: "Continue"),
        ])
        let window = MirroringAXWindow(title: nil, frame: nil, hostingView: overlay)
        XCTAssertTrue(SessionBlockClassifier.hasCredentialPrompt(window))
    }

    func testThePlainResumeOverlayIsNotACredentialPrompt() {
        let overlay = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXStaticText", label: "iPhone Mirroring Paused"),
            AXNodeSnapshot(role: "AXButton", label: "Resume"),
        ])
        let window = MirroringAXWindow(title: nil, frame: nil, hostingView: overlay)
        XCTAssertFalse(SessionBlockClassifier.hasCredentialPrompt(window))
        XCTAssertEqual(state(window), .paused)
    }

    // MARK: - Unlabeled controls (macOS 27)

    private let unlabeledButtons = AXNodeSnapshot(role: "AXGroup", children: [
        AXNodeSnapshot(role: "AXButton"), AXNodeSnapshot(role: "AXButton"),
        AXNodeSnapshot(role: "AXButton", label: "  "),
    ])

    func testUnlabeledButtonsOverContentAreConnected() {
        let window = axWindow(frame: nil, hosting: unlabeledButtons)
        XCTAssertEqual(MirroringWindowResolver.state(of: window) { false }, .connected)
    }

    func testUnlabeledButtonsOverABlankFrameArePaused() {
        let window = axWindow(frame: nil, hosting: unlabeledButtons)
        XCTAssertEqual(MirroringWindowResolver.state(of: window) { true }, .paused)
    }

    func testUnlabeledButtonsBesideLabeledTextArePausedWithoutTheFrame() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            AXNodeSnapshot(role: "AXButton"),
            AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
        ])
        XCTAssertEqual(state(axWindow(frame: nil, hosting: hosting)), .paused)
    }
}
