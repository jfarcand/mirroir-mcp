// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Refuses a `mirroir test` run whose skills hold a step the parser could not read.
// ABOUTME: Checked before any step executes, dry run included — a run cannot pass over steps it never understood.

import Foundation

/// Pre-flight gate for steps the parser turned into `.invalid`, or into a
/// `.skipped` step it could not use.
enum InvalidStepGate {

    /// One unreadable step, located in its skill.
    struct Finding: Equatable {
        let skillName: String
        let filePath: String
        let stepIndex: Int
        let stepType: String
        let reason: String
    }

    /// Every invalid step across `skills`, in skill and step order.
    static func scan(skills: [SkillDefinition]) -> [Finding] {
        skills.flatMap { skill in
            skill.steps.enumerated().compactMap { index, step in
                guard let unreadable = unreadable(step) else { return nil }
                return Finding(skillName: skill.name, filePath: skill.filePath,
                               stepIndex: index, stepType: unreadable.stepType,
                               reason: unreadable.reason)
            }
        }
    }

    /// The type and reason of a step the parser could not read, looking inside a
    /// measure at the action it times; nil for a readable step.
    ///
    /// A step the parser could read but not use (a drag naming neither end, a
    /// measure with no action) is refused too: it would otherwise run as SKIP,
    /// and a skill can pass beside a step that checked nothing. An AI-only step
    /// is readable — it reports itself not evaluated — except as the action a
    /// measure times, where nothing would run before the timer starts.
    static func unreadable(_ step: SkillStep) -> (stepType: String, reason: String)? {
        switch step {
        case .invalid(let stepType, let reason):
            return (stepType, reason)
        case .skipped(let stepType, let reason) where step.aiOnlyStepType == nil:
            return (stepType, reason)
        case .measure(_, let action, _, _):
            if let stepType = action.aiOnlyStepType {
                return ("measure", "action \(stepType): an AI-only step cannot be timed")
            }
            return unreadable(action).map { ("measure", "action \($0.stepType): \($0.reason)") }
        default:
            return nil
        }
    }

    /// Refuse the run when any skill holds an invalid step.
    ///
    /// A dry run is refused too: it reports every step PASS without executing,
    /// so letting it through would pass a file the real run cannot read.
    /// Returns the exit code to return, or `nil` to proceed.
    static func refuse(skills: [SkillDefinition]) -> Int32? {
        let findings = scan(skills: skills)
        guard !findings.isEmpty else { return nil }
        fputs("Error: \(findings.count) step(s) cannot be run:\n", stderr)
        for finding in findings {
            fputs("  \(finding.filePath) step \(finding.stepIndex) (\(finding.stepType)): "
                  + "\(finding.reason)\n", stderr)
        }
        return 1
    }
}
