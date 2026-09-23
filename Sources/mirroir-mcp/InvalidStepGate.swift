// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Refuses a `mirroir test` run whose skills hold a step the parser could not read.
// ABOUTME: Checked before any step executes, dry run included — a run cannot pass over steps it never understood.

import Foundation

/// Pre-flight gate for steps the parser turned into `.invalid`.
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
                guard case .invalid(let stepType, let reason) = step else { return nil }
                return Finding(skillName: skill.name, filePath: skill.filePath,
                               stepIndex: index, stepType: stepType, reason: reason)
            }
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
