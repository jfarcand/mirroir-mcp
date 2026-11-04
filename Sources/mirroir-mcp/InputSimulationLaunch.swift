// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Starts iPhone Mirroring in the background when an input call finds it not running, and launches apps through Spotlight.
// ABOUTME: The user's front app keeps the focus; a launch presses Return only when Spotlight's top result is an app.

import Foundation
import HelperLib

extension InputSimulation {

    /// Launch a target that is not running, without making it active, and
    /// wait for its session to come up. Only a bridge that can launch its
    /// app (iPhone Mirroring) does anything; other targets are started by
    /// the user. Nothing is sent: the caller's connection check then reports
    /// whatever state the launch reached.
    func launchIfNotRunning(tag: String) {
        guard bridge.getState() == .notRunning,
              let launcher = bridge as? MenuActionCapable else { return }
        guard launcher.launchInBackground() else {
            DebugLog.log(tag, "target not running and the background launch was refused")
            return
        }
        DebugLog.log(tag, "target not running — launched in the background")
        waitForConnection(tag: tag)
    }

    /// Wait while the session is starting: the process launching, the window
    /// opening, or the window reading "Connecting to". Returns as soon as the
    /// session is connected, shows a block that waiting does not clear (the
    /// iPhone in use, a Connect button, a Mac prompt), or
    /// `EnvConfig.launchConnectTimeoutUs` passes.
    func waitForConnection(tag: String) {
        let pollUs = max(EnvConfig.launchConnectPollUs, 1)
        var waitedUs: UInt32 = 0
        while waitedUs < EnvConfig.launchConnectTimeoutUs {
            let state = bridge.getState()
            if state == .connected { return }
            if state == .paused,
               (bridge as? MenuActionCapable)?.sessionBlock()?.move != .waitWhileConnecting {
                return
            }
            usleep(pollUs)
            waitedUs += pollUs
        }
        DebugLog.log(tag, "session still starting after \(waitedUs / 1000)ms")
    }

    /// Launch an app by name using Spotlight search.
    /// Opens Spotlight, types the app name, waits for results, and presses Return.
    /// Returns nil on success, or an error message on failure.
    func launchApp(name: String) -> String? {
        if let stateError = ensureConnected(tag: "launchApp") {
            return stateError
        }
        DebugLog.log("launchApp", "launching '\(name)'")

        // Step 1: Open Spotlight via menu action (requires MenuActionCapable). The
        // screen before it is kept to tell when Spotlight has opened.
        let beforeOpen = pasteVerifier?.describe(settleTimeoutUs: 0)?.elements ?? []
        let openFailure = "Failed to open Spotlight. Is target '\(bridge.targetName)' running?"
        guard let menuBridge = bridge as? (any MenuActionCapable) else {
            DebugLog.log("launchApp", "ERROR: failed to open Spotlight")
            return openFailure
        }
        // The menu item toggles Spotlight: pressed while Spotlight is open, it
        // closes it, and the name would then be typed into the app behind.
        let alreadyOpen = SpotlightDetector.isSpotlightVisible(elements: beforeOpen)
        if alreadyOpen {
            DebugLog.log("launchApp", "Spotlight already open; menu item not pressed")
        } else {
            guard menuBridge.triggerMenuAction(menu: "View", item: "Spotlight") else {
                DebugLog.log("launchApp", "ERROR: failed to open Spotlight")
                return openFailure
            }
            usleep(EnvConfig.spotlightAppearanceUs)
        }

        // Step 2: Type the app name, and confirm Spotlight shows it before Return.
        // Spotlight can reopen holding the previous query in a state that swallows
        // keystrokes; Return would then launch the previous result.
        // Spotlight opened while a Home transition finishes is closed again by it,
        // so a Spotlight that never shows is opened once more before giving up.
        guard let opened = spotlightScreen(replacing: beforeOpen)
                ?? (menuBridge.triggerMenuAction(menu: "View", item: "Spotlight")
                    ? spotlightScreen(replacing: beforeOpen) : nil) else {
            return "Spotlight did not open (or the screen could not be read), so " +
                "'\(name)' was not searched for; Return was not pressed."
        }
        // An app tile a held query already shows is tapped instead: typing into a
        // held query can be ignored. The idle page holds no query and takes typing,
        // which is more reliable than its suggestion tiles.
        if SpotlightDetector.holdsQuery(elements: opened.elements),
           let tile = SpotlightAppTile.label(for: name, in: opened.elements) {
            return openTile(tile, name: name, spotlight: opened.elements)
        }
        let before = opened.elements.map(\.text)
        // Spotlight left open keeps its query unselected, and typing would add to it.
        // Reopened, it selects the query, so typing replaces it.
        if alreadyOpen {
            _ = pressKey(keyName: "a", modifiers: ["command"])
        }
        let typeResult = typeText(name)
        guard typeResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to type app name")
            return typeResult.error ?? "Failed to type app name"
        }
        usleep(EnvConfig.searchResultsPopulateUs)
        guard spotlightShows(name, comparedTo: before) else {
            // Spotlight can open on its idle page, then restore the held query that
            // swallowed the typing: its tile for this app still opens it.
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               let tile = SpotlightAppTile.label(for: name, in: screen.elements) {
                return openTile(tile, name: name, spotlight: screen.elements)
            }
            DebugLog.log("launchApp", "ERROR: '\(name)' never appeared in Spotlight")
            return "Typed '\(name)' into Spotlight but it never appeared on screen, so " +
                "Return was not pressed. Keystrokes are probably not reaching the iPhone, "
                + "which only quitting and reopening iPhone Mirroring on the Mac clears. "
                + AgentInstruction.waitForUser
        }

