// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Data model and parser for APP.md files — human-authored app structure descriptions.
// ABOUTME: Provides hints, skip lists, and obstacle rules to guide exploration sessions.

import Foundation
import HelperLib

/// A human-authored description of an iOS app's structure, navigation patterns,
/// and known obstacles. Loaded from APP.md files and injected into exploration
/// sessions to guide the AI with domain knowledge the developer already has.
struct AppDescription: Sendable {
    /// App name for matching (case-insensitive). From front matter `app:` field.
    let appName: String
    /// APP.md schema major from the `version:` front-matter field, gated by
    /// ``AppMdSchemaVersion``. Required: an APP.md without it is refused.
    let schemaVersion: Int
    /// Optional locale (e.g. "fr_CA", "en_US"). When set, only matches that locale.
    let locale: String?
    /// Optional archetype name referencing a screen recipe (e.g. "dashboard", "social-feed").
    /// When set, bypasses recipe auto-detection and uses this recipe directly.
    let archetype: String?
    /// Optional playability class from the `playable:` front-matter field:
    /// "observe-only", "single-control", or "pc-controls". Absent means an
    /// ordinary, explorable app. Anything other than "observe-only" marks a
    /// driveable game, which the explorer refuses to BFS — a game scene is
    /// driven by a `kind: game` skill, not by autonomous exploration. Nil for
    /// an ordinary app; only APP.md files that declare `playable:` set it.
    let playable: String?
    /// Whether to force-quit the app via App Switcher before launching for exploration.
    let resetBeforeExplore: Bool
    /// Obstacle handling mode: "auto", "hint", or "off".
    let obstacleMode: ObstacleMode
    /// Free-form sections concatenated as AI context (Structure, tab descriptions, Tips).
    let context: String
    /// Parsed obstacle rules: when trigger text appears, tap the action text.
    let obstacles: [ObstacleRule]
    /// Element text patterns that the explorer must never tap.
    let skipElements: [String]
    /// Credential key-value pairs (supports ${VAR} substitution).
    let credentials: [String: String]
    /// Raw exploration hints for inclusion in generated skills.
    let hints: [String]
    /// Tab names extracted from the Structure section (e.g. ["Pour toi", "Explorer", "Profil"]).
    /// The explorer uses these to find and tap tab bar elements by text match,
    /// bypassing component detection for apps with non-standard UI.
    let tabs: [String]
    /// Optional geometric hint for the tab bar's orientation and edge.
    /// When present, `TabTargetInjector` synthesizes evenly-spaced tab anchors
    /// along the declared axis/edge when text matching fails (icon-only bars).
    let tabLayout: TabLayout?
    /// Tabs whose subtree deserves exploration budget before sibling breadth
    /// (from a `## Deep Tabs` section, e.g. a profile tab that gates the
    /// settings chain). Screens reached through these tabs are dequeued from
    /// the frontier ahead of FIFO order; empty list keeps pure FIFO.
    let deepTabs: [String]
    /// Optional declarative scene graph extracted from `## Simulator …` sections.
    /// Present once the app has been ported to the FakeMirroring simulator;
    /// nil for guidance-only APP.md files that haven't been ported yet.
    let simulator: SimulatorSpec?

    /// Whether the explorer may BFS this app. True for ordinary apps (no
    /// `playable:` declared) and for `observe-only` apps; false for any other
    /// `playable` class (`single-control`, `pc-controls`, or an unrecognized
    /// value — fail safe toward never driving a game).
    var allowsExploration: Bool {
        (playable ?? "observe-only") == "observe-only"
    }
}

/// Geometric hint for the tab bar layout. Defaults to `.horizontal` bottom-edge
/// (standard iOS convention) when omitted.
struct TabLayout: Sendable {
    let orientation: TabOrientation
    let edge: TabEdge
}

/// Axis along which tabs are arranged.
enum TabOrientation: String, Sendable {
    /// Tabs stacked in a row (X varies, Y ≈ constant). Standard iOS bottom tab bar.
    case horizontal
    /// Tabs stacked in a column (Y varies, X ≈ constant). Side rails, landscape
    /// camera control columns, iPad sidebars.
    case vertical
}

/// Which edge of the window the tab bar hugs.
enum TabEdge: String, Sendable {
    case top, bottom, left, right
}

/// How obstacle rules from APP.md are applied during exploration.
enum ObstacleMode: String, Sendable {
    /// Automatically dismiss matching obstacles (default).
    case auto
    /// Surface obstacle info to the AI as hints but don't auto-act.
    case hint
    /// Ignore obstacle rules entirely.
    case off
}

