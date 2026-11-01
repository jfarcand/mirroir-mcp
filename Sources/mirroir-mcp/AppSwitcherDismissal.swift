// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared force-quit flow for iPhone Mirroring — launch via Spotlight, locate the card via OCR intersection, drag to dismiss, return home.
// ABOUTME: Single source of truth used by reset_app (MCP tool), compiled-skill replay, and explore reset_before_explore so all paths fail closed identically.

import CoreGraphics
import Foundation
import HelperLib

/// AppSwitcherDismissal — orchestration helper that force-quits an iPhone
/// app via the App Switcher.
///
/// Steps:
/// 1. Launch the app (resolves localized display name via Spotlight)
/// 2. Capture foreground OCR (fingerprint)
/// 3. Open App Switcher
/// 4. Locate the just-launched card by its switcher label, else via OCR-intersection (`AppSwitcherCardLocator`), once two reads agree on where it rests
/// 5. Drag the card upward to dismiss
/// 6. Return to the home screen, retrying once if iOS lands on Spotlight
///
/// The flow fails **closed** at every step: if launch fails, OCR is empty, or
/// the card cannot be located, the function returns an error message and does
/// not blindly drag at a hard-coded fraction. The `reset_app` tool, compiled
/// `reset_app` step replay, and `forceQuitBeforeExplore` lifecycle hook all
/// share this single implementation.
enum AppSwitcherDismissal {

    /// Force-quit `appName`. Returns `nil` on success, an error message on
    /// any failure step. Caller is responsible for the surrounding tool
    /// response/StepResult shape — this helper is action-only.
    ///
    /// Preconditions:
    /// - `bridge` and `input` operate on the same iPhone Mirroring window
    /// - `menuBridge` and `bridge` refer to the same target
    /// - `describer` reads from the same window
    static func forceQuit(
        appName: String,
        input: any InputProviding,
        bridge: any WindowBridging,
        menuBridge: any MenuActionCapable,
        describer: any ScreenDescribing
    ) -> String? {
        // 1. Launch — handles localized app names via Spotlight.
        if let error = input.launchApp(name: appName) {
            return "Failed to launch '\(appName)': \(error)"
        }
        usleep(EnvConfig.toolSettlingDelayUs)

        // 2. Capture foreground OCR — fingerprint for card matching. A cold
        // launch shows a near-textless splash screen first; a fingerprint taken
        // there is too sparse to match the card later (the locator requires
        // minimum matched-text evidence), so wait for the UI to render real
        // content before accepting the capture. Warm launches pass on the
        // first attempt.
        var foregroundOcr: ScreenDescriber.DescribeResult?
        for attempt in 1 ... EnvConfig.appForegroundReadyRetries {
            if let capture = describer.describe(),
               capture.elements.count >= EnvConfig.appForegroundReadyMinElements {
                foregroundOcr = capture
                break
            }
            DebugLog.log("reset_app",
                "foreground OCR sparse (attempt \(attempt)) — waiting for app to render")
            usleep(EnvConfig.toolSettlingDelayUs * 2)
        }
        guard let appOcr = foregroundOcr, !appOcr.elements.isEmpty else {
            return "Failed to capture foreground OCR for '\(appName)' — app never rendered content"
        }

        // 3. Open App Switcher, then wait out the card entry animation: the
        // just-foregrounded app's card slides from center to its resting slot
        // right of center. OCR captured mid-slide aims the dismiss drag at a
        // position the card has already left (see appSwitcherOpenSettleUs).
        guard menuBridge.triggerMenuAction(menu: "View", item: "App Switcher") else {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return "Failed to open App Switcher. Is '\(bridge.targetName)' running?"
        }
        usleep(EnvConfig.appSwitcherOpenSettleUs)

        // 4–5. Locate the matching card by its switcher label, else by OCR
        // intersection, once two reads agree on where it rests. Fail closed when
        // it cannot be located (no match OR an ambiguous one) or never holds
        // still — never drag a guess, or we quit the wrong app.
        let windowSize = bridge.getWindowInfo()?.size ?? CGSize(width: 410, height: 898)
        let cardX: Double
        switch locateRestingCard(
            appName: appName, appElements: appOcr.elements,
            describer: describer, windowSize: windowSize) {
        case .success(let x):
            cardX = x
        case .failure(let failure):
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return failure.message(appName: appName)
        }
        DebugLog.log("reset_app", "located '\(appName)' card at x=\(Int(cardX))")

        // 6. Drag the card upward. The end point must stay inside the mirrored
        // content: window-relative y=0 is the macOS title-bar edge, and a drag
        // released there is a cancelled touch to iOS — the card snaps back
        // (observed on-device: to-y=0 never dismissed, to-y=80 did).
        let cardY = Double(windowSize.height) * EnvConfig.appSwitcherCardYFraction
        let toY = max(EnvConfig.appSwitcherSwipeTopMarginPt, cardY - EnvConfig.appSwitcherSwipeDistance)
        if let error = input.drag(
            fromX: cardX, fromY: cardY,
            toX: cardX, toY: toY,
            durationMs: EnvConfig.appSwitcherSwipeDurationMs
        ) {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return "Failed to swipe app card: \(error)"
        }
        // 6b. Verify the card actually dismissed. The drag posts successfully
        // (CGEvent=OK) even when the flick fails to fling the card off-screen,
        // so re-OCR the switcher after the re-layout settles. "Still present"
        // requires BOTH signals: the content-fingerprint re-locates (stray
        // token overlap alone kept reporting long-dismissed cards as present)
        // AND the switcher's own app-name label for this app is still rendered
        // in the label band — every genuinely stuck card shows its label;
        // every observed false positive lacked it.
        usleep(EnvConfig.appSwitcherOpenSettleUs)
        if let postDrag = describer.describe(),
           AppSwitcherCardLocator.locateCard(
               appName: appName,
               appElements: appOcr.elements,
               switcherElements: postDrag.elements,
               windowSize: windowSize
           ) != nil,
           AppSwitcherCardLocator.labelBandContains(
               appName: appName,
               switcherElements: postDrag.elements,
               windowHeight: Double(windowSize.height)
           ) {
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
            return "Swiped '\(appName)' card but it is still in the App Switcher — dismissal did not take"
        }

        // 7. Return to home screen.
        //
        // After a successful card-dismiss drag, iOS occasionally interprets
        // the next View > Home Screen menu trigger as a Spotlight invocation
        // instead of a home gesture — landing the user on Spotlight with
        // the previous query still typed. Verify the result by OCR and retry
        // once when Spotlight is detected; the second trigger reliably
        // reaches home.
        _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
        usleep(EnvConfig.toolSettlingDelayUs)
        if let postHomeOcr = describer.describe(),
           SpotlightDetector.isSpotlightVisible(elements: postHomeOcr.elements) {
            DebugLog.log("reset_app", "Home Screen menu landed on Spotlight, retrying once")
            _ = menuBridge.triggerMenuAction(menu: "View", item: "Home Screen")
        }
        return nil
    }
    /// Why the card to drag could not be pinned down.
    enum CardLocateFailure: Error, Equatable {
        /// The switcher screen could not be read.
        case unreadable
        /// The switcher showed no text at all.
        case empty
        /// No read located the card unambiguously.
        case notFound
        /// The card was located on every read but never at the same place twice.
        case neverSettled

