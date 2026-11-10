// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The words iOS itself draws on its system screens, read from the system-phrases.md pattern data file.
// ABOUTME: The iPhone's language is unknown to the Mac, so the file is a union across languages that anyone can extend.

import Foundation
import HelperLib

/// Words iOS draws on system screens, read from `system-phrases.md` in the
/// element pattern paths.
///
/// These are texts on the iPhone, in the iPhone's language, which the Mac
/// cannot know. They are pattern data, one bullet per phrase as read on a
/// phone, not a table in the binary. Text the iPhone Mirroring app draws on
/// the Mac is a different matter: `InterstitialPhrases` takes that from
/// Apple's own strings.
struct SystemPhrases: Sendable, Equatable {

    /// A section of the file: its `##` heading names it.
    enum Section: String, CaseIterable, Sendable {
        /// Fragments of lock-screen and passcode text.
        case lockScreen = "Lock Screen"
        /// The heading above Spotlight's top result.
        case spotlightTopHit = "Spotlight Top Hit"
        /// The whole word the search field adds when Return would open an app.
        case spotlightOpen = "Spotlight Open"
        /// Other fragments shown only while Spotlight covers the screen.
        case spotlightOverlay = "Spotlight Overlay"
        /// The whole label of the Home Screen's search pill.
        case homeSearchPill = "Home Search Pill"
        /// Whole system-alert button labels, most conservative first.
        case alertDismiss = "Alert Dismiss"
        /// Fragments of a system alert's title, `.*` standing for any text.
        case alertTitle = "Alert Title"
    }

    /// Each section's bullets, folded with `fold`, in file order.
    let sections: [Section: [String]]

    /// The phrases of `section`, none when the file lacks it.
    func phrases(_ section: Section) -> [String] { sections[section] ?? [] }

    var lockScreen: [String] { phrases(.lockScreen) }

    /// No phrases at all: what runs when no file is found.
    static let empty = SystemPhrases(sections: [:])

    /// The data file's name inside an element pattern directory.
    static let fileName = "system-phrases.md"

    /// The phrases this process runs with, read once.
    static let live = load()

    /// Every path the file is looked up at, in resolution order.
    static func candidates() -> [String] {
        ComponentLoader.searchPaths().map { $0.appendingPathComponent(fileName).path }
    }

    /// The phrases in the first candidate that exists. With no file anywhere
    /// there are no phrases, and the paths that were tried are logged.
    static func load(candidates: [String] = candidates()) -> SystemPhrases {
        for candidate in candidates {
            guard let content = try? String(contentsOfFile: candidate, encoding: .utf8) else { continue }
            return parse(content: content)
        }
        DebugLog.log("patterns", "no \(fileName) in \(candidates.joined(separator: ", "))")
        return .empty
    }

    /// Text as the file and the screen are compared: lower-cased, with the
    /// curly apostrophe iOS draws read as a straight one.
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
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
