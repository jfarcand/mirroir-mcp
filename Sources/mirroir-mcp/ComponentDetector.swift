// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Groups OCR elements into UI components using loaded component definitions.
// ABOUTME: Heuristic matching based on row properties, zone position, and element patterns.

import Foundation
import HelperLib

/// A detected UI component grouping one or more OCR elements.
struct ScreenComponent: Sendable {
    /// Component name from the matched definition (e.g. "table-row-disclosure").
    let kind: String
    /// The matched component definition.
    let definition: ComponentDefinition
    /// All OCR elements belonging to this component.
    let elements: [ClassifiedElement]
    /// Best element to tap (nil for non-interactive components).
    let tapTarget: TapPoint?
    /// Whether any element in this component is a chevron.
    let hasChevron: Bool
    /// Top Y coordinate of this component's bounding box.
    let topY: Double
    /// Bottom Y coordinate of this component's bounding box.
    let bottomY: Double

    /// Human-readable label derived from the component's elements using the label rule.
    /// Prevents raw OCR artifacts ("icon", ">") from leaking into skill step names.
    var displayLabel: String {
        switch definition.interaction.labelRule {
        case .tapTarget:
            return tapTarget?.text ?? fallbackLabel
        case .firstText:
            if let first = elements.first(where: {
                $0.role != .decoration && $0.point.text != "icon"
                    && !ElementClassifier.chevronCharacters.contains($0.point.text.trimmingCharacters(in: .whitespaces))
            }) {
                return first.point.text
            }
            return fallbackLabel
        case .longestText:
            if let longest = elements
                .filter({ $0.role != .decoration })
                .max(by: { $0.point.text.count < $1.point.text.count }) {
                return longest.point.text
            }
            return fallbackLabel
        }
    }

    /// Fallback: first non-decoration element text, or the component kind.
    private var fallbackLabel: String {
        elements.first(where: { $0.role != .decoration })?.point.text ?? kind
    }
}

/// Groups classified OCR elements into UI components using loaded definitions.
/// Pure transformation: all static methods, no stored state.
enum ComponentDetector {

    /// Fraction of screen height defining the nav bar zone at the top.
    static let navBarZoneFraction: Double = 0.12
    /// Fraction of screen height defining the tab bar zone at the bottom.
    static let tabBarZoneFraction: Double = 0.12
    /// Numeric value regex for matching summary cards and value-containing components.
    private static let numericPattern = try! NSRegularExpression(
        pattern: #"\d+([.,]\d+)?"#
    )