        func message(appName: String) -> String {
            switch self {
            case .unreadable:
                return "Failed to capture App Switcher screen for verification"
            case .empty:
                return "App Switcher appears empty — no app cards detected"
            case .notFound:
                return "Cannot locate '\(appName)' card in App Switcher unambiguously — " +
                    "refusing to drag (would risk quitting the wrong app)"
            case .neverSettled:
                return "'\(appName)' card never came to rest in the App Switcher — " +
                    "refusing to drag (would risk quitting the wrong app)"
            }
        }
    }

    /// Most switcher reads spent waiting for the card to hold still.
    static let maxRestReads = 4

    /// Largest shift, in points, between two reads of the card that still
    /// counts as the card at rest.
    static let restTolerancePt = 8.0

    /// The X of `appName`'s card once two consecutive reads, `pauseUs` apart,
    /// locate it at the same place. The card slides from center to its resting
    /// slot after the switcher opens, and the mirrored frame lags the device:
    /// one read can show the card where it was, and a drag aimed there lands on
    /// the neighboring card and quits the wrong app.
    static func locateRestingCard(
        appName: String,
        appElements: [TapPoint],
        describer: any ScreenDescribing,
        windowSize: CGSize,
        pauseUs: UInt32 = EnvConfig.stepSettlingDelayMs * 1000,
        sleep: (UInt32) -> Void = { usleep($0) }
    ) -> Result<Double, CardLocateFailure> {
        var previous: Double?
        var failure = CardLocateFailure.notFound
        for read in 0 ..< maxRestReads {
            if read > 0 { sleep(pauseUs) }
            guard let screen = describer.describe() else { return .failure(.unreadable) }
            guard !screen.elements.isEmpty else { return .failure(.empty) }
            guard let x = AppSwitcherCardLocator.locateCard(
                appName: appName, appElements: appElements,
                switcherElements: screen.elements, windowSize: windowSize) else {
                previous = nil
                failure = .notFound
                continue
            }
            DebugLog.log("reset_app", "read \(read + 1): '\(appName)' card at x=\(Int(x))")
            if let previous, abs(x - previous) <= restTolerancePt { return .success(x) }
            previous = x
            failure = .neverSettled
        }
        return .failure(failure)
    }
}
