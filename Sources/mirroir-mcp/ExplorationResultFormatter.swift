// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Formats exploration results (skill bundles, stats, reports) for MCP tool output.
// ABOUTME: Extracted from GenerateSkillTools.swift to keep files under the 500-line limit.

import Foundation

/// Formats exploration results for display in MCP tool responses.
/// Pure transformation: all static methods, no stored state.
enum ExplorationResultFormatter {

    /// Format a skill bundle into display text.
    static func formatBundle(_ bundle: SkillBundle, preamble: String) -> String {
        if bundle.skills.count > 1 {
            var text = preamble + "\n\n"
            if let manifest = bundle.manifest { text += manifest + "\n" }
            for (i, skill) in bundle.skills.enumerated() {
                text += "--- Skill \(i + 1): \(skill.name) ---\n\n" + skill.content
                if i < bundle.skills.count - 1 { text += "\n\n" }
            }
            return text
        }
        return bundle.skills.first?.content ?? ""
    }

    /// Format the final exploration result with stats, skill content, and detailed report.
    static func formatExploreResult(bundle: SkillBundle, explorer: BFSExplorer) -> String {
        let stats = explorer.stats
        let statLine = "(\(stats.nodeCount) screens, \(stats.actionCount) actions, \(stats.elapsedSeconds)s)"
        guard !bundle.skills.isEmpty else {
            return "Exploration finished but no skills were generated.\n\n" + explorer.generateReport()
        }
        let preamble = bundle.skills.count > 1
            ? "Exploration complete! Generated \(bundle.skills.count) skills \(statLine):"
            : "Exploration complete \(statLine):"
        return formatBundle(bundle, preamble: preamble) + "\n\n" + explorer.generateReport()
    }
}
