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

    /// Lower-cased fragments of lock-screen and passcode text.
    let lockScreen: [String]

    /// The data file's name inside an element pattern directory.
    static let fileName = "system-phrases.md"

    /// The section whose bullets are lock-screen fragments.
    static let lockScreenSection = "## Lock Screen"

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
        return SystemPhrases(lockScreen: [])
    }

    /// The bullets under `## Lock Screen`, lower-cased, in file order.
    static func parse(content: String) -> SystemPhrases {
        var phrases: [String] = []
        var inSection = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") {
                inSection = trimmed == lockScreenSection
                continue
            }
            guard inSection, trimmed.hasPrefix("- ") else { continue }
            let phrase = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
            if !phrase.isEmpty { phrases.append(phrase) }
        }
        return SystemPhrases(lockScreen: phrases)
    }
}
