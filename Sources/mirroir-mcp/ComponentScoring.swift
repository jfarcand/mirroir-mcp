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
// ABOUTME: Scores component definitions against row properties for best-match selection.
// ABOUTME: Extracted from ComponentDetector to keep file sizes under 500 lines.

import Foundation

/// Scores component definitions against OCR row properties.
/// Pure transformation: all static methods, no stored state.
enum ComponentScoring {

    /// Score each definition against row properties, return the best match that passes
    /// all non-nil constraints. Returns nil if no definition matches.
    static func bestMatch(
        definitions: [ComponentDefinition],
        rowProps: ComponentDetector.RowProperties
    ) -> ComponentDefinition? {
        var bestDef: ComponentDefinition?
        var bestScore: Double = -1

        for definition in definitions {
            guard let score = scoreMatch(definition: definition, rowProps: rowProps) else {
                continue
            }
            if score > bestScore {
                bestScore = score
                bestDef = definition
            }
        }

        return bestDef
    }

    /// Score how well a definition matches row properties.
    /// Returns nil if any hard constraint fails; otherwise returns a specificity score.
    static func scoreMatch(
        definition: ComponentDefinition,
        rowProps: ComponentDetector.RowProperties
    ) -> Double? {
        let rules = definition.matchRules
        var score: Double = 0

        // Hard constraint: zone must match
        if rules.zone != rowProps.zone {
            return nil
        }

        // Hard constraint: element count in range.
        // When exclude_numeric_only is set, use effective count (excluding bare-digit elements).
        let effectiveCount = rules.excludeNumericOnly == true
            ? rowProps.elementCount - rowProps.numericOnlyCount
            : rowProps.elementCount
        if effectiveCount < rules.minElements || effectiveCount > rules.maxElements {
            return nil
        }

        // Hard constraint: row height within limit
        if rowProps.rowHeight > rules.maxRowHeightPt {
            return nil
        }

        // Chevron constraint: behavior depends on chevronMode
        if let mode = rules.chevronMode {
            switch mode {
            case .required:
                if !rowProps.hasChevron { return nil }
                score += 3.0
            case .forbidden:
                if rowProps.hasChevron { return nil }
                score += 1.0
            case .preferred:
                // Soft constraint: bonus when present, no penalty when absent
                if rowProps.hasChevron {
                    score += 3.0
                }
            }
        } else if let requireChevron = rules.rowHasChevron {
            // Legacy path: row_has_chevron boolean (hard constraint)
            if requireChevron != rowProps.hasChevron {
                return nil
            }
            score += requireChevron ? 3.0 : 1.0
        }

        // Hard constraint: numeric value requirement
        if let requireNumeric = rules.hasNumericValue {
            if requireNumeric != rowProps.hasNumericValue {
                return nil
            }
            score += 2.0
        }

        // Hard constraint: long text requirement
        if let requireLongText = rules.hasLongText {
            if requireLongText != rowProps.hasLongText {
                return nil
            }
            score += 2.0
        }

        // Hard constraint: dismiss button requirement
        if let requireDismiss = rules.hasDismissButton {
            if requireDismiss != rowProps.hasDismissButton {
                return nil
            }
            score += 3.0
        }

        // Hard constraint: average row OCR confidence
        if let minConf = rules.minConfidence, rowProps.averageConfidence < minConf {
            return nil
        }

        // Hard constraint: text pattern -- at least one element must match regex
        if let pattern = rules.textPattern,
           let regex = try? NSRegularExpression(pattern: pattern) {
            let anyMatch = rowProps.elementTexts.contains { text in
                let range = NSRange(text.startIndex..., in: text)
                return regex.firstMatch(in: text, range: range) != nil
            }
            if !anyMatch { return nil }
        }

        // Specificity bonuses: tighter ranges score higher
        let elementRange = rules.maxElements - rules.minElements
        if elementRange < 3 {
            score += 1.0
        }

        // Zone-specific bonus (nav bar and tab bar are more specific)
        if rules.zone == .navBar || rules.zone == .tabBar {
            score += 2.0
        }

        return score
    }
}
