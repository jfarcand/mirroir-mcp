// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Foreground check, Spotlight-launch and Spotlight-dismissal helpers shared by handleStart, handleExplore and trap recovery.
// ABOUTME: Polls with local OCR, then describes the first screen once with the client's describer.

import Foundation
import HelperLib

extension MirroirMCP {

    /// Variants returned by the launch helpers on failure. Each wraps a fully
    /// formed user-facing message; the variant tag exists for callers that
    /// want to distinguish them in logging or recovery flows.
    enum LaunchFailure: Error, Sendable {
        case launchFailed(String)
        case spotlightLingered(String)
        case foreignForeground(String)
        case undescribable(String)

        var message: String {
            switch self {
            case .launchFailed(let m), .spotlightLingered(let m),
                 .foreignForeground(let m), .undescribable(let m):
                return m
            }
        }
    }

    /// Max re-describes to wait out a home screen briefly showing after launch.
    private static let homeScreenSyncRetries = 4

    /// Spotlight-launch `appName` and wait for the overlay to dismiss, returning
    /// the first clean screen as local OCR reads it.
    ///
    /// Every poll here is bookkeeping (is Spotlight gone, is the app up yet), so
    /// it runs on `ctx.ocrDescriber` and never spends a vision call.
    static func launchAndWait(
        appName: String,
        ctx: TargetContext
    ) -> Result<ScreenDescriber.DescribeResult, LaunchFailure> {
        if let launchError = ctx.input.launchApp(name: appName) {
            return .failure(.launchFailed("Failed to launch '\(appName)': \(launchError)"))
        }
        guard var result = SpotlightDetector.waitForDismissal(describer: ctx.ocrDescriber) else {
            return .failure(.spotlightLingered(
                "'\(appName)' did not appear after launch — " +
                "Spotlight search may still be visible. Try launching the app manually first."))
        }
        // Post-launch sync: after a reset, Spotlight can dismiss onto the home
        // screen for a moment before the app finishes launching. Re-describe a
        // few times so exploration starts inside the app, not on the springboard.
        let screenHeight = Double(ctx.bridge.getWindowInfo()?.size.height ?? 898)
        var attempts = 0
        while attempts < homeScreenSyncRetries,
              AppContextDetector.detectHomeScreen(
                  elements: result.elements, screenHeight: screenHeight) {
            DebugLog.log("explore",
                "post-launch: home screen detected, waiting for '\(appName)' to foreground "
                + "(\(attempts + 1)/\(homeScreenSyncRetries))")
            usleep(EnvConfig.toolSettlingDelayUs)
            guard let next = ctx.ocrDescriber.describe() else { break }
            result = next
            attempts += 1
        }
        return .success(result)
    }

    /// `launchAndWait`, then the launched screen as the client's describer
    /// reports it: exploration describes every later screen with
    /// `ctx.describer`, so its first screen comes from the same describer.
    static func launchAndDescribe(
        appName: String,
        ctx: TargetContext
    ) -> Result<ScreenDescriber.DescribeResult, LaunchFailure> {
        launchAndWait(appName: appName, ctx: ctx).flatMap { _ in
            describeLaunched(appName: appName, ctx: ctx)
        }
    }

    /// `launchAndWait` behind a foreground guard, then the launched screen as
    /// the client's describer reports it.
    ///
    /// Never explore a screen that looks like a DIFFERENT app. A subverted
    /// launch (Spotlight over a stuck App Switcher, a failed reset that
    /// tap-selected another card) can leave a foreign app frontmost — tapping
    /// exploration anchors into someone's Mail is the failure mode this exists
    /// to stop. One relaunch retry, then abort. The guard reads local OCR.
    static func launchInForeground(
        appName: String,
        ctx: TargetContext
    ) -> Result<ScreenDescriber.DescribeResult, LaunchFailure> {
        launchAndWait(appName: appName, ctx: ctx)
            .flatMap { first -> Result<ScreenDescriber.DescribeResult, LaunchFailure> in
                guard AppForegroundDetector.looksForeign(elements: first.elements, appName: appName)
                else { return .success(first) }
                DebugLog.log("explore",
                    "foreground looks foreign to '\(appName)' — retrying launch before aborting")
                return launchAndWait(appName: appName, ctx: ctx).flatMap { retry in
                    guard AppForegroundDetector.looksForeign(elements: retry.elements, appName: appName)
                    else { return .success(retry) }
                    return .failure(.foreignForeground(
                        "Aborting explore: the foreground screen does not look like "
                        + "'\(appName)' even after relaunching. Bring the app to the "
                        + "foreground manually and retry."))
                }
            }
            .flatMap { _ in describeLaunched(appName: appName, ctx: ctx) }
    }

    /// The first exploration screen when `appName` is already frontmost, or nil
    /// when a Spotlight launch is needed.
    ///
    /// The check is bookkeeping, so it reads local OCR: the fingerprint is a
    /// Jaccard match of label text against the persisted graph, the same
    /// comparison `launchInForeground`'s guard already runs on OCR. Against a
    /// graph built by the vision describer, OCR text can score lower; that
    /// only costs a launch the check could have skipped, never a false skip.
    /// On a match the screen is described once with the client's describer,
    /// so a cold start spends exactly one client describe either way.
    static func describeIfAlreadyForeground(
        appName: String,
        ctx: TargetContext,
        logTag: String
    ) -> Result<ScreenDescriber.DescribeResult, LaunchFailure>? {
        guard let current = ctx.ocrDescriber.describe(),
              case .alreadyForeground(let similarity) = AppForegroundDetector.detect(
                  elements: current.elements, appName: appName)
        else { return nil }
        DebugLog.log(logTag, "already in '\(appName)' "
            + "(root similarity \(String(format: "%.2f", similarity))) — skipping Spotlight launch")
        return describeLaunched(appName: appName, ctx: ctx)
    }

    /// Describe the app's first screen with the client's describer.
    private static func describeLaunched(
        appName: String,
        ctx: TargetContext
    ) -> Result<ScreenDescriber.DescribeResult, LaunchFailure> {
        guard let described = ctx.describer.describe() else {
            return .failure(.undescribable(
                "'\(appName)' is in the foreground, but its first screen could not be "
                + "described. Is the '\(ctx.name)' window visible?"))
        }
        return .success(described)
    }
}
