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
    ///   - recipeMatch: Optional matched screen recipe for archetype-aware generation.
    ///   - appDescription: Optional APP.md description; its tab names and
    ///     landmarks become stable wait-step anchors and its skip list excludes
    ///     landmark candidates.
    /// - Returns: A complete SKILL.md string with YAML front matter and markdown body.
    /// Actions whose element is on the screen they acted on, the one before the
    /// screen they reached.
    private static let sourceScreenActions: Set<String> = ["tap", "long_press"]

    static func generate(
        appName: String, goal: String, screens: [ExploredScreen],
        recipeMatch: RecipeMatch? = nil,
        appDescription: AppDescription? = nil
    ) -> String {
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
        var tags = ["generated"]
        if let recipe = recipeMatch?.recipe {
            tags.append(recipe.name)
        }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        if let recipe = recipeMatch?.recipe {
            lines.append("archetype: \(recipe.name)")
            lines.append("navigation: \(recipe.navigationModel.type)")
        }
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

        // Recipe exploration hints (when available, help the AI execute smarter)
        if let hints = recipeMatch?.recipe.explorationHints, !hints.isEmpty {
            lines.append("## Navigation Notes")
            lines.append("")
            for hint in hints {
                lines.append("- \(hint)")
            }
            lines.append("")
        }

        // App description context (from APP.md — helps AI understand the app)
        if let desc = appDescription, !desc.context.isEmpty {
            lines.append("## App Context")
            lines.append("")
            lines.append(desc.context)
            lines.append("")
        }

        // Developer-authored tips from APP.md, rendered as a distinct section so
        // they're easy to spot vs. the free-form Structure / tab descriptions.
        if let desc = appDescription, !desc.hints.isEmpty {
            lines.append("## Tips")
            lines.append("")
            for hint in desc.hints {
                lines.append("- \(hint)")
            }
            lines.append("")
        }

        // Declared credential keys (NOT values) so the AI knows what credentials
        // the flow needs. Resolved env-var values never leak into the skill file.
        if let desc = appDescription, !desc.credentials.isEmpty {
            lines.append("## Required Credentials")
            lines.append("")
            lines.append("This app declares the following credentials in its APP.md. "
                + "Values are resolved from environment variables at runtime — "
                + "do not hardcode secrets in the skill.")
            lines.append("")
            for key in desc.credentials.keys.sorted() {
                lines.append("- `\(key)`")
            }
            lines.append("")
        }

        // Steps heading
        lines.append("## Steps")

        // Step counter and landmark dedup tracker
        var stepNum = 1
        var emittedLandmarks = Set<String>()

        // Step 1: always launch the app
        lines.append("\(stepNum). Launch **\(appName)**")
        stepNum += 1

        // Infinite-scroll archetypes have ephemeral feed content: only stable
        // anchors qualify as wait landmarks, otherwise the wait step is omitted.
        let requireStable = recipeMatch?.recipe.navigationModel.scrollBehavior == "infinite"

        // Steps for each captured screen
        for (index, screen) in screens.enumerated() {
            // The action that reached this screen comes first, then the wait for
            // the screen it reached: a wait placed before the action would look
            // for the next screen's landmark on the screen the action starts from.
            // Prefer displayLabel (component-derived, OCR-artifact-free) over raw arrivedVia.
            // Fall back to resolving arrivedVia against screen elements for proper casing:
            // a tap or long press acted on the screen before, so its label is resolved
            // there — on the screen it reached, "BRAWLERS" would match a longer
            // "BRAWLERS À DÉBLOQUER" by containment.
            let actedOn = index > 0 && Self.sourceScreenActions.contains(screen.actionType ?? "")
                ? screens[index - 1].elements : screen.elements
            let stepLabel: String? = screen.displayLabel ?? screen.arrivedVia.map { via in
                ActionStepFormatter.resolveLabel(arrivedVia: via, elements: actedOn)
            }

            // Generate action step based on actionType
            if let step = ActionStepFormatter.format(actionType: screen.actionType, arrivedVia: stepLabel) {
                lines.append("\(stepNum). \(step)")
                stepNum += 1
            }

            // Pick a landmark element for wait_for, skipping already-emitted landmarks.
            // APP.md tab names and landmarks act as stable anchors and its skip
            // list as exclusions.
            if let landmark = LandmarkPicker.pickLandmark(
                from: screen.elements,
                stableAnchors: appDescription?.stableAnchors ?? [],
                excludedPatterns: appDescription?.skipElements ?? [],
                requireStable: requireStable
            ) {
                if !emittedLandmarks.contains(landmark) {
                    emittedLandmarks.insert(landmark)
                    lines.append("\(stepNum). Wait for \"\(landmark)\" to appear")
                    stepNum += 1
                }
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
