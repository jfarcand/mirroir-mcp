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
// ABOUTME: The words iOS itself draws on its system screens, parsed from Resources/system-phrases.md compiled into the binary.
// ABOUTME: The iPhone's language is unknown to the Mac, so the file is a union across languages that anyone can extend.

import Foundation
import HelperLib

/// Words iOS draws on system screens, from `Resources/system-phrases.md`.
///
/// These are texts on the iPhone, in the iPhone's language, which the Mac
/// cannot know. They are data, one bullet per phrase as read on a phone,
/// kept in a Markdown file rather than in Swift. The file is compiled into
/// the executable: launch_app, the alert detector and the lock-screen check
/// need it on every install, including one that copies the binary alone and
/// has no skills checkout. Text the iPhone Mirroring app draws on the Mac is
/// a different matter: `InterstitialPhrases` takes that from Apple's own strings.
struct SystemPhrases: Sendable, Equatable {

    /// A section of the file: its `##` heading names it.
    enum Section: String, CaseIterable, Sendable {
        /// Fragments of lock-screen and passcode text.
        case lockScreen = "Lock Screen"
        /// The heading above Spotlight's top result.
        case spotlightTopHit = "Spotlight Top Hit"
        /// The whole word the search field adds when Return would open an app.
        case spotlightOpen = "Spotlight Open"
        /// The whole label of an App Store result's button for an app not installed.
        case spotlightStoreButton = "Spotlight Store Button"
        /// Fragments of a turn-by-turn navigation screen, `.*` standing for any text.
        case navigation = "Navigation"
        /// Other fragments shown only while Spotlight covers the screen.
        case spotlightOverlay = "Spotlight Overlay"
        /// The whole label of the Home Screen's search pill.
        case homeSearchPill = "Home Search Pill"
        /// Whole system-alert button labels, most conservative first.
        case alertDismiss = "Alert Dismiss"
        /// Fragments of a system alert's title, `.*` standing for any text.
        case alertTitle = "Alert Title"
        /// The Settings app's name, which set_network opens.
        case settingsApp = "Settings App"
        /// The Settings row holding the Airplane Mode switch.
        case settingsAirplaneRow = "Settings Airplane Row"
        /// The Settings row that opens the Wi-Fi page.
        case settingsWiFiRow = "Settings Wi-Fi Row"
        /// The row on the Wi-Fi page holding the Wi-Fi switch.
        case settingsWiFiSwitch = "Settings Wi-Fi Switch"
        /// The Settings row that opens the cellular page.
        case settingsCellularRow = "Settings Cellular Row"
        /// The row on the cellular page holding the cellular data switch.
        case settingsCellularSwitch = "Settings Cellular Switch"
    }

    /// Each section's bullets, folded with `fold`, in file order.
    let sections: [Section: [String]]

    /// The phrases of `section`, none when the file lacks it.
    func phrases(_ section: Section) -> [String] { sections[section] ?? [] }

    var lockScreen: [String] { phrases(.lockScreen) }

    /// The file as compiled into the binary.
    static var shippedContent: String { String(decoding: PackageResources.system_phrases_md, as: UTF8.self) }

    /// The phrases this process runs with, parsed once.
    static let live = parse(content: shippedContent)

    /// Text as the file and the screen are compared: lower-cased, with the
    /// curly apostrophe iOS draws read as a straight one.
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Whether folded `text` contains `pattern`, where a `.*` in the pattern
    /// stands for any text between its two parts.
    static func matches(_ text: String, pattern: String) -> Bool {
        let parts = pattern.components(separatedBy: ".*")
        guard parts.count == 2 else { return text.contains(pattern) }
        guard let first = text.range(of: parts[0]) else { return false }
        return text[first.upperBound...].contains(parts[1])
    }

    /// The bullets under each known `##` heading, folded, in file order.
    /// Bullets under any other heading are ignored.
    static func parse(content: String) -> SystemPhrases {
        var sections: [Section: [String]] = [:]
        var current: Section?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") {
                current = Section(rawValue: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let section = current, trimmed.hasPrefix("- ") else { continue }
            let phrase = fold(trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces))
            if !phrase.isEmpty { sections[section, default: []].append(phrase) }
        }
        return SystemPhrases(sections: sections)
    }
}