        // Step 3: Press Return to launch the top result, once that result is an
        // app. Without one, Return opens a web suggestion or an App Store page.
        guard returnWillOpenApp() else {
            DebugLog.log("launchApp", "ERROR: no app is Spotlight's top result for '\(name)'")
            // The menu item toggles it: leave the iPhone as it was, not on this query.
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Spotlight")
            return "Spotlight lists no app as its top result for '\(name)', so Return was not "
                + "pressed: pressing it would open a web suggestion or an App Store page. The app "
                + "may not be installed, or its name on this iPhone may differ."
        }
        let keyResult = pressKey(keyName: "return")
        guard keyResult.success else {
            DebugLog.log("launchApp", "ERROR: failed to press Return")
            return keyResult.error ?? "Failed to press Return"
        }

        DebugLog.log("launchApp", "launched '\(name)' OK")
        return nil
    }

    /// Every text line on screen, read once through `pasteVerifier`. Nil when
    /// there is no reader or the screen cannot be read.
    func screenLines() -> [String]? {
        guard let result = pasteVerifier?.describe(settleTimeoutUs: 0),
              result.ocrFailure == nil else { return nil }
        return result.elements.map(\.text)
    }

    /// The screen once Spotlight shows on it, polling for up to
    /// `pasteVerifyTimeoutUs`; nil when it never does or cannot be read. Spotlight
    /// shows when its known headings appear or the screen no longer matches
    /// `previous` (the headings are localized, and only some locales are known).
    private func spotlightScreen(replacing previous: [TapPoint]) -> ScreenDescriber.DescribeResult? {
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               screen.ocrFailure == nil,
               SpotlightDetector.isSpotlightVisible(elements: screen.elements)
                || !StructuralFingerprint.areEquivalent(previous, screen.elements) {
                return screen
            }
        }
        return nil
    }

    /// Tap the Spotlight tile showing `name`, then confirm Spotlight closed: its
    /// known headings are gone and the screen no longer matches `spotlight`,
    /// polling for up to `pasteVerifyTimeoutUs`. Nil on success, else why it failed.
    private func openTile(_ tile: TapPoint, name: String, spotlight: [TapPoint]) -> String? {
        DebugLog.log("launchApp", "tapping the '\(name)' tile Spotlight already shows")
        let point = SpotlightAppTile.tapPoint(for: tile)
        if let tapError = tap(x: point.x, y: point.y) {
            return "Failed to tap the '\(name)' tile in Spotlight: \(tapError)"
        }
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               screen.ocrFailure == nil,
               !SpotlightDetector.isSpotlightVisible(elements: screen.elements),
               !StructuralFingerprint.areEquivalent(spotlight, screen.elements) {
                return nil
            }
        }
        return "Tapped the '\(name)' tile in Spotlight but Spotlight is still open, so " +
            "'\(name)' did not launch."
    }

    /// Whether Spotlight's top result is an app, polling for up to
    /// `pasteVerifyTimeoutUs`, because results fill in after the typed text shows.
    private func returnWillOpenApp() -> Bool {
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               screen.ocrFailure == nil,
               SpotlightDetector.returnOpensApp(elements: screen.elements) {
                return true
            }
        }
        return false
    }

    /// Whether `name` shows up on screen more often than in `before`, polling
    /// for up to `pasteVerifyTimeoutUs`.
    private func spotlightShows(_ name: String, comparedTo before: [String]) -> Bool {
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let lines = screenLines(),
               PasteNeedle.appearedAgain(name, before: before, after: lines) {
                return true
            }
        }
        return false
    }
}
