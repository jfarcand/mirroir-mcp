// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Assembles SKILL.md documents from explored screens.
// ABOUTME: Produces YAML front matter and numbered markdown steps using LandmarkPicker and ActionStepFormatter.

import Foundation
import HelperLib

/// Generates SKILL.md content from app exploration data.
/// Delegates OCR filtering to `LandmarkPicker` and action formatting to `ActionStepFormatter`.
enum SkillMdGenerator {

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

        // Description paragraph
        if !goal.isEmpty {
            let capitalizedGoal = goal.prefix(1).uppercased() + goal.dropFirst()
            lines.append("\(capitalizedGoal) in the \(appName) app.")
        } else {
            lines.append("Explore the \(appName) app.")
        }
        lines.append("")

        // Steps heading
        lines.append("## Steps")

        // Step counter and landmark dedup tracker
        var stepNum = 1
        var lastLandmark: String?

        // Step 1: always launch the app
        lines.append("\(stepNum). Launch **\(appName)**")
        stepNum += 1

        // Steps for each captured screen
        for screen in screens {
            // Pick a landmark element for wait_for, skipping consecutive duplicates
            if let landmark = LandmarkPicker.pickLandmark(from: screen.elements) {
                if landmark != lastLandmark {
                    lines.append("\(stepNum). Wait for \"\(landmark)\" to appear")
                    stepNum += 1
                }
                lastLandmark = landmark
            }

            // Generate action step based on actionType
            if let step = ActionStepFormatter.format(actionType: screen.actionType, arrivedVia: screen.arrivedVia) {
                lines.append("\(stepNum). \(step)")
                stepNum += 1
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Derive a skill name from the app name and optional goal.
    /// Produces a Title Case name suitable for display.
    static func deriveName(appName: String, goal: String) -> String {
        let source: String
        if goal.isEmpty {
            source = "Explore \(appName)"
        } else {
            source = goal
        }

        // Title-case each word
        return source.split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
