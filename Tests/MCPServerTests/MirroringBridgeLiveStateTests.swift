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
final class ScriptedMirroringProbe: MirroringSystemProbing, @unchecked Sendable {
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

    /// Whether the scripted app has a window in the Dock.
    private var minimized = false
    func set(minimized: Bool) { lock.withLock { self.minimized = minimized } }
    func hasMinimizedWindow(pid requested: pid_t) -> Bool {
        lock.withLock { requested == pid && minimized }
    }

    /// Whether the scripted Mac's screen is locked.
    private var screenLocked = false
    func set(screenLocked: Bool) { lock.withLock { self.screenLocked = screenLocked } }
    func isMacScreenLocked() -> Bool { lock.withLock { screenLocked } }

    /// Whether the scripted app is hidden.
    private var hidden = false
    func set(hidden: Bool) { lock.withLock { self.hidden = hidden } }
    func isAppHidden(pid requested: pid_t) -> Bool { lock.withLock { requested == pid && hidden } }

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

    private var raises: [pid_t] = []
    var raisedPIDs: [pid_t] { lock.withLock { raises } }

    func raiseMainWindow(pid requested: pid_t) -> Bool {
        lock.withLock {
            raises.append(requested)
            return requested == pid && axWindow != nil
        }
    }

    /// Whether the scripted frame is blank, and the window IDs it was asked for.
    private var blankFrame = true
    private var frameChecks: [CGWindowID] = []

    func set(blankFrame: Bool) { lock.withLock { self.blankFrame = blankFrame } }
    var checkedFrames: [CGWindowID] { lock.withLock { frameChecks } }

    func frameIsBlank(windowID: CGWindowID) -> Bool {
        lock.withLock {
            frameChecks.append(windowID)
            return blankFrame
        }
    }

    /// Bundle IDs a background launch was requested for.
    private var launches: [String] = []
    var launchedBundleIDs: [String] { lock.withLock { launches } }

