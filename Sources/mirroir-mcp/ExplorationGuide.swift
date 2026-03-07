// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Produces exploration guidance after each screen capture for AI agents.
// ABOUTME: Analyzes screen elements against the goal and history to suggest next actions.

import Foundation
import HelperLib

/// Produces actionable guidance for AI agents during app exploration.
/// Analyzes screen content, goal relevance, and navigation history to suggest next actions.
enum ExplorationGuide {

    /// Exploration mode determines the strategy for guidance generation.
    enum Mode: String, Sendable {
        /// Agent has a specific goal (e.g. "check software version").
        case goalDriven
        /// Agent explores freely and discovers available flows.
        case discovery
    }

    /// Structured guidance returned after each capture.
    struct Guidance: Sendable {
        /// Suggested next actions (e.g. "Tap \"About\"", "Scroll down").
        let suggestions: [String]
        /// Goal progress note, nil if no goal or no progress detected.
        let goalProgress: String?
        /// Warning about exploration state (cycle detected, stuck, etc.).
        let warning: String?
        /// True if the agent appears to be back at the starting screen.
        let isFlowComplete: Bool
    }

    /// Maximum number of navigation suggestions to include in guidance.
    static let maxSuggestions = 5

    // MARK: - Main Entry Point

    /// Minimum captures before flow boundary detection is active.
    static let minScreensForFlowBoundary = 2

    /// Number of consecutive duplicate captures that triggers a "stuck" warning.
    static let stuckThreshold = 3

    /// Analyze the current screen and produce guidance for the agent.
    static func analyze(
        mode: Mode,
        goal: String,
        elements: [TapPoint],
        hints: [String],
        startElements: [TapPoint]?,
        actionLog: [ExplorationAction],
        screenCount: Int,
        isMobile: Bool = true
    ) -> Guidance {
        let backAtStart: Bool
        if let startElements, screenCount >= minScreensForFlowBoundary {
            backAtStart = StructuralFingerprint.areEquivalent(elements, startElements)
        } else {
            backAtStart = false
        }

        let duplicateStreak = consecutiveDuplicatesCount(in: actionLog)

        let warning: String?
        if duplicateStreak >= stuckThreshold {
            warning = "Agent appears stuck \u{2014} last \(duplicateStreak) captures were duplicates. " +
                "Try a different element or scroll to reveal new content."
        } else {
            warning = nil
        }

        switch mode {
        case .goalDriven:
            return analyzeGoalDriven(
                goal: goal, elements: elements, hints: hints,
                backAtStart: backAtStart, warning: warning, screenCount: screenCount)
        case .discovery:
            return analyzeDiscovery(
                elements: elements, hints: hints,
                backAtStart: backAtStart, warning: warning, screenCount: screenCount,
                isMobile: isMobile)
        }
    }

    // MARK: - Goal-Driven Analysis

    private static func analyzeGoalDriven(
        goal: String,
        elements: [TapPoint],
        hints: [String],
        backAtStart: Bool,
        warning: String?,
        screenCount: Int
    ) -> Guidance {
        let keywords = extractKeywords(from: goal)
        let candidates = filterNavigableElements(elements)

        // Check if goal-relevant content is visible on screen
        let goalMatches = candidates.filter { el in
            keywords.contains(where: { keyword in
                el.text.lowercased().contains(keyword)
            })
        }

        var suggestions: [String] = []
        var goalProgress: String?

        if !goalMatches.isEmpty {
            let matchTexts = goalMatches.map { "\"\($0.text)\"" }.joined(separator: ", ")
            goalProgress = "Goal-relevant content visible: \(matchTexts). " +
                "Consider using Remember to note the information, then Finish."
            suggestions.append("Remember: Note the relevant information on screen")
            suggestions.append("Screenshot: Capture this screen for reference")
            suggestions.append("Finish: Complete the exploration")
        } else {
            goalProgress = "Goal \"\(goal)\" \u{2014} not yet visible on this screen."

            let ranked = rankByGoalRelevance(candidates: candidates, keywords: keywords)
            for (index, el) in ranked.prefix(maxSuggestions).enumerated() {
                if index == 0 && !keywords.isEmpty {
                    suggestions.append("Tap \"\(el.text)\" \u{2014} may lead toward \"\(goal)\"")
                } else {
                    suggestions.append("Tap \"\(el.text)\"")
                }
            }

            if candidates.count > maxSuggestions {
                suggestions.append("Scroll down \u{2014} more content may be below")
            }
        }

        if backAtStart {
            suggestions.append("Back at start screen \u{2014} consider finishing exploration")
        }

        return Guidance(
            suggestions: suggestions,
            goalProgress: goalProgress,
            warning: warning,
            isFlowComplete: backAtStart
        )
    }

