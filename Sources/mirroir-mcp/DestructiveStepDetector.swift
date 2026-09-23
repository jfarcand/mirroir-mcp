// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds skill steps with real-world consequences that a run should confirm first.
// ABOUTME: Pure matching over step text; the runner decides what to do with the matches.

import Foundation

/// Identifies skill steps whose effects reach the outside world and cannot be
/// undone by re-running the skill (pure transformation pattern).
///
/// `ExplorationBudget.builtInSkipPatterns` already keeps the autonomous explorer
/// away from these actions, but that guard only covers exploration. A skill run
/// through `mirroir test` executes exactly the steps it was given, so a skill
/// containing "tap Send" or "tap Delete" fires it against a live device with
/// nothing in between. This closes that gap.
enum DestructiveStepDetector {

    /// A step that needs confirmation before the run may proceed.
    struct Match {
        /// Skill the step belongs to.
        let skillName: String
        /// 1-based position, matching how step numbers are reported to users.
        let stepNumber: Int
        /// The step rendered for a human deciding whether to allow it.
        let summary: String
        /// Why it matched — either the pattern found in the step's text, or the
        /// name of an inherently destructive step type.
        let reason: String
    }

    /// Actions that reach the outside world, matched against the user-visible
    /// text of a step. English only — localized patterns belong in the skill
    /// definitions, matching the convention in `ExplorationBudget`.
    ///
    /// A pattern wrapped in slashes is treated as a regular expression, the same
    /// syntax `skipElements` accepts.
    static let builtInConfirmPatterns: [String] = [
        // Sending / publishing — irreversible once it reaches another person
        "send", "post", "publish", "share", "reply", "forward", "invite",
        // Removal
        "delete", "uninstall", "remove", "archive", "erase", "clear all", "trash",
        // Money
        "pay", "purchase", "buy", "order", "checkout", "subscribe", "donate",
        "transfer", "withdraw",
        // Account state
        "sign out", "log out", "deactivate", "close account", "unfriend",
        "unfollow", "block", "report",
    ]

    /// Step types that are destructive by their nature, whatever their text says.
    private static let inherentlyDestructiveTypes: Set<String> = ["reset_app"]

    /// Find every step across `skills` that needs confirmation.
    ///
    /// Returns matches in execution order so a caller can show the user what
    /// would happen, in the sequence it would happen.
    static func scan(skills: [SkillDefinition], patterns: [String]) -> [Match] {
        skills.flatMap { skill in
            skill.steps.enumerated().compactMap { index, step in
                guard let reason = reasonForConfirmation(step, patterns: patterns) else {
                    return nil
                }
                return Match(
                    skillName: skill.name,
                    stepNumber: index + 1,
                    summary: step.displayName,
                    reason: reason
                )
            }
        }
    }

    /// Why a step needs confirmation, or `nil` when it does not.
    static func reasonForConfirmation(_ step: SkillStep, patterns: [String]) -> String? {
        if inherentlyDestructiveTypes.contains(step.typeKey) {
            return "\(step.typeKey) erases app state"
        }
        guard let text = consequentialText(of: step) else { return nil }
        guard let pattern = firstMatch(in: text, patterns: patterns) else { return nil }
        return "matches '\(pattern)'"
    }

    /// The user-visible text of a step that could cause an effect, or `nil` for
    /// steps that only observe.
    ///
    /// The switch is exhaustive on purpose: a new step type must be classified
    /// deliberately rather than defaulting into "harmless".
    static func consequentialText(of step: SkillStep) -> String? {
        switch step {
        // Acts on a named control — the label is what the user would be tapping.
        case .tap(let label), .longPress(let label, _):
            return label
        // Enters content that a following action may commit.
        case .type(let text):
            return text
        // Can hand off to another app or trigger a server-side action.
        case .openURL(let url):
            return url
        // Rearranging or dropping onto a target can delete or reorder.
        case .drag(let fromLabel, let toLabel):
            return "\(fromLabel) \(toLabel)"
        // Times an inner action; the inner action carries the consequence.
        case .measure(_, let action, _, _):
            return consequentialText(of: action)
        // Observation, navigation, and device-level steps carry no target text.
        case .launch, .pressKey, .swipe, .waitFor, .assertVisible, .assertNotVisible,
             .screenshot, .home, .shake, .scrollTo, .resetApp, .setNetwork,
             .switchTarget, .skipped, .invalid:
            return nil
        }
    }

    /// The first pattern matching `text`, or `nil`. Patterns wrapped in slashes
    /// are regular expressions; the rest are case-insensitive substrings.
    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        let haystack = text.lowercased()
        for pattern in patterns {
            if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
                let body = String(pattern.dropFirst().dropLast())
                guard let regex = try? NSRegularExpression(
                    pattern: body, options: [.caseInsensitive]) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, range: range) != nil { return pattern }
            } else if haystack.contains(pattern.lowercased()) {
                return pattern
            }
        }
        return nil
    }

}
