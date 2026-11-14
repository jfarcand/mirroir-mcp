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
// ABOUTME: Builds ranked exploration plans per screen by scoring navigation elements.
// ABOUTME: Scoring uses chevron context, label length, screen position, and scout results.

import Foundation
import HelperLib

/// An element with its computed exploration priority score.
struct RankedElement: Sendable {
    /// The original tap point from OCR.
    let point: TapPoint
    /// Computed priority score — higher means explore sooner.
    let score: Double
    /// Human-readable explanation of the score for debug logging.
    let reason: String
    /// Clean label derived from the component's LabelRule, free of OCR artifacts.
    /// Falls back to `point.text` when no component context is available.
    let displayLabel: String
    /// Whether this element has breadth_navigation role (e.g. tab bar item).
    /// Used by the BFS explorer to exempt these from safe-zone bottom margin checks,
    /// since tab bar items sit at the very bottom of the screen by design.
    let isBreadthNavigation: Bool

    init(point: TapPoint, score: Double, reason: String, displayLabel: String? = nil,
         isBreadthNavigation: Bool = false) {
        self.point = point
        self.score = score
        self.reason = reason
        self.displayLabel = displayLabel ?? point.text
        self.isBreadthNavigation = isBreadthNavigation
    }
}

/// Builds scored exploration plans for screens, prioritizing elements most likely to
/// lead to new screens over ambiguous fallback labels.
/// Pure transformation: all static methods, no stored state.
enum ScreenPlanner {

    // MARK: - Scoring Weights

    /// Bonus for elements whose row had a chevron indicator.
    static let chevronContextWeight: Double = 3.0
    /// Bonus for short, menu-item-like labels (single word, <= 20 chars).
    static let shortLabelWeight: Double = 2.0
    /// Bonus for elements positioned in the middle band of the screen (25%-75%).
    static let midScreenWeight: Double = 1.0
    /// Bonus for elements that scouting confirmed navigate to a new screen.
    static let scoutNavigatedWeight: Double = 5.0
    /// Penalty for elements that scouting confirmed do NOT navigate.
    static let scoutNoChangeWeight: Double = -10.0
    /// Penalty for elements with no chevron context (ambiguous fallback).
    static let fallbackPenalty: Double = -1.0
    /// Penalty for long labels (> 30 chars), which are more likely descriptive text.
    static let longLabelPenalty: Double = -1.0
    /// Bonus for breadth_navigation role (tabs explored first for app coverage).
    static let breadthRoleWeight: Double = 4.0
    /// Bonus for high exploration priority within a role.
    static let highPriorityWeight: Double = 2.0
    /// Penalty for low exploration priority within a role.
    static let lowPriorityWeight: Double = -2.0

    /// Maximum character length to qualify as a "short label".
    static let shortLabelMaxLength = 20
    /// Threshold above which a label is considered "long" (descriptive).
    static let longLabelThreshold = 30

    // MARK: - Plan Building

    /// Build a ranked exploration plan for a screen.
    ///
    /// Scores each navigation-classified element using weighted signals: chevron context,
    /// label length, vertical position, and scout results. Returns elements sorted by
    /// descending score, excluding those already visited.
    ///
    /// - Parameters:
    ///   - classified: All classified elements on the current screen.
    ///   - visitedElements: Element texts already tapped on this screen.
    ///   - scoutResults: Map of element text to scout result (may be empty).
    ///   - screenHeight: Height of the target window for mid-screen calculation.
    /// - Returns: Ranked elements sorted by descending score, with visited elements excluded.
    static func buildPlan(
        classified: [ClassifiedElement],
        visitedElements: Set<String>,
        scoutResults: [String: ScoutResult],
        screenHeight: Double
    ) -> [RankedElement] {
        classified
            .filter { $0.role == .navigation && !visitedElements.contains($0.point.text)
                && $0.point.tapY < screenHeight - TimingConstants.safeBottomMarginPt }
            .map { element in
                let (score, reason) = computeScore(
                    element: element,
                    scoutResults: scoutResults,
                    screenHeight: screenHeight
                )
                return RankedElement(point: element.point, score: score, reason: reason)
            }
            .sorted { $0.point.tapY != $1.point.tapY ? $0.point.tapY < $1.point.tapY : $0.score > $1.score }
    }

    // MARK: - Component-Based Plan Building