    func launchInBackground(bundleID: String) -> Bool {
        lock.withLock {
            launches.append(bundleID)
            return true
        }
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

    // MARK: - Activation

    func testABackgroundLaunchAsksLaunchServicesForTheBridgedBundle() {
        XCTAssertTrue(bridge.launchInBackground())
        XCTAssertEqual(probe.launchedBundleIDs, ["com.example.mirroring"])
        XCTAssertFalse(bridge.wasQuit, "an app never seen running was not quit")
        XCTAssertNil(bridge.sessionBlock())
    }

    /// Quitting iPhone Mirroring is a stop: an app this server saw running
    /// and then gone is not reopened, and every input says why.
    func testAnAppThatWasQuitIsNotReopened() {
        show(pid: 300, frame: Self.portrait)
        XCTAssertEqual(bridge.getState(), .connected)
        probe.set(pid: nil, axWindow: nil, entries: [])

        XCTAssertEqual(bridge.getState(), .notRunning)
        XCTAssertTrue(bridge.wasQuit)
        XCTAssertFalse(bridge.launchInBackground())
        XCTAssertTrue(probe.launchedBundleIDs.isEmpty, "Launch Services was not asked")
        let block = bridge.sessionBlock()
        XCTAssertEqual(block?.move, .reopenAfterQuit)
        XCTAssertEqual(block?.move.needsUser, true)
        XCTAssertEqual(block?.refusal(targetName: "iphone").hasPrefix(
            "'iphone' is not accepting input. The window says: nothing: the app is gone. "
            + "This needs the user: open iPhone Mirroring again, then retry."), true)

        // Opened again by the user, the session is back and nothing is held against it.
        show(pid: 301, frame: Self.portrait)
        XCTAssertEqual(bridge.getState(), .connected)
        XCTAssertFalse(bridge.wasQuit)
        XCTAssertNil(bridge.sessionBlock())
    }

    func testActivateRaisesTheLiveProcessWindow() {
        show(pid: 100, frame: Self.portrait)
        bridge.activate()
        show(pid: 200, frame: Self.portrait)
        bridge.activate()
        XCTAssertEqual(probe.raisedPIDs, [100, 200])
    }

    func testActivateWithoutAProcessRaisesNothing() {
        probe.set(pid: nil, axWindow: nil, entries: [])
        bridge.activate()
        XCTAssertTrue(probe.raisedPIDs.isEmpty)
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

    /// A Mac password sheet carries an "OK" button, a resume title: pressing or
    /// clicking it would submit the prompt, so neither happens.
    func testAPasswordSheetIsNeverPressedOrClicked() {
        let sheet = AXNodeSnapshot(role: "AXSheet", children: [
            AXNodeSnapshot(role: "AXStaticText", label: "Enter your password to allow this."),
            AXNodeSnapshot(role: "AXTextField", subrole: "AXSecureTextField"),
            AXNodeSnapshot(role: "AXButton", label: "OK"),
            AXNodeSnapshot(role: "AXButton", label: "Cancel"),
        ])
        probe.set(pid: 300, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.portrait,
            hostingView: AXNodeSnapshot(role: "AXGroup"), sheets: [sheet]),
                  entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(resumePoint: CGPoint(x: 1498, y: 569))

        XCTAssertEqual(bridge.getState(), .paused)
        XCTAssertEqual(bridge.sessionBlock()?.move, .approveOnMac)
        XCTAssertNil(bridge.pausedDismissButtonPoint())
        XCTAssertFalse(bridge.pressResume())
        XCTAssertTrue(probe.resumePresses.isEmpty)
    }

    func testNoWindowWhenAXExposesNoMainWindow() {
        probe.set(pid: 100, axWindow: nil, entries: [])
        XCTAssertEqual(bridge.getState(), .noWindow)
        XCTAssertNil(bridge.getWindowInfo())
    }

    /// Measured on macOS 26.5: a minimized Mirroring window is still listed
    /// by Accessibility but is no longer the app's main window. It is named
    /// as minimized, not taken for a closed window.
    func testAMinimizedWindowReadsAsMinimizedNotAsNoWindow() {
        probe.set(pid: 100, axWindow: nil, entries: [])
        probe.set(minimized: true)
        XCTAssertEqual(bridge.getState(), .minimized)
        XCTAssertNil(bridge.getWindowInfo(), "a minimized window has no geometry to act on")

        probe.set(minimized: false)
        XCTAssertEqual(bridge.getState(), .noWindow)
    }

    // MARK: - Unlabeled controls (macOS 27) and blocked-session guidance

    /// A live macOS 27 window: three unlabeled buttons over the video.
    private func unlabeledButtonsWindow() -> MirroringAXWindow {
        MirroringAXWindow(
            title: Self.title, frame: Self.portrait,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton"), AXNodeSnapshot(role: "AXButton"),
                AXNodeSnapshot(role: "AXButton"),
            ]))
    }

    func testUnlabeledButtonsOverAFrameWithContentReadAsConnected() {
        probe.set(pid: 300, axWindow: unlabeledButtonsWindow(),
                  entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(blankFrame: false)

        XCTAssertEqual(bridge.getState(), .connected)
        XCTAssertEqual(probe.checkedFrames, [11])
    }

    func testUnlabeledButtonsOverABlankFrameReadAsPaused() {
        probe.set(pid: 300, axWindow: unlabeledButtonsWindow(),
                  entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(blankFrame: true)

        XCTAssertEqual(bridge.getState(), .paused)
        XCTAssertEqual(probe.checkedFrames, [11])
    }

    func testALabeledInterstitialNeverConsultsTheFrame() {
        probe.set(pid: 300, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.portrait,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
                AXNodeSnapshot(role: "AXButton", label: "Try Again"),
            ])), entries: windowList(pid: 300, mirroring: Self.portrait))

