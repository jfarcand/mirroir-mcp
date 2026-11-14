// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Presses one of iPhone Mirroring's View menu commands (Home Screen, App Switcher, Spotlight) honestly.
// ABOUTME: Fails when the iPhone could not have received it; Home is pressed again while Spotlight or the old screen shows.

import Foundation
import HelperLib

/// A View menu command of the iPhone Mirroring app.
///
/// The menu item answers even while the session is paused ("Connection
/// Paused", "iPhone in Use"): the Mac app takes the click, but nothing reaches
/// the iPhone. So the session is freed first, the way pointing input frees it,
/// and the command succeeds only when the session is still connected after it.
enum MirroringMenuCommand: String, CaseIterable {
    case homeScreen = "Home Screen"
    case appSwitcher = "App Switcher"
    case spotlight = "Spotlight"

    /// The menu the commands live in.
    static let menu = "View"

    /// The tool that presses it, which names it in messages.
    var toolName: String {
        switch self {
        case .homeScreen: return "press_home"
        case .appSwitcher: return "press_app_switcher"
        case .spotlight: return "spotlight"
        }
    }

    /// Press the command on `bridge`'s window.
    ///
    /// - Returns: nil when the command was pressed on a connected session, else
    ///   why it was not, or why the iPhone did not receive it.
    func press(bridge: any WindowBridging, input: any InputProviding) -> String? {
        guard let menuBridge = bridge as? (any MenuActionCapable) else {
            return "Target '\(bridge.targetName)' does not support \(toolName)"
        }
        if let refusal = input.ensureConnected(tag: toolName) {
            return refusal
        }
        guard menuBridge.triggerMenuAction(menu: Self.menu, item: rawValue) else {
            return "Failed to press \(rawValue). Is '\(bridge.targetName)' running?"
        }
        let state = bridge.getState()
        guard state == .connected else {
            return "The \(rawValue) command was sent, but '\(bridge.targetName)' is \(state), "
                + "so the iPhone did not receive it. Describe the screen before the next action."
        }
        return nil
    }

    /// What pressing Home did.
    enum HomePress: Equatable {
        /// Home took effect: the Home Screen shows, the screen changed away
        /// from what it was, or the screen cannot be read to tell.
        case reached
        /// Every press left the screen as it was. Pressing Home on the Home
        /// Screen changes nothing, and the Home Screen is only recognized by
        /// its search pill in the languages `system-phrases.md` lists, so this
        /// is most likely the Home Screen, unconfirmed.
        case unchanged(presses: Int)
        /// Home could not be pressed, or Spotlight still shows after it.
        case failed(String)

        /// The text the tool and the step report for an outcome that is not a failure.
        var report: String {
            switch self {
            case .reached:
                return "Pressed Home — navigated to home screen"
            case .unchanged(let presses):
                return "Pressed Home \(presses) times and the screen did not change, "
                    + "so it was most likely the Home Screen already. Describe the screen to confirm."
            case .failed(let error):
                return error
            }
        }
    }

    /// Press Home and confirm it left the screen it was on.
    ///
    /// Two things can keep the Home Screen away after the menu item answers:
    /// after an app opened from Spotlight, iOS answers Home with Spotlight
    /// again, still holding the old query ("Notes — Ouvrir", XR, iOS 26), and
    /// a press can be dropped, leaving the app in front (same phone,
    /// 2026-11-13). So the settled screen is read before and after each press,
    /// and Home is pressed again while the screen shows Spotlight or has not
    /// changed. The Home Screen's search pill ends it at once, so pressing
    /// Home on the Home Screen is one press.
    static func pressHome(bridge: any WindowBridging, input: any InputProviding,
                          describer: any ScreenDescribing) -> HomePress {
        let height = Double(bridge.getWindowInfo()?.size.height ?? 0)
        var before = describer.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs)?.elements
        var spotlightShows = false
        for attempt in 1 ... homePressAttempts {
            if let error = homeScreen.press(bridge: bridge, input: input) { return .failed(error) }
            guard let after = describer.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs)?.elements else {
                return .reached
            }
            if SpotlightDetector.isHomeScreenVisible(elements: after, windowHeight: height) { return .reached }
            spotlightShows = SpotlightDetector.isSpotlightVisible(elements: after)
            if !spotlightShows {
                guard let previous = before, StructuralFingerprint.areEquivalent(previous, after) else {
                    return .reached
                }
            }
            DebugLog.log(homeScreen.toolName, "after Home press \(attempt), "
                + (spotlightShows ? "Spotlight still shows" : "the screen did not change"))
            before = after
        }
        guard spotlightShows else { return .unchanged(presses: homePressAttempts) }
        return .failed("Home was pressed \(homePressAttempts) times and Spotlight still shows. "
            + "Describe the screen before the next action.")
    }

    /// Home presses made while Home has not taken effect: a dropped press and
    /// a Spotlight brought back can both happen in one call.
    static let homePressAttempts = 3
}
