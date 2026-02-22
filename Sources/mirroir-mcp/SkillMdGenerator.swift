// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pure function that converts explored screens into a SKILL.md string.
// ABOUTME: Produces YAML front matter and markdown step instructions from ExploredScreen data.

import Foundation
import HelperLib

/// Generates SKILL.md content from app exploration data.
/// Pure function with no side effects — easily testable.
enum SkillMdGenerator {

    /// Minimum character length for a landmark candidate.
    static let landmarkMinLength = 3
    /// Maximum character length for a landmark candidate.
    static let landmarkMaxLength = 40
    /// Minimum OCR confidence for a landmark candidate.
    static let landmarkMinConfidence: Float = 0.5

    /// Generate a SKILL.md string from exploration session data.
    ///
    /// - Parameters:
    ///   - appName: The app that was explored.
    ///   - goal: Optional description of the flow (e.g. "check software version").
    ///   - screens: Captured screens in navigation order.
    /// - Returns: A complete SKILL.md string with YAML front matter and markdown body.
    static func generate(appName: String, goal: String, screens: [ExploredScreen]) -> String {
        var lines: [String] = []

        // YAML front matter
        let name = deriveName(appName: appName, goal: goal)
        lines.append("---")
        lines.append("version: \(SkillMdParser.currentVersion)")
        lines.append("name: \(name)")
        lines.append("app: \(appName)")
        if !goal.isEmpty {
            lines.append("description: \(goal)")
        } else {
            lines.append("description: Explore \(appName)")
        }
        lines.append("tags: [generated]")
        lines.append("---")
        lines.append("")

        // Step 1: always launch the app
        lines.append("Launch **\(appName)**")
        lines.append("")

        // Steps for each captured screen
        for screen in screens {
            // Pick a landmark element for wait_for
            if let landmark = pickLandmarkElement(from: screen.elements) {
                lines.append("Wait for \"\(landmark)\"")
                lines.append("")
            }

            // If this screen was reached by tapping something, add a Tap step
            if let arrivedVia = screen.arrivedVia, !arrivedVia.isEmpty {
                lines.append("Tap \"\(arrivedVia)\"")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Pick the most distinctive OCR element near the top of the screen as a landmark.
    /// Prefers elements that are 3-40 characters long with confidence > 0.5.
    /// Sorts candidates by Y position (topmost first) to pick a stable header/title.
    static func pickLandmarkElement(from elements: [TapPoint]) -> String? {
        let candidates = elements.filter { el in
            el.text.count >= landmarkMinLength &&
            el.text.count <= landmarkMaxLength &&
            el.confidence >= landmarkMinConfidence
        }
        .sorted { $0.tapY < $1.tapY }

        return candidates.first?.text
    }

    /// Derive a skill name from the app name and optional goal.
    /// Produces a lowercase-kebab-case identifier.
    static func deriveName(appName: String, goal: String) -> String {
        let source: String
        if goal.isEmpty {
            source = "explore-\(appName)"
        } else {
            source = "\(appName)-\(goal)"
        }

        // Convert to lowercase kebab-case: replace non-alphanumeric with hyphens, collapse runs
        let kebab = source.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()

        // Collapse consecutive hyphens and trim leading/trailing hyphens
        let collapsed = kebab.components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return collapsed
    }
}
