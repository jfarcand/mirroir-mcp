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
// ABOUTME: Reads Mac Spotlight's result rows and keyboard shortcut for launching an iPhone app from the Mac.
// ABOUTME: A row is the iPhone app only when it reads "<name>.app — …iPhone…"; a Mac app of that name reads "<name>.app".

import Foundation

public enum MacSpotlightMatch {

    /// Whether a result row's texts name the iPhone app `name`. macOS 27 shows
    /// an iPhone app as "Waze.app — From iPhone"; a Mac app of the same name
    /// ("Strava.app", a Chrome web app) has no suffix and is never taken. The
    /// suffix is localized, and "iPhone" is in every localization of it. The
    /// name must match whole, ignoring case: "Maps" does not take "Google Maps".
    public static func isIPhoneApp(rowTexts: [String], named name: String) -> Bool {
        let wanted = normalized(name) + ".app"
        return rowTexts.contains { text in
            let parts = normalized(text).components(separatedBy: " — ")
            return parts.count == 2
                && parts[0].caseInsensitiveCompare(wanted) == .orderedSame
                && parts[1].contains("iPhone")
        }
    }

    /// The text without the invisible formatting marks Spotlight wraps names
    /// in (bidi isolates, word joiners), trimmed.
    static func normalized(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The keyboard shortcut that shows Mac Spotlight, as System Settings > Keyboard
/// > Keyboard Shortcuts sets it ("Show Spotlight search", symbolic hot key 64).
public struct SpotlightHotkey: Equatable, Sendable {
    /// The virtual key code (49 is Space).
    public let keyCode: UInt16
    /// The modifier flags, in CGEventFlags bits (1048576 is Command).
    public let modifierFlags: UInt64

    public init(keyCode: UInt16, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    /// Command-Space, the macOS default.
    public static let commandSpace = SpotlightHotkey(keyCode: 49, modifierFlags: 1_048_576)

    /// The shortcut from the `AppleSymbolicHotKeys` dictionary of
    /// `com.apple.symbolichotkeys`. Nil when the user turned it off; the default
    /// when the dictionary has no entry for it (never changed) or one this
    /// cannot read.
    public static func from(symbolicHotKeys: [String: Any]?) -> SpotlightHotkey? {
        guard let entry = symbolicHotKeys?["64"] as? [String: Any] else { return .commandSpace }
        if let enabled = entry["enabled"] as? Int, enabled == 0 { return nil }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              parameters[1] >= 0, parameters[1] < Int(UInt16.max), parameters[2] >= 0 else {
            return .commandSpace
        }
        return SpotlightHotkey(keyCode: UInt16(parameters[1]), modifierFlags: UInt64(parameters[2]))
    }

    /// The shortcut this Mac uses now.
    public static func configured() -> SpotlightHotkey? {
        from(symbolicHotKeys: UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys"))
    }
}