    /// Group classified OCR elements into UI components using loaded definitions.
    ///
    /// Algorithm:
    /// 1. Zone partition (nav bar top ~12%, tab bar bottom ~12%, content middle)
    /// 2. Row grouping via ElementClassifier.groupIntoRows()
    /// 3. For each row, match against component definitions (most specific first)
    /// 4. Apply grouping rules to absorb adjacent rows into multi-row components
    /// 5. Unmatched elements become single-element components using their ClassifiedElement role
    ///
    /// - Parameters:
    ///   - classified: All classified elements on the screen.
    ///   - definitions: Loaded component definitions to match against.
    ///   - screenHeight: Height of the target window for zone calculation.
    /// - Returns: Detected components with grouped elements and tap targets.
    static func detect(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent] {
        guard !classified.isEmpty else { return [] }

        let rows = ElementClassifier.groupIntoRows(
            classified.map { $0.point }
        )

        // Build row → classified elements mapping
        let classifiedByKey = buildClassifiedIndex(classified)
        let classifiedRows: [[ClassifiedElement]] = rows.map { row in
            row.compactMap { point in
                classifiedByKey[elementKey(point)]
            }
        }

        // Match each row against definitions, then absorb nearby rows
        var components: [ScreenComponent] = []
        var consumedRowIndices = Set<Int>()

        for (rowIndex, classifiedRow) in classifiedRows.enumerated() {
            guard !consumedRowIndices.contains(rowIndex) else { continue }
            guard !classifiedRow.isEmpty else { continue }

            let rowProps = computeRowProperties(
                classifiedRow, screenHeight: screenHeight
            )

            // Try matching against definitions (most specific first)
            if let match = bestMatch(
                definitions: definitions, rowProps: rowProps
            ) {
                var allElements = classifiedRow
                consumedRowIndices.insert(rowIndex)

                // Apply absorption rules to adjacent rows below
                if match.grouping.absorbsBelowWithinPt > 0 {
                    let maxY = rowProps.bottomY + match.grouping.absorbsBelowWithinPt
                    for belowIndex in (rowIndex + 1)..<classifiedRows.count {
                        guard !consumedRowIndices.contains(belowIndex) else { continue }
                        let belowRow = classifiedRows[belowIndex]
                        guard !belowRow.isEmpty else { continue }

                        let belowTopY = belowRow.map { $0.point.pageY }.min() ?? 0
                        guard belowTopY <= maxY else { break }

                        let canAbsorb = shouldAbsorb(
                            belowRow, condition: match.grouping.absorbCondition
                        )
                        if canAbsorb {
                            allElements.append(contentsOf: belowRow)
                            consumedRowIndices.insert(belowIndex)
                        }
                    }
                }

                // Split into per-item components when split_mode is per_item
                if match.grouping.splitMode == .perItem {
                    let splitComponents = splitIntoPerItem(
                        definition: match, elements: allElements
                    )
                    components.append(contentsOf: splitComponents)
                } else {
                    let component = buildComponent(
                        kind: match.name, definition: match,
                        elements: allElements,
                        anchorElements: classifiedRow
                    )
                    components.append(component)
                }
            } else {
                // No definition matched — create per-element fallback components
                consumedRowIndices.insert(rowIndex)
                for element in classifiedRow {
                    let fallback = buildFallbackComponent(element: element)
                    components.append(fallback)
                }
            }
        }

        return components.sorted { $0.topY < $1.topY }
    }

    // MARK: - Row Properties

    /// Properties computed from a row of classified elements for matching.
    struct RowProperties {
        let elementCount: Int
        let hasChevron: Bool
        let hasNumericValue: Bool
        let rowHeight: Double
        let topY: Double
        let bottomY: Double
        let zone: ScreenZone
        let hasStateIndicator: Bool
        let hasLongText: Bool
        let hasDismissButton: Bool
        /// Mean OCR confidence across all elements in the row.
        let averageConfidence: Double
        /// Count of bare-digit elements (1-3 chars, all digits) like "23" or "5".
        let numericOnlyCount: Int
        /// Raw text of each element in the row (for text_pattern matching).
        let elementTexts: [String]
    }

