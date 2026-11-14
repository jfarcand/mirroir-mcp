// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Opens an app from its Home Screen icon when Spotlight does not take the typed name, on the page Home shows.
// ABOUTME: Only a label equal to the app's name is tapped, and the launch counts once the Home Screen is gone.

import CoreGraphics
import Foundation
import HelperLib

extension InputSimulation {

    /// Open `name` from its Home Screen icon. Goes Home, which closes
    /// Spotlight, and reads the page Home shows. No page is turned: a touch
    /// drag across the icon grid is a hold-and-move to iOS and can rearrange
    /// icons into folders (measured on the XR, 2026-11-12). Nil once the app
    /// opened, else why it did not.
    func launchFromHomeScreen(name: String) -> String? {
        guard let menuBridge = bridge as? (any MenuActionCapable),
              let window = bridge.getWindowInfo()?.size else {
            return "the Home Screen could not be reached"
        }
        let height = Double(window.height)
        // Home closes Spotlight too. The Spotlight menu item is not pressed to
        // close it: it toggles, and a Home Screen read as Spotlight (carnet#70)
        // would be covered by Spotlight instead.
        let homeItem = MirroringMenuCommand.homeScreen.rawValue
        guard menuBridge.triggerMenuAction(menu: MirroringMenuCommand.menu, item: homeItem) else {
            return "the Home Screen menu item could not be pressed"
        }
        guard let page = settledScreen() else { return "the Home Screen could not be read" }
        guard SpotlightDetector.isHomeScreenVisible(elements: page, windowHeight: height) else {
            return "the Home Screen did not show (its search pill was not found)"
        }
        guard let icon = HomeScreenAppIcon.label(for: name, in: page) else {
            DebugLog.log("launchApp", "no Home Screen icon labeled '\(name)' on the page Home shows")
            return "no icon is labeled exactly '\(name)' on the Home Screen page that shows. Other pages "
                + "are not turned to, and apps in a folder, in the Dock (its icons have no name) or only "
                + "in the App Library are not searched"
        }
        return openIcon(icon, name: name, home: page, windowHeight: height)
    }

    /// The screen once it has settled, as elements; nil when it cannot be read.
    private func settledScreen() -> [TapPoint]? {
        guard let screen = pasteVerifier?.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs),
              screen.ocrFailure == nil else { return nil }
        return screen.elements
    }

    /// Tap the icon `label` names, then confirm the Home Screen is gone: its
    /// search pill no longer shows and the screen no longer matches `home`,
    /// polling for up to `pasteVerifyTimeoutUs`. Nil on success.
    private func openIcon(_ label: TapPoint, name: String, home: [TapPoint], windowHeight: Double) -> String? {
        DebugLog.log("launchApp", "tapping the '\(name)' icon on the Home Screen")
        if let tapError = tap(x: label.tapX, y: label.tapY) {
            return "the '\(name)' icon could not be tapped: \(tapError)"
        }
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        let attempts = max(1, Int(EnvConfig.pasteVerifyTimeoutUs / poll))
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(poll) }
            if let screen = pasteVerifier?.describe(settleTimeoutUs: 0),
               screen.ocrFailure == nil,
               !SpotlightDetector.isHomeScreenVisible(elements: screen.elements, windowHeight: windowHeight),
               !StructuralFingerprint.areEquivalent(home, screen.elements) {
                DebugLog.log("launchApp", "launched '\(name)' from its Home Screen icon")
                return nil
            }
        }
        return "the '\(name)' icon was tapped but the Home Screen still shows"
    }
}