/// A rule for dismissing an app-specific obstacle (paywall, permission dialog, onboarding).
struct ObstacleRule: Sendable {
    /// Text that triggers this rule (substring match against screen elements).
    let trigger: String
    /// Text of the element to tap to dismiss (e.g. "Not Now", "Don't Allow", "×").
    let action: String
}

/// Parses APP.md files into AppDescription instances.
/// Pure transformation: all static methods, no stored state.
enum AppDescriptionParser {

    /// Parse an APP.md file's content into an AppDescription.
    /// Returns nil if required fields (app name, at least one section) are missing,
    /// or when ``AppMdSchemaVersion`` refuses the `version:` (absent, malformed,
    /// or a different major).
    static func parse(content: String) -> AppDescription? {
        let result = AppMdSectioning.extract(content: content)
        let frontMatter = result.frontMatter
        let sections = result.sections

        guard let appName = frontMatter["app"] else { return nil }
        let locale = frontMatter["locale"]
        let archetype = frontMatter["archetype"]
        let playable = frontMatter["playable"]
        let resetBeforeExplore = ["true", "yes", "1"].contains(
            (frontMatter["reset_before_explore"] ?? "false").lowercased())
        let obstacleMode = ObstacleMode(rawValue: frontMatter["obstacle_mode"] ?? "auto") ?? .auto

        let schemaVersion: Int
        switch AppMdSchemaVersion.gate(frontMatter["version"]) {
        case .supported(let major):
            schemaVersion = major
        case .newerMinor(let major, let minor):
            DebugLog.log("app-desc",
                "APP.md for '\(appName)' declares version \(major).\(minor); "
                + "this build models up to \(major).\(AppMdSchemaVersion.knownMinor). "
                + "Fields that minor added are ignored.")
            schemaVersion = major
        case .rejected(let reason):
            DebugLog.log("app-desc", "APP.md for '\(appName)' refused: \(reason)")
            return nil
        }

        // Collect free-form context from Structure + per-tab descriptions.
        // Tips live on `AppDescription.hints` (rendered as a separate section
        // by SkillMdGenerator) — intentionally excluded from `context` to avoid
        // duplicate rendering.
        var contextParts: [String] = []
        if let structure = sections["Structure"] {
            contextParts.append("## Structure\n\(structure.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for (heading, body) in sections.sorted(by: { $0.key < $1.key }) {
            if heading.hasSuffix("Tab") || heading.hasSuffix("tab") {
                contextParts.append("## \(heading)\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        let context = contextParts.joined(separator: "\n\n")
        guard !context.isEmpty || sections["Obstacles"] != nil || sections["Skip"] != nil else {
            return nil
        }

        let obstacles = parseObstacles(sections["Obstacles"] ?? "")
        let skipElements = parseList(sections["Skip"] ?? "")
        let credentials = parseCredentials(sections["Credentials"] ?? "")
        let hints = parseList(sections["Tips"] ?? "")
        let tabs = parseTabs(structure: sections["Structure"] ?? "", sections: sections)
        let tabLayout = parseTabLayout(sections["Tab Layout"] ?? "")
        let deepTabs = parseList(sections["Deep Tabs"] ?? "")
        let simulator = SimulatorSpecParser.parse(
            sections: sections, frontMatter: frontMatter, appName: appName)

        return AppDescription(
            appName: appName,
            schemaVersion: schemaVersion,
            locale: locale,
            archetype: archetype,
            playable: playable,
            resetBeforeExplore: resetBeforeExplore,
            obstacleMode: obstacleMode,
            context: context,
            obstacles: obstacles,
            skipElements: skipElements,
            credentials: credentials,
            hints: hints,
            tabs: tabs,
            tabLayout: tabLayout,
            deepTabs: deepTabs,
            simulator: simulator
        )
    }

    /// Why ``AppMdSchemaVersion`` refuses `content`, with the app it names:
    /// nil when it names no `app:` or its `version:` is accepted. The loader
    /// reports this so a refused APP.md is never dropped without a word.
    static func schemaRefusal(content: String) -> (appName: String, reason: String)? {
        let frontMatter = AppMdSectioning.extract(content: content).frontMatter
        guard let appName = frontMatter["app"],
              case .rejected(let reason) = AppMdSchemaVersion.gate(frontMatter["version"]) else {
            return nil
        }
        return (appName, reason)
    }

    /// Parse the `## Tab Layout` section.
    /// Accepts `- key: value` bullets or plain `key: value` lines.
    /// Returns nil when the section is absent or declares neither orientation nor edge.
    private static func parseTabLayout(_ text: String) -> TabLayout? {
        var orientation: TabOrientation?
        var edge: TabEdge?
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces).lowercased()
            switch key {
            case "orientation":
                orientation = TabOrientation(rawValue: value)
            case "edge":
                edge = TabEdge(rawValue: value)
            default:
                continue
            }
        }
        guard orientation != nil || edge != nil else { return nil }
        // Defaults: horizontal bottom (standard iOS tab bar convention).
        return TabLayout(
            orientation: orientation ?? .horizontal,
            edge: edge ?? .bottom
        )
    }

    // MARK: - Section Parsers

    /// Parse obstacle rules: lines like "- Health Access permission dialog → tap 'Allow'"
    /// or "- paywall → dismiss via 'Not Now'"
    private static func parseObstacles(_ text: String) -> [ObstacleRule] {
        var rules: [ObstacleRule] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let body = String(trimmed.dropFirst(2))

            // Parse "trigger → action" format
            // Support both → and -> as arrow separators
            let separator: String
            if body.contains("→") {
                separator = "→"
            } else if body.contains("->") {
                separator = "->"
            } else {
                continue
            }

            let splitParts = body.components(separatedBy: separator)
            guard splitParts.count >= 2 else { continue }

            let trigger = splitParts[0].trimmingCharacters(in: .whitespaces)
            let action = splitParts.dropFirst().joined(separator: separator)
                .trimmingCharacters(in: .whitespaces)

            // Strip common prefixes: "tap ", "dismiss via ", etc.
            let cleaned = action
                .replacingOccurrences(of: "tap ", with: "", options: [.caseInsensitive, .anchored])
                .replacingOccurrences(of: "dismiss via ", with: "", options: [.caseInsensitive, .anchored])
                .replacingOccurrences(of: "dismiss ", with: "", options: [.caseInsensitive, .anchored])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))

            guard !trigger.isEmpty && !cleaned.isEmpty else { continue }
            rules.append(ObstacleRule(trigger: trigger, action: cleaned))
        }
        return rules
    }

    /// Parse a simple bulleted list into strings.
    private static func parseList(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { line in
                String(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
            }
            .filter { !$0.isEmpty }
    }

    /// Parse credentials as key: value pairs.
    private static func parseCredentials(_ text: String) -> [String: String] {
        var creds: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            var stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("- ") { stripped = String(stripped.dropFirst(2)) }
            guard let colonIdx = stripped.firstIndex(of: ":") else { continue }
            let key = String(stripped[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(stripped[stripped.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            creds[key] = value
        }
        return creds
    }

    /// Extract tab names. Three patterns accepted, in priority order:
    /// 1. `## Tabs` section with a bullet list — cleanest syntax.
    /// 2. Inline in `## Structure`: "N tabs: Tab1, Tab2" or "tabs: Tab1, Tab2".
    /// 3. Per-tab section headings: "## Explorer Tab" → "Explorer".
    /// The first pattern that yields at least one name wins.
    private static func parseTabs(structure: String, sections: [String: String]) -> [String] {
        // Pattern 1: `## Tabs` section with bullet list.
        if let body = sections["Tabs"] {
            let tabs = parseList(body)
                .map { name -> String in
                    // Strip parenthetical translations: "Pour toi (For You)" → "Pour toi"
                    if let paren = name.range(of: "(") {
                        return String(name[name.startIndex..<paren.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    return name
                }
                .filter { !$0.isEmpty }
            if !tabs.isEmpty { return tabs }
        }

        var tabs: [String] = []

        // Pattern 2: "N tabs: Tab1, Tab2, Tab3" or "tabs: Tab1, Tab2" in Structure
        for line in structure.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "tabs:", options: .caseInsensitive) else {
                continue
            }
            let afterColon = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let names = afterColon.split(separator: ",").map { part in
                var name = part.trimmingCharacters(in: .whitespaces)
                if let parenStart = name.range(of: "(") {
                    name = String(name[name.startIndex..<parenStart.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }
                return name
            }
            tabs.append(contentsOf: names.filter { !$0.isEmpty })
            break
        }

        // Pattern 3: "## Explorer Tab" headings → "Explorer"
        if tabs.isEmpty {
            for heading in sections.keys.sorted() {
                if heading.hasSuffix("Tab") || heading.hasSuffix("tab") {
                    let name = heading.replacingOccurrences(of: " Tab", with: "")
                        .replacingOccurrences(of: " tab", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { tabs.append(name) }
                }
            }
        }

        return tabs
    }

}