    // MARK: - Discovery Analysis

    private static func analyzeDiscovery(
        elements: [TapPoint],
        hints: [String],
        backAtStart: Bool,
        warning: String?,
        screenCount: Int,
        isMobile: Bool = true
    ) -> Guidance {
        let candidates = filterNavigableElements(elements)
        var suggestions: [String] = []
        var goalProgress: String?

        if screenCount <= 1 {
            goalProgress = "Discovery mode \u{2014} explore available flows on this screen."
            for el in candidates.prefix(maxSuggestions) {
                suggestions.append("Tap \"\(el.text)\" \u{2014} explore this flow")
            }
            if candidates.count > maxSuggestions {
                suggestions.append(
                    "Scroll down \u{2014} \(candidates.count - maxSuggestions) more elements below")
            }
        } else if backAtStart {
            goalProgress = "Back at start screen \u{2014} pick another flow to explore, or Finish."
            for el in candidates.prefix(maxSuggestions) {
                suggestions.append("Tap \"\(el.text)\" \u{2014} explore this flow")
            }
        } else {
            for el in candidates.prefix(maxSuggestions) {
                suggestions.append("Tap \"\(el.text)\"")
            }
            if isMobile {
                suggestions.append("Tap the back button \u{2014} return to previous screen")
            } else {
                suggestions.append("Press Back (Cmd+[) \u{2014} return to previous screen")
            }
        }

        return Guidance(
            suggestions: suggestions,
            goalProgress: goalProgress,
            warning: warning,
            isFlowComplete: backAtStart
        )
    }

    // MARK: - Flow Detection

