/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: The structured forms of the condition and repeat steps: a visibility check that gates or repeats one action.
// ABOUTME: Parses `visible "X" -> step` and `until visible "X", max N -> step`; any other value stays an AI-only step.

import Foundation
import HelperLib

/// What a `condition` or `repeat` step checks on the screen: whether an
/// element with `label` is visible (`visible`) or absent (`not visible`).
struct ScreenCheck: Equatable {
    let label: String
    let visible: Bool

    /// The check as the step grammar writes it, with `quotedLabel` as the label.
    func written(quotedLabel: String) -> String {
        (visible ? "" : "not ") + "visible \(quotedLabel)"
    }

    /// The check as a report names it: `"Done" visible` or `"Done" not visible`.
    var displayName: String {
        "\"\(label)\" " + (visible ? "visible" : "not visible")
    }

    /// Whether the check holds on a screen showing `elements`.
    func holds(in elements: [TapPoint]) -> Bool {
        ElementMatcher.isVisible(label: label, in: elements) == visible
    }
}

/// Parses the structured `condition` and `repeat` values.
///
/// `condition: visible "Allow" -> tap: Allow` runs the action only when the
/// check holds. `repeat: until visible "Done", max 8 -> swipe: up` runs the
/// action until the check holds, at most `max` times. A value that does not
/// open with the check (`visible`, `not visible`, `until ...`) is free text an
/// AI client interprets, and parses to the AI-only step as before.
enum ControlFlowSteps {

    /// The most times one `repeat` may run its action. A repeat states its own
    /// `max`; this bounds what it may state, so one step cannot loop for hours.
    static let maxRepeatIterations = 50

    /// The arrow between the check and the action.
    static let arrow = "->"

    static let conditionForm = "condition: visible \"Label\" -> tap: Label"
    static let repeatForm = "repeat: until visible \"Label\", max 8 -> swipe: up"

    /// The step a `condition` value parses to, or nil when the value is free
    /// text for an AI client.
    static func parseCondition(_ value: String) -> SkillStep? {
        guard opensWithCheck(value) else { return nil }
        guard let (head, actionText) = splitArrow(value),
              let check = parseCheck(head) else {
            return .invalid(stepType: "condition", reason: "expected `\(conditionForm)`")
        }
        switch parseAction(actionText) {
        case .action(let action): return .condition(check: check, then: action)
        case .refused(let reason): return .invalid(stepType: "condition", reason: reason)
        }
    }

    /// The step a `repeat` value parses to, or nil when the value is free text
    /// for an AI client.
    static func parseRepeat(_ value: String) -> SkillStep? {
        guard let afterUntil = dropWord("until", from: value), opensWithCheck(afterUntil) else {
            return nil
        }
        let invalid = SkillStep.invalid(stepType: "repeat", reason: "expected `\(repeatForm)`")
        guard let (head, actionText) = splitArrow(afterUntil),
              let comma = head.lastIndex(of: ",") else { return invalid }
        let checkText = String(head[..<comma])
        let maxText = head[head.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard let check = parseCheck(checkText),
              let countText = dropWord("max", from: maxText),
              let count = Int(countText) else { return invalid }
        guard (1...maxRepeatIterations).contains(count) else {
            return .invalid(stepType: "repeat",
                            reason: "max must be between 1 and \(maxRepeatIterations), got \(count)")
        }
        switch parseAction(actionText) {
        case .action(let action):
            return .repeatUntil(check: check, maxIterations: count, body: action)
        case .refused(let reason):
            return .invalid(stepType: "repeat", reason: reason)
        }
    }

    /// Whether `value` opens with a check: `visible` or `not visible`, then a quote.
    private static func opensWithCheck(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let afterNot = dropWord("not", from: trimmed) ?? trimmed
        guard let rest = dropWord("visible", from: afterNot) else { return false }
        return rest.hasPrefix("\"") || rest.hasPrefix("'")
    }

    /// The check in `text`: `visible "X"` or `not visible "X"`, quoted with
    /// double or single quotes. Nil when it is anything else.
    private static func parseCheck(_ text: String) -> ScreenCheck? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let negated = dropWord("not", from: trimmed)
        guard let quoted = dropWord("visible", from: negated ?? trimmed),
              let label = unquote(quoted), !label.isEmpty else { return nil }
        return ScreenCheck(label: label, visible: negated == nil)
    }

    /// The check half and the action half of `value`, split at the first arrow
    /// outside quotes. Nil when there is no such arrow.
    private static func splitArrow(_ value: String) -> (String, String)? {
        var quote: Character?
        var index = value.startIndex
        while index < value.endIndex {
            let char = value[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if value[index...].hasPrefix(arrow) {
                let head = String(value[..<index])
                let tail = String(value[value.index(index, offsetBy: arrow.count)...])
                return (head, tail.trimmingCharacters(in: .whitespaces))
            }
            index = value.index(after: index)
        }
        return nil
    }

    /// An action half that parsed to a step, or why it was refused.
    private enum ParsedAction {
        case action(SkillStep)
        case refused(String)
    }

    /// The action a check gates or repeats: one plain step. A step that holds
    /// other steps, plays a model loop, changes target or needs an AI client is
    /// refused, so a condition or repeat stays one check and one action.
    private static func parseAction(_ text: String) -> ParsedAction {
        guard let action = SkillParser.parseStep(text) else {
            return .refused("no action after `\(arrow)`")
        }
        switch action {
        case .invalid(let type, let reason):
            return .refused("action \(type): \(reason)")
        case .skipped(let type, _):
            return .refused("action \(type) needs an AI client and cannot be checked")
        case .condition, .repeatUntil, .measure, .scene, .switchTarget:
            return .refused("action \(action.typeKey) cannot be nested: the action is one plain step")
        default:
            return .action(action)
        }
    }

    /// `text` with its leading `word` and the whitespace after it removed, or
    /// nil when `text` does not open with that word.
    private static func dropWord(_ word: String, from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(word) else { return nil }
        let rest = trimmed.dropFirst(word.count)
        guard let first = rest.first, first.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The text inside one pair of matching quotes that makes up all of `text`.
    private static func unquote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'",
              trimmed.last == first else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        return inner.contains(first) ? nil : String(inner)
    }
}
