// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Guidance generation and formatting helpers for the generate_skill tool.
// ABOUTME: Dispatches strategy-based guidance and formats screen descriptions for MCP responses.

import Foundation
import HelperLib

/// Helpers for generating exploration guidance and formatting screen descriptions.
/// Extracted from GenerateSkillTools to keep that file under the 500-line limit.
enum ExplorationGuidanceHelper {

    /// Generate exploration guidance, preferring strategy-based analysis when the graph is populated.
    /// Falls back to the keyword-based ExplorationGuide.analyze() for backward compatibility.
    static func generateGuidance(
        session: ExplorationSession,
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String],
        isMobile: Bool = true
    ) -> ExplorationGuide.Guidance {
        let graph = session.currentGraph
        if graph.started {
            return analyzeWithDetectedStrategy(
                session: session, graph: graph,
                elements: elements, icons: icons, hints: hints
            )
        }
        return ExplorationGuide.analyze(
            mode: session.currentMode,
            goal: session.currentGoal,
            elements: elements,
            hints: hints,
            startElements: session.startScreenElements,
            actionLog: session.actions,
            screenCount: session.screenCount,
            isMobile: isMobile
        )
    }

    /// Dispatch strategy-based guidance analysis using the session's detected strategy.
    static func analyzeWithDetectedStrategy(
        session: ExplorationSession,
        graph: NavigationGraph,
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String]
    ) -> ExplorationGuide.Guidance {
        switch session.currentStrategy {
        case "social":
            return ExplorationGuide.analyzeWithStrategy(
                strategy: SocialAppStrategy.self,
                graph: graph, elements: elements, icons: icons,
                hints: hints, budget: .default, goal: session.currentGoal)
        case "desktop":
            return ExplorationGuide.analyzeWithStrategy(
                strategy: DesktopAppStrategy.self,
                graph: graph, elements: elements, icons: icons,
                hints: hints, budget: .default, goal: session.currentGoal)
        default:
            return ExplorationGuide.analyzeWithStrategy(
                strategy: MobileAppStrategy.self,
                graph: graph, elements: elements, icons: icons,
                hints: hints, budget: .default, goal: session.currentGoal)
        }
    }

    /// Format OCR elements and hints into a text description.
    /// Same pattern as describe_screen in ScreenTools.swift.
    static func formatScreenDescription(
        elements: [TapPoint],
        hints: [String],
        preamble: String
    ) -> String {
        var lines = [preamble, "", "Screen elements (tap coordinates in points):"]
        for el in elements.sorted(by: { $0.tapY < $1.tapY }) {
            lines.append("- \"\(el.text)\" at (\(Int(el.tapX)), \(Int(el.tapY)))")
        }
        if elements.isEmpty {
            lines.append("(no text detected)")
        }
        if !hints.isEmpty {
            lines.append("")
            lines.append("Hints:")
            for hint in hints {
                lines.append("- \(hint)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