    /// Compute properties for a row of classified elements.
    static func computeRowProperties(
        _ row: [ClassifiedElement],
        screenHeight: Double
    ) -> RowProperties {
        // Page-absolute Y for topY/bottomY — correct ordering and absorption
        // after multi-viewport merges where elements carry scroll-adjusted pageY.
        let pageYs = row.map { $0.point.pageY }
        let topY = pageYs.min() ?? 0
        let bottomY = pageYs.max() ?? 0

        // Zone detection uses viewport-relative tapY because zones (nav bar top 12%,
        // tab bar bottom 12%) are defined relative to the viewport, not the full page.
        let viewportYs = row.map { $0.point.tapY }
        let viewportMidY = ((viewportYs.min() ?? 0) + (viewportYs.max() ?? 0)) / 2

        let zone: ScreenZone
        if screenHeight > 0 && viewportMidY < screenHeight * navBarZoneFraction {
            zone = .navBar
        } else if screenHeight > 0 && viewportMidY > screenHeight * (1 - tabBarZoneFraction) {
            zone = .tabBar
        } else {
            zone = .content
        }

        let hasChevron = row.contains { element in
            let trimmed = element.point.text.trimmingCharacters(in: .whitespaces)
            // Exact match (element is just ">") or embedded (text ends with " >")
            return ElementClassifier.chevronCharacters.contains(where: { trimmed.hasSuffix($0) })
        }

        let hasNumericValue = row.contains { element in
            containsNumericValue(element.point.text)
        }

        let hasStateIndicator = row.contains { element in
            ElementClassifier.stateIndicators.contains(
                element.point.text.lowercased().trimmingCharacters(in: .whitespaces)
            )
        }

        let longTextThreshold = 50
        let hasLongText = row.contains { $0.point.text.count > longTextThreshold }

        let hasDismissButton = row.contains { element in
            ElementClassifier.dismissCharacters.contains(
                element.point.text.trimmingCharacters(in: .whitespaces)
            )
        }

        let avgConf = row.isEmpty
            ? 0.0
            : row.map { Double($0.point.confidence) }.reduce(0, +) / Double(row.count)
        let numericOnlyCount = row.filter {
            isShortNumericOnly($0.point.text)
        }.count
        let elementTexts = row.map { $0.point.text }

        return RowProperties(
            elementCount: row.count,
            hasChevron: hasChevron,
            hasNumericValue: hasNumericValue,
            rowHeight: bottomY - topY,
            topY: topY,
            bottomY: bottomY,
            zone: zone,
            hasStateIndicator: hasStateIndicator,
            hasLongText: hasLongText,
            hasDismissButton: hasDismissButton,
            averageConfidence: avgConf,
            numericOnlyCount: numericOnlyCount,
            elementTexts: elementTexts
        )
    }

    // MARK: - Matching

    /// Score each definition against row properties, return the best match that passes
    /// all non-nil constraints. Returns nil if no definition matches.
    /// Delegates to ComponentScoring for the actual scoring logic.
    static func bestMatch(
        definitions: [ComponentDefinition],
        rowProps: RowProperties
    ) -> ComponentDefinition? {
        ComponentScoring.bestMatch(definitions: definitions, rowProps: rowProps)
    }

    // MARK: - Absorption

    /// Post-process components by applying absorption rules.
    /// Components with `absorbsBelowWithinPt > 0` absorb nearby components below them.
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

    // MARK: - Split Mode

    /// Split a matched row into one component per non-decoration element.
    /// Each element becomes its own ScreenComponent with its own tap target,
    /// enabling per-item exploration of multi-target containers like tab bars.
    private static func splitIntoPerItem(
        definition: ComponentDefinition,
        elements: [ClassifiedElement]
    ) -> [ScreenComponent] {
        let qualifying = elements.filter { $0.role != .decoration }
        guard !qualifying.isEmpty else {
            return [buildComponent(kind: definition.name, definition: definition, elements: elements)]
        }

        return qualifying.map { element in
            buildComponent(
                kind: definition.name, definition: definition,
                elements: [element]
            )
        }
    }

    // MARK: - Component Building

    /// Build a ScreenComponent from matched definition and grouped elements.
    ///
    /// - Parameter anchorElements: Elements from the original matched row, used
    ///   for tap target selection. When absorption merges additional rows into
    ///   `elements`, those absorbed elements must not become the tap target.
    ///   Pass the pre-absorption row here; defaults to `elements` when nil.
    private static func buildComponent(
        kind: String,
        definition: ComponentDefinition,
        elements: [ClassifiedElement],
        anchorElements: [ClassifiedElement]? = nil
    ) -> ScreenComponent {
        let ys = elements.map { $0.point.pageY }
        let topY = ys.min() ?? 0
        let bottomY = ys.max() ?? 0

        let hasChevron = elements.contains { element in
            ElementClassifier.chevronCharacters.contains(
                element.point.text.trimmingCharacters(in: .whitespaces)
            )
        }

        let tapTarget = selectTapTarget(
            elements: anchorElements ?? elements,
            rule: definition.interaction.clickTarget,
            clickable: definition.interaction.clickable
        )

        return ScreenComponent(
            kind: kind,
            definition: definition,
            elements: elements,
            tapTarget: tapTarget,
            hasChevron: hasChevron,
            topY: topY,
            bottomY: bottomY
        )
    }

