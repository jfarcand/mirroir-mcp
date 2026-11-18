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

    /// Measured on macOS 26.5 with Stage Manager on (#83): a window in the
    /// strip keeps its AX frame while the window server reports the tilted
    /// thumbnail. The AX frame is where the window shows once it is on stage.
    func testStageManagerStripThumbnailReportsAXGeometryWithTheWindowID() {
        let ax = CGRect(x: 1273, y: 34, width: 430, height: 942)
        let info = MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: axWindow(frame: ax),
            windowList: [WindowListEntry(
                windowID: 124085, ownerPID: pid, name: "iPhone Mirroring",
                bounds: CGRect(x: 1648, y: 494, width: 47, height: 141))])
        XCTAssertEqual(info?.windowID, 124085)
        XCTAssertEqual(info?.position, ax.origin)
        XCTAssertEqual(info?.size, ax.size)
    }

    /// Measured on macOS 26.5: Mission Control shows the window at about half
    /// its size, and the window server reports that scaled copy.
    func testMissionControlThumbnailReportsAXGeometry() {
        let ax = CGRect(x: 1273, y: 34, width: 430, height: 942)
        let info = MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: axWindow(frame: ax),
            windowList: [WindowListEntry(
                windowID: 124085, ownerPID: pid, name: "iPhone Mirroring",
                bounds: CGRect(x: 1461, y: 580, width: 228, height: 499))])
        XCTAssertEqual(info?.size, ax.size)
        XCTAssertEqual(info?.position, ax.origin)
    }

    /// After a rotation AX can still hold the portrait size while the window
    /// server already shows landscape: the window server wins.
    func testRotatedWindowKeepsWindowServerGeometryOverLaggingAX() {
        let cg = CGRect(x: 1000, y: 300, width: 942, height: 430)
        let info = MirroringWindowResolver.windowInfo(
            pid: pid, axWindow: axWindow(frame: CGRect(x: 1273, y: 34, width: 430, height: 942)),
            windowList: [WindowListEntry(
                windowID: 9, ownerPID: pid, name: "iPhone Mirroring", bounds: cg)])
        XCTAssertEqual(info?.size, cg.size)
        XCTAssertEqual(info?.position, cg.origin)
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

    /// carnet#77: the AX tree captured on 2026-11-17 after typing "horloge"
    /// into Spotlight on an iOS 27 phone. The Mac drew its autocorrection
    /// bubble over the live window: "Horloge" and a close button.
    private var autocorrectionBubble: AXNodeSnapshot {
        AXNodeSnapshot(role: "AXGroup", identifier: "NSAutocorrectionSuggestion", children: [
            AXNodeSnapshot(role: "AXList", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "Horloge"),
            ]),
            AXNodeSnapshot(role: "AXButton", label: "close"),
        ])
    }

    func testTheMacAutocorrectionBubbleOverALiveSessionIsConnected() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [autocorrectionBubble])
        XCTAssertEqual(state(axWindow(frame: nil, hosting: hosting)), .connected)
    }

    func testTheAutocorrectionBubbleDoesNotHideAnOverlay() {
        let hosting = AXNodeSnapshot(role: "AXGroup", children: [
            autocorrectionBubble,
            AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone Mirroring Paused"),
                AXNodeSnapshot(role: "AXButton", label: "Resume"),
            ]),
        ])
        XCTAssertEqual(state(axWindow(frame: nil, hosting: hosting)), .paused)
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

    // MARK: - mirror window

    /// carnet#85, measured 2026-11-17: with iPhone Mirroring Settings open, the
    /// Settings window was the AX main window and read as a paused session.
    func testTheSettingsWindowIsNeverTakenForTheMirror() {
        let index = MirroringWindowResolver.mirrorWindowIndex(identifiers: [
            "com_apple_SwiftUI_Settings_window", "iphone-mirroring-main", "com_apple_SwiftUI_Settings_window",
        ])
        XCTAssertEqual(index, 1)
    }

    func testTheMainWindowIsTheMirrorWhenItIsNotAnAccessory() {
        XCTAssertEqual(MirroringWindowResolver.mirrorWindowIndex(identifiers: ["iphone-mirroring-main"]), 0)
        XCTAssertEqual(MirroringWindowResolver.mirrorWindowIndex(identifiers: [nil]), 0,
                       "a window with no identifier (FakeMirroring) is the mirror")
    }

    func testOnlyAccessoryWindowsMeanNoMirror() {
        XCTAssertNil(MirroringWindowResolver.mirrorWindowIndex(
            identifiers: ["com_apple_SwiftUI_Settings_window"]))
    }

    // MARK: - resume control

    func testResumeControlAcceptsOnlyKnownTitles() {
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: "Resume"))
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(label: " OK "))
        // A title in the Mac's language is accepted on a Mac set to that
        // language, where iPhone Mirroring draws it; not on an English one.
        XCTAssertTrue(MirroringWindowResolver.isResumeControl(
            label: "Réessayer", phrases: InterstitialFixtures.frenchCanadianPhrases))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(
            label: "Réessayer", phrases: InterstitialFixtures.englishPhrases))
        XCTAssertFalse(MirroringWindowResolver.isResumeControl(label: "Close"))
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
