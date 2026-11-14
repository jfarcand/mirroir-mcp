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
// ABOUTME: Post-processing absorption for ScreenComponent rows — merges tightly stacked rows into single units.
// ABOUTME: Extracted from ComponentDetector.swift to stay under the 500-line limit.

import Foundation
import HelperLib

extension ComponentDetector {

    // MARK: - Absorption

    /// Apply absorption to merge multi-row components (like summary cards with multiple
    /// sub-rows of text) based on their definition's `absorbs_below_within_pt` setting.
    /// This ensures multi-row cards (e.g., Health app summary cards) are treated as
    /// single tappable units regardless of which classifier produced them.
    static func applyAbsorption(_ components: [ScreenComponent]) -> [ScreenComponent] {
        let sorted = components.sorted { $0.topY < $1.topY }
        var consumed = Set<Int>()
        var result: [ScreenComponent] = []

        for (i, component) in sorted.enumerated() {
            guard !consumed.contains(i) else { continue }

            let absorbRange = component.definition.grouping.absorbsBelowWithinPt
            guard absorbRange > 0 else {
                result.append(component)
                continue
            }

            let maxY = component.bottomY + absorbRange
            var mergedElements = component.elements

            for j in (i + 1)..<sorted.count {
                guard !consumed.contains(j) else { continue }
                let below = sorted[j]
                guard below.topY <= maxY else { break }

                // Don't absorb components that are themselves absorbers (e.g., another
                // summary-card). Only non-absorbing components should be swallowed.
                guard below.definition.grouping.absorbsBelowWithinPt == 0 else { continue }

                // Don't absorb across zone boundaries (e.g., content card must not
                // swallow tab_bar or nav_bar components).
                guard below.definition.matchRules.zone == component.definition.matchRules.zone else { continue }

                if shouldAbsorb(below.elements, condition: component.definition.grouping.absorbCondition) {
                    mergedElements.append(contentsOf: below.elements)
                    consumed.insert(j)
                }
            }

            if mergedElements.count > component.elements.count {
                // Rebuild with merged elements for Y range and labeling, but
                // preserve original tap target — absorbed elements must not
                // change where the explorer taps.
                let ys = mergedElements.map { $0.point.pageY }
                let hasChevron = mergedElements.contains { element in
                    ElementClassifier.chevronCharacters.contains(
                        element.point.text.trimmingCharacters(in: .whitespaces)
                    )
                }
                result.append(ScreenComponent(
                    kind: component.kind,
                    definition: component.definition,
                    elements: mergedElements,
                    tapTarget: component.tapTarget,
                    hasChevron: hasChevron,
                    topY: ys.min() ?? 0,
                    bottomY: ys.max() ?? 0
                ))
            } else {
                result.append(component)
            }
        }

        return result
    }

    /// Check whether a row of elements should be absorbed into a multi-row component.
    static func shouldAbsorb(
        _ row: [ClassifiedElement],
        condition: AbsorbCondition
    ) -> Bool {
        switch condition {
        case .any:
            return true
        case .infoOrDecorationOnly:
            return row.allSatisfy { $0.role == .info || $0.role == .decoration }
        case .noChevronRowsOnly:
            let hasChevron = row.contains { element in
                let trimmed = element.point.text.trimmingCharacters(in: .whitespaces)
                return ElementClassifier.chevronCharacters.contains(where: { trimmed.hasSuffix($0) })
            }
            return !hasChevron
        }
    }
}