        XCTAssertEqual(bridge.getState(), .paused)
        XCTAssertTrue(probe.checkedFrames.isEmpty)
    }

    func testTheBlockQuotesTheWindowAndNamesTheMove() {
        probe.set(pid: 300, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.portrait,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
                AXNodeSnapshot(role: "AXStaticText", label: "Lock your iPhone to connect."),
                AXNodeSnapshot(role: "AXButton", label: "Try Again"),
            ])), entries: windowList(pid: 300, mirroring: Self.portrait))

        let block = bridge.sessionBlock()
        XCTAssertEqual(block?.move, .lockIPhone)
        XCTAssertEqual(block?.quoted, ["iPhone in Use", "Lock your iPhone to connect.", "[Try Again]"])
    }

    /// Seen on macOS 26.5 on 2026-11-09 with the screen locked: Accessibility
    /// answers with no window for an app that is running and showing one.
    private var unreadableWindow: MirroringAXWindow {
        MirroringAXWindow(title: nil, frame: nil, hostingView: nil, isWindow: false)
    }

    func testAnUnreadableWindowOnALockedMacAsksForTheMacToBeUnlocked() {
        probe.set(pid: 300, axWindow: unreadableWindow, entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(screenLocked: true)

        let block = bridge.sessionBlock()
        XCTAssertEqual(block?.move, .unlockMac)
        XCTAssertEqual(block?.said, "nothing that can be read: the Mac's screen is locked")
        XCTAssertEqual(block?.move.needsUser, true)
        XCTAssertEqual(block?.move.advice.hasPrefix("This needs the user: unlock the Mac, then retry."), true)
        XCTAssertEqual(block?.move.advice.contains("quit and reopen"), false,
                       "reopening iPhone Mirroring does not unlock the Mac")
    }

    func testAnUnreadableWindowOnAnUnlockedMacStillAsksToReopenMirroring() {
        probe.set(pid: 300, axWindow: unreadableWindow, entries: windowList(pid: 300, mirroring: Self.portrait))
        XCTAssertEqual(bridge.sessionBlock()?.move, .reopenMirroring)
    }

    /// A window that can be read speaks for itself, locked Mac or not.
    func testAReadableBlockIsNotReplacedByTheLock() {
        probe.set(pid: 300, axWindow: MirroringAXWindow(
            title: Self.title, frame: Self.portrait,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
                AXNodeSnapshot(role: "AXStaticText", label: "Lock your iPhone to connect."),
                AXNodeSnapshot(role: "AXButton", label: "Try Again"),
            ])), entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(screenLocked: true)
        XCTAssertEqual(bridge.sessionBlock()?.move, .lockIPhone)
    }

    /// Measured on macOS 26.5 with the iPhone XR, 2026-11-09: with the app
    /// hidden the frames stay live, and a tap and a swipe posted to the window
    /// changed nothing on the iPhone while both reported success.
    func testAConnectedButHiddenAppBlocksInput() {
        probe.set(pid: 300, axWindow: liveWindow(Self.portrait),
                  entries: windowList(pid: 300, mirroring: Self.portrait))
        probe.set(hidden: true)

        XCTAssertEqual(bridge.getState(), .connected, "reading still works, so the state does not change")
        let block = bridge.sessionBlock()
        XCTAssertEqual(block?.move, .showMirroring)
        XCTAssertEqual(block?.move.needsUser, true)
        XCTAssertEqual(block?.refusal(targetName: "iphone").hasPrefix(
            "'iphone' is not accepting input. The window says: nothing wrong, but its app is hidden. "
            + "This needs the user: show iPhone Mirroring again"), true)

        probe.set(hidden: false)
        XCTAssertNil(bridge.sessionBlock())
    }

    func testAConnectedSessionHasNoBlock() {
        probe.set(pid: 300, axWindow: liveWindow(Self.portrait),
                  entries: windowList(pid: 300, mirroring: Self.portrait))
        XCTAssertNil(bridge.sessionBlock())
    }
}
