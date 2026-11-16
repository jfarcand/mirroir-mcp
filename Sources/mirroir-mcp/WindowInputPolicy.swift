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
// ABOUTME: Decides whether iPhone Mirroring input goes to its window by SkyLight record or through HID clicks.
// ABOUTME: Window records are used only on the macOS versions they were measured on, unless the windowInput setting says otherwise.

import Foundation
import HelperLib

/// Whether taps, keys and swipes are posted to the mirror's window by SkyLight
/// record (the user's front app stays in front) or sent as HID input (iPhone
/// Mirroring comes to the front first).
///
/// The record layout `SkyLightWindowPoster` writes is private to the window
/// server. On a macOS it was not measured on, the window server can accept a
/// record and drop it, so every tap reports success and nothing reaches the
/// iPhone (jfarcand/mirroir-mcp#84, macOS 27.3). HID input is the path every
/// macOS delivers, so it is the default there.
enum WindowInputPolicy {

    /// The newest macOS major version window records were measured on.
    static let lastMeasuredMacOSMajor = 26

    /// The `windowInput` values: `auto` follows the macOS version, `on` and
    /// `off` force one path.
    enum Mode: String, CaseIterable {
        case auto, on, off
    }

    /// The path chosen and why, as `doctor` and the debug log say it.
    struct Decision: Equatable {
        let usesWindow: Bool
        let reason: String
    }

    /// The decision for a `windowInput` setting on a macOS major version.
    /// An unknown setting value behaves like `auto` and says so.
    static func decide(setting: String, macOSMajor: Int) -> Decision {
        let raw = setting.lowercased()
        switch Mode(rawValue: raw) {
        case .on:
            return Decision(usesWindow: true, reason: "windowInput is on")
        case .off:
            return Decision(usesWindow: false, reason: "windowInput is off")
        case .auto, nil:
            let prefix = raw.isEmpty || Mode(rawValue: raw) != nil
                ? "" : "windowInput \"\(setting)\" is not auto, on or off; using auto. "
            if macOSMajor <= lastMeasuredMacOSMajor {
                return Decision(usesWindow: true,
                                reason: prefix + "measured on macOS \(macOSMajor)")
            }
            return Decision(usesWindow: false,
                            reason: prefix + "window input is not measured on macOS \(macOSMajor); "
                                + "set windowInput to on to try it")
        }
    }

    /// The decision for this Mac and its settings.
    static var live: Decision {
        decide(setting: EnvConfig.windowInput,
               macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// The window poster to build input with: the live SkyLight poster when
    /// this Mac uses window input, nil for the HID path.
    static var livePoster: SkyLightWindowPoster? {
        let decision = live
        DebugLog.log("window-input", "\(decision.usesWindow ? "window records" : "HID"): \(decision.reason)")
        return decision.usesWindow ? SkyLightWindowPoster.live : nil
    }
}