    /// Build a fallback single-element component when no definition matched.
    /// Navigation-classified elements remain explorable so they aren't lost
    /// when the heuristic matcher can't group them into a known component.
    private static func buildFallbackComponent(
        element: ClassifiedElement
    ) -> ScreenComponent {
        let isNav = element.role == .navigation
        let fallbackDef = ComponentDefinition(
            name: "unclassified",
            platform: "ios",
            description: "Element not matching any component definition.",
            visualPattern: [],
            matchRules: ComponentMatchRules(
                rowHasChevron: nil, chevronMode: nil, minElements: 1, maxElements: 1,
                maxRowHeightPt: 100, hasNumericValue: nil, hasLongText: nil,
                hasDismissButton: nil, zone: .content,
                minConfidence: nil, excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: isNav,
                clickTarget: isNav ? .firstNavigation : .none,
                clickResult: isNav ? .pushesScreen : .none,
                backAfterClick: isNav,
                labelRule: .tapTarget
            ),
            exploration: ComponentExploration(
                explorable: isNav,
                role: isNav ? .depthNavigation : .info,
                priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: false,
                absorbsBelowWithinPt: 0,
                absorbCondition: .any,
                splitMode: .none
            )
        )

        return ScreenComponent(
            kind: "unclassified",
            definition: fallbackDef,
            elements: [element],
            tapTarget: isNav ? element.point : nil,
            hasChevron: element.hasChevronContext,
            topY: element.point.pageY,
            bottomY: element.point.pageY
        )
    }

    /// Select the best tap target within a component's elements based on the click target rule.
    private static func selectTapTarget(
        elements: [ClassifiedElement],
        rule: ClickTargetRule,
        clickable: Bool
    ) -> TapPoint? {
        guard clickable else { return nil }

        switch rule {
        case .firstNavigation:
            // Prefer navigation-classified elements, then any non-decoration element
            if let nav = elements.first(where: { $0.role == .navigation }) {
                return nav.point
            }
            return elements.first(where: { $0.role != .decoration })?.point

        case .firstText:
            // First element with real text content (skip "icon" and decoration)
            return elements.first(where: {
                $0.role != .decoration && $0.point.text != "icon"
            })?.point

        case .firstDismissButton:
            // Find the dismiss button (X, ✕, ×) in the component's elements
            if let dismiss = elements.first(where: { element in
                ElementClassifier.dismissCharacters.contains(
                    element.point.text.trimmingCharacters(in: .whitespaces)
                )
            }) {
                return dismiss.point
            }
            return elements.first(where: { $0.role != .decoration })?.point

        case .centered:
            // Pick the element closest to the horizontal center
            let sorted = elements.sorted { $0.point.tapX < $1.point.tapX }
            return sorted[sorted.count / 2].point

        case .none:
            return nil
        }
    }

    // MARK: - Helpers

    /// Check if text is a short bare-digit string (1-3 characters, all digits).
    /// Used to identify OCR-hallucinated badge numbers or icon artifacts like "23" or "5".
    private static func isShortNumericOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 3 && trimmed.allSatisfy { $0.isNumber }
    }

    /// Check if text contains a numeric value (e.g. "12,4km", "3.2 GB", "50%").
    private static func containsNumericValue(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return numericPattern.firstMatch(in: text, range: range) != nil
    }

    /// Build an index of classified elements keyed by position-based key.
    private static func buildClassifiedIndex(
        _ classified: [ClassifiedElement]
    ) -> [String: ClassifiedElement] {
        var index: [String: ClassifiedElement] = [:]
        for element in classified {
            index[elementKey(element.point)] = element
        }
        return index
    }

    /// Position-based key for an element (matches ElementClassifier convention).
    private static func elementKey(_ point: TapPoint) -> String {
        "\(point.text)@\(Int(point.tapX)),\(Int(point.tapY))"
    }
}