    /// Build a ranked exploration plan from detected screen components.
    ///
    /// Filters to explorable components with unvisited tap targets, scores using existing
    /// weights plus exploration role and priority bonuses. Components marked as non-explorable
    /// are excluded entirely, preventing wasted taps on dismiss buttons, toggles, and headers.
    ///
    /// - Parameters:
    ///   - components: Detected screen components with grouped elements.
    ///   - visitedElements: Element texts already tapped on this screen.
    ///   - scoutResults: Map of element text to scout result (may be empty).
    ///   - screenHeight: Height of the target window for mid-screen calculation.
    /// - Returns: Ranked elements sorted by descending score, with visited elements excluded.
    static func buildComponentPlan(
        components: [ScreenComponent],
        visitedElements: Set<String>,
        scoutResults: [String: ScoutResult],
        screenHeight: Double
    ) -> [RankedElement] {
        components
            .compactMap { component -> RankedElement? in
                // Skip non-explorable components (exploration policy, not just UI truth).
                // Uses displayLabel for visited check to avoid collisions when multiple
                // components share the same raw tap target text (e.g. YOLO "icon").
                guard component.definition.exploration.explorable,
                      let tapTarget = component.tapTarget,
                      !visitedElements.contains(component.displayLabel),
                      !ElementClassifier.chevronCharacters.contains(
                          tapTarget.text.trimmingCharacters(in: .whitespaces)
                      ) else {
                    return nil
                }

                // Exclude elements in the home gesture zone at the bottom of the screen.
                // Breadth navigation (tab bar items) is exempt because they are designed
                // to sit at the very bottom and are explicitly marked explorable.
                let isBreadth = component.definition.exploration.role == .breadthNavigation
                guard isBreadth || tapTarget.tapY < screenHeight - TimingConstants.safeBottomMarginPt else {
                    return nil
                }

                let (score, reason) = computeComponentScore(
                    component: component,
                    tapTarget: tapTarget,
                    scoutResults: scoutResults,
                    screenHeight: screenHeight
                )
                return RankedElement(point: tapTarget, score: score, reason: reason,
                    displayLabel: component.displayLabel, isBreadthNavigation: isBreadth)
            }
            // Sort score-first so role/priority/chevron weight wins; tapY
            // is the deterministic tie-breaker (top-down reading order
            // among elements that scored equally).
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.point.tapY < $1.point.tapY }
    }

    // MARK: - Private

    /// Compute the exploration priority score for a component's tap target.
    private static func computeComponentScore(
        component: ScreenComponent,
        tapTarget: TapPoint,
        scoutResults: [String: ScoutResult],
        screenHeight: Double
    ) -> (Double, String) {
        var score: Double = 0
        var reasons: [String] = []
        let text = tapTarget.text

        // Component-level navigation signal
        if component.definition.interaction.clickResult.isNavigational {
            if component.hasChevron {
                score += chevronContextWeight
                reasons.append("chevron +\(Int(chevronContextWeight))")
            } else {
                score += 1.0
                reasons.append("nav +1")
            }
        } else {
            score += fallbackPenalty
            reasons.append("no nav \(Int(fallbackPenalty))")
        }

        // Exploration role bonus: breadth-first components (tabs) explored before depth
        if component.definition.exploration.role == .breadthNavigation {
            score += breadthRoleWeight
            reasons.append("breadth +\(Int(breadthRoleWeight))")
        }

        // Exploration priority bonus/penalty
        switch component.definition.exploration.priority {
        case .high:
            score += highPriorityWeight
            reasons.append("pri:high +\(Int(highPriorityWeight))")
        case .low:
            score += lowPriorityWeight
            reasons.append("pri:low \(Int(lowPriorityWeight))")
        case .normal:
            break
        }

        // Label length signals (same as element-level)
        let trimmedLength = text.trimmingCharacters(in: .whitespaces).count
        let isSingleWord = !text.contains(" ")
        if isSingleWord && trimmedLength <= shortLabelMaxLength {
            score += shortLabelWeight
            reasons.append("short +\(Int(shortLabelWeight))")
        }
        if trimmedLength > longLabelThreshold {
            score += longLabelPenalty
            reasons.append("long \(Int(longLabelPenalty))")
        }

        // Mid-screen position bonus
        let y = tapTarget.tapY
        let lowerBound = screenHeight * 0.25
        let upperBound = screenHeight * 0.75
        if y >= lowerBound && y <= upperBound {
            score += midScreenWeight
            reasons.append("mid +\(Int(midScreenWeight))")
        }

        // Scout results
        if let scoutResult = scoutResults[text] {
            switch scoutResult {
            case .navigated:
                score += scoutNavigatedWeight
                reasons.append("scout:nav +\(Int(scoutNavigatedWeight))")
            case .noChange:
                score += scoutNoChangeWeight
                reasons.append("scout:none \(Int(scoutNoChangeWeight))")
            }
        }

        return (score, reasons.joined(separator: ", "))
    }

    /// Compute the exploration priority score for a single navigation element.
    private static func computeScore(
        element: ClassifiedElement,
        scoutResults: [String: ScoutResult],
        screenHeight: Double
    ) -> (Double, String) {
        var score: Double = 0
        var reasons: [String] = []
        let text = element.point.text

        // Chevron context: row had a ">" indicator
        if element.hasChevronContext {
            score += chevronContextWeight
            reasons.append("chevron +\(Int(chevronContextWeight))")
        } else {
            score += fallbackPenalty
            reasons.append("no chevron \(Int(fallbackPenalty))")
        }

        // Label length signals
        let trimmedLength = text.trimmingCharacters(in: .whitespaces).count
        let isSingleWord = !text.contains(" ")
        if isSingleWord && trimmedLength <= shortLabelMaxLength {
            score += shortLabelWeight
            reasons.append("short +\(Int(shortLabelWeight))")
        }
        if trimmedLength > longLabelThreshold {
            score += longLabelPenalty
            reasons.append("long \(Int(longLabelPenalty))")
        }

        // Mid-screen position bonus (Y between 25%-75%)
        let y = element.point.tapY
        let lowerBound = screenHeight * 0.25
        let upperBound = screenHeight * 0.75
        if y >= lowerBound && y <= upperBound {
            score += midScreenWeight
            reasons.append("mid +\(Int(midScreenWeight))")
        }

        // Scout results
        if let scoutResult = scoutResults[text] {
            switch scoutResult {
            case .navigated:
                score += scoutNavigatedWeight
                reasons.append("scout:nav +\(Int(scoutNavigatedWeight))")
            case .noChange:
                score += scoutNoChangeWeight
                reasons.append("scout:none \(Int(scoutNoChangeWeight))")
            }
        }

        return (score, reasons.joined(separator: ", "))
    }

    // MARK: - Q-Value Boost

    /// Weight applied to Q-value when boosting plan scores.
    static let qValueWeight: Double = 2.0

    /// Apply learned Q-value boosts to a plan and re-sort by adjusted score.
    /// Elements with higher Q-values (led to new screens in past runs) get priority.
    /// Elements with zero Q-value (dead taps in past runs) are demoted to the end.
    ///
    /// Breadth-front invariant: breadth_navigation elements (APP.md tab targets
    /// injected at the front of the plan) keep their existing relative order at
    /// the front of the returned plan and are neither boosted nor re-sorted.
    /// Unknown labels default to q=1.0 (+2.0 boost), so boosting everything
    /// would let content items outrank the deliberately front-injected tabs.
    ///
    /// - Parameters:
    ///   - plan: The ranked plan to boost.
    ///   - qValues: Map from element displayLabel to Q-value (from persisted graph).
    /// - Returns: Breadth items first (order preserved), remainder re-sorted by
    ///   Q-boosted score.
    static func applyQBoost(
        plan: [RankedElement],
        qValues: [String: Double]
    ) -> [RankedElement] {
        guard !qValues.isEmpty else { return plan }
        let breadthFront = plan.filter { $0.isBreadthNavigation }
        var boosted: [RankedElement] = plan
            .filter { !$0.isBreadthNavigation }
            .map { (element: RankedElement) -> RankedElement in
                let q: Double = qValues[element.displayLabel] ?? 1.0
                let boost: Double = q * qValueWeight
                let qLabel: String = String(format: "%.1f", q)
                let reason: String = element.reason + ", q=" + qLabel
                return RankedElement(
                    point: element.point,
                    score: element.score + boost,
                    reason: reason,
                    displayLabel: element.displayLabel,
                    isBreadthNavigation: element.isBreadthNavigation
                )
            }
        // Same score-first ordering as the initial plan rank — see
        // comment on the primary sort site above.
        boosted.sort { $0.score != $1.score ? $0.score > $1.score : $0.point.tapY < $1.point.tapY }
        return breadthFront + boosted
    }
}