    /// Count consecutive duplicate capture rejections from the tail of the action log.
    static func consecutiveDuplicatesCount(in actionLog: [ExplorationAction]) -> Int {
        var count = 0
        for action in actionLog.reversed() {
            if action.wasDuplicate {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Keyword Extraction

    /// Common stop words filtered from goal text before keyword matching.
    static let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been",
        "to", "of", "in", "for", "on", "with", "at", "by", "from",
        "and", "or", "not", "no", "do", "does", "did",
        "this", "that", "it", "its", "my", "your",
        "how", "what", "where", "when", "which", "who",
        "check", "find", "look", "see", "get", "go",
    ]

    /// Extract lowercase keywords from a goal string, filtering stop words.
    static func extractKeywords(from goal: String) -> [String] {
        goal.lowercased()
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Filter elements to those likely to be navigation targets.
    /// Excludes status bar, short text, and low-confidence elements.
    static func filterNavigableElements(_ elements: [TapPoint]) -> [TapPoint] {
        elements.filter { el in
            el.text.count >= LandmarkPicker.landmarkMinLength &&
            el.text.count <= LandmarkPicker.landmarkMaxLength &&
            el.confidence >= LandmarkPicker.landmarkMinConfidence &&
            el.tapY >= LandmarkPicker.statusBarMaxY &&
            !LandmarkPicker.isTimePattern(el.text) &&
            !LandmarkPicker.isBareNumber(el.text) &&
            !LandmarkPicker.isPunctuationOnly(el.text)
        }
        .sorted(by: { $0.tapY < $1.tapY })
    }

    /// Rank elements by relevance to goal keywords.
    /// Elements containing goal keywords are ranked first, then by Y position.
    static func rankByGoalRelevance(
        candidates: [TapPoint],
        keywords: [String]
    ) -> [TapPoint] {
        guard !keywords.isEmpty else { return candidates }

        let scored = candidates.map { el -> (TapPoint, Int) in
            let text = el.text.lowercased()
            let score = keywords.filter { text.contains($0) }.count
            return (el, score)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - Strategy-Based Analysis

    /// Analyze the current screen using a NavigationGraph and ExplorationStrategy.
    /// Produces guidance from graph state + strategy instead of keyword matching.
    static func analyzeWithStrategy<S: ExplorationStrategy>(
        strategy: S.Type,
        graph: NavigationGraph,
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String],
        budget: ExplorationBudget,
        goal: String
    ) -> Guidance {
        let fingerprint = graph.currentFingerprint
        guard let node = graph.node(for: fingerprint) else {
            // Fallback: graph not populated yet
            return Guidance(suggestions: ["Capture the current screen first."],
                            goalProgress: nil, warning: nil, isFlowComplete: false)
        }

        let screenType = node.screenType
        let depth = node.depth
        let visitedElements = node.visitedElements

        // Check if terminal
        if strategy.isTerminal(elements: elements, depth: depth,
                               budget: budget, screenType: screenType) {
            let backtrack = strategy.backtrackMethod(currentHints: hints, depth: depth)
            var suggestions = ["This screen is a terminal node."]
            switch backtrack {
            case .pressBack:
                suggestions.append("Press Back (Cmd+[) to backtrack.")
            case .pressHome:
                suggestions.append("Press Home to return to app root.")
            case .tapBack:
                suggestions.append("Tap the back button to go back.")
            case .none:
                suggestions.append("Consider finishing exploration.")
            }
            return Guidance(suggestions: suggestions, goalProgress: nil,
                            warning: nil, isFlowComplete: false)
        }

        // Rank elements
        let ranked = strategy.rankElements(
            elements: elements, icons: icons,
            visitedElements: visitedElements, depth: depth, screenType: screenType
        )
        let actionable = ranked.filter { !strategy.shouldSkip(elementText: $0.text, budget: budget) }

        var suggestions: [String] = []
        var goalProgress: String?

        // Goal progress (if goal-driven)
        if !goal.isEmpty {
            let keywords = extractKeywords(from: goal)
            let matches = actionable.filter { el in
                keywords.contains { el.text.lowercased().contains($0) }
            }
            if !matches.isEmpty {
                let matchTexts = matches.map { "\"\($0.text)\"" }.joined(separator: ", ")
                goalProgress = "Goal-relevant content visible: \(matchTexts)."
            } else {
                goalProgress = "Goal \"\(goal)\" \u{2014} not yet visible."
            }
        }

        // Suggest unvisited elements
        let unvisited = actionable.filter { !visitedElements.contains($0.text) }
        for el in unvisited.prefix(maxSuggestions) {
            suggestions.append("Tap \"\(el.text)\"")
        }

        if unvisited.isEmpty {
            let backtrack = strategy.backtrackMethod(currentHints: hints, depth: depth)
            switch backtrack {
            case .pressBack:
                suggestions.append("All elements visited \u{2014} Press Back (Cmd+[)")
            case .pressHome:
                suggestions.append("All elements visited \u{2014} Press Home")
            case .tapBack:
                suggestions.append("All elements visited \u{2014} Tap back")
            case .none:
                suggestions.append("All elements visited \u{2014} consider finishing")
            }
        }

        // Warning for stuck state
        let warning: String? = (graph.nodeCount == 1 && graph.edgeCount > 3)
            ? "Navigation appears stuck \u{2014} actions are not changing the screen."
            : nil

        return Guidance(
            suggestions: suggestions,
            goalProgress: goalProgress,
            warning: warning,
            isFlowComplete: unvisited.isEmpty && depth == 0
        )
    }

    // MARK: - Formatting

    /// Format a Guidance struct as text for inclusion in MCP tool response.
    static func formatGuidance(_ guidance: Guidance) -> String {
        var lines: [String] = []

        if let goalProgress = guidance.goalProgress {
            lines.append("")
            lines.append("Exploration guidance:")
            lines.append("- \(goalProgress)")
        }

        if let warning = guidance.warning {
            lines.append("")
            lines.append("Warning: \(warning)")
        }

        if !guidance.suggestions.isEmpty {
            if guidance.goalProgress == nil {
                lines.append("")
                lines.append("Suggestions:")
            }
            for suggestion in guidance.suggestions {
                lines.append("- \(suggestion)")
            }
        }

        if guidance.isFlowComplete {
            lines.append("")
            lines.append(
                "Flow appears complete \u{2014} call generate_skill with " +
                "action=\"finish\" to generate the SKILL.md.")
        }

        return lines.joined(separator: "\n")
    }
}
