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
// ABOUTME: launch_app's first try on iPhone Mirroring: open the app from Mac Spotlight, then confirm the iPhone screen changed.
// ABOUTME: A miss (no "From iPhone" row, no change on the iPhone) falls back to the iPhone's Spotlight; a panel left open stops it.

import Foundation
import HelperLib

/// What launch_app's Mac Spotlight step did.
enum MacSpotlightStep: Equatable {
    /// The app opened on the iPhone.
    case launched
    /// Not opened from the Mac; the iPhone's Spotlight goes next.
    case fallBack
    /// Not opened, and Mac Spotlight's panel stayed up: the keys the
    /// iPhone's Spotlight needs would go to it, so the launch stops here.
    case refused(String)
}

extension InputSimulation {

    /// Open `name` from Mac Spotlight's "From iPhone" row, and wait up to
    /// `macSpotlightOpenTimeoutUs` for the iPhone screen to change: launched
    /// once it has. Falls back when there is no Mac launcher, the screen
    /// cannot be read before and after (nothing could confirm the launch),
    /// the row is not there (an exact name only: a Mac app of the same name is
    /// never taken), or the screen stays the same, as it does when the app was
    /// already open.
    func launchThroughMacSpotlight(name: String) -> MacSpotlightStep {
        guard let macLauncher, let reader = pasteVerifier,
              let before = reader.describe(settleTimeoutUs: EnvConfig.frameSettleTimeoutUs),
              before.ocrFailure == nil else { return .fallBack }
        switch macLauncher.open(appNamed: name) {
        case .skipped(let reason):
            DebugLog.log("launchApp", "Mac Spotlight not used: \(reason)")
            return .fallBack
        case .panelLeftOpen(let reason):
            DebugLog.log("launchApp", "Mac Spotlight not used and its panel stayed open: \(reason)")
            return .refused("'\(name)' was not launched: \(reason), and the Mac's Spotlight panel did not "
                + "close, so nothing was typed on the iPhone (the panel would take the keys). Close it on "
                + "the Mac (Escape), then call launch_app again.")
        case .clicked:
            break
        }
        let poll = max(1, EnvConfig.pasteVerifyPollUs)
        var waited: UInt32 = 0
        while waited < EnvConfig.macSpotlightOpenTimeoutUs {
            usleep(poll)
            waited += poll
            if let screen = reader.describe(settleTimeoutUs: 0), screen.ocrFailure == nil,
               !StructuralFingerprint.areEquivalent(before.elements, screen.elements) {
                DebugLog.log("launchApp", "opened '\(name)' from Mac Spotlight")
                return .launched
            }
        }
        DebugLog.log("launchApp", "clicked '\(name)' in Mac Spotlight but the iPhone screen did not change; "
            + "searching the iPhone's Spotlight")
        return .fallBack
    }
}
