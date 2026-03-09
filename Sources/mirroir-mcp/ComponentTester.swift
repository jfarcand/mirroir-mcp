// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Runs component detection against live OCR and produces a diagnostic report.
// ABOUTME: Used by the calibrate_component MCP tool to validate component definition .md files.

import Foundation
import HelperLib

/// Runs a single component definition against OCR data and produces a diagnostic report.
/// Pure transformation: all static methods, no stored state.
enum ComponentTester {

    /// Run component detection against OCR elements and produce a diagnostic report.
    ///
    /// Shows each row's properties, what definition matched it (from all definitions),
    /// and whether the target definition specifically would match.
    ///
    /// - Parameters:
    ///   - definition: The component definition being tested.
    ///   - elements: Raw OCR tap points from the screen.
    ///   - screenHeight: Height of the target window for zone calculation.
    ///   - allDefinitions: All loaded component definitions for "what actually matched" comparison.
    /// - Returns: A formatted diagnostic report string.
    static func diagnose(
        definition: ComponentDefinition,
        elements: [TapPoint],
        screenHeight: Double,
        allDefinitions: [ComponentDefinition]
    ) -> String {
        var lines: [String] = []

        // Section 1: Definition summary
        lines.append("=== Component Definition ===")
        lines.append("name: \(definition.name)")
        lines.append(
            "zone: \(definition.matchRules.zone.rawValue) | "
            + "clickable: \(definition.interaction.clickable) | "
            + "click_target: \(definition.interaction.clickTarget.rawValue)"
        )
        lines.append(formatMatchRules(definition.matchRules))

        // Handle empty screen
        guard !elements.isEmpty else {
            lines.append("")
            lines.append("=== Screen Analysis (0 OCR elements) ===")
            lines.append("No OCR elements detected on screen.")
            lines.append("")
            lines.append("=== Results ===")
            lines.append("No matches — screen is empty.")
            return lines.joined(separator: "\n")
        }

        // Classify and group into rows
        let classified = ElementClassifier.classify(
            elements, screenHeight: screenHeight
        )
        let rows = ElementClassifier.groupIntoRows(elements)

        // Build classified index for row lookups
        let classifiedByKey = buildClassifiedIndex(classified)

        lines.append("")
        lines.append("=== Screen Analysis (\(elements.count) OCR elements → \(rows.count) rows) ===")

        var matchedRowIndices: [Int] = []

        for (rowIndex, row) in rows.enumerated() {
            let classifiedRow = row.compactMap { point in
                classifiedByKey[elementKey(point)]
            }
            guard !classifiedRow.isEmpty else { continue }

            let rowProps = ComponentDetector.computeRowProperties(
                classifiedRow, screenHeight: screenHeight
            )

            // Format row header
            let yRange = rowProps.topY == rowProps.bottomY
                ? "\(Int(rowProps.topY))"
                : "\(Int(rowProps.topY))-\(Int(rowProps.bottomY))"
            lines.append("")
            let avgConfStr = String(format: "%.2f", rowProps.averageConfidence)
            lines.append(
                "Row \(rowIndex) | zone=\(rowProps.zone.rawValue) | "
                + "elements=\(rowProps.elementCount) | "
                + "chevron=\(rowProps.hasChevron) | "
                + "height=\(Int(rowProps.rowHeight))pt | "
                + "y=\(yRange) | "
                + "avg_conf=\(avgConfStr)"
            )

            // Show element texts with roles and confidence
            let elementDescs = classifiedRow.map { el in
                let conf = String(format: "%.2f", el.point.confidence)
                return "\"\(el.point.text)\" (\(el.role.rawValue), \(conf))"
            }
            lines.append("  \(elementDescs.joined(separator: ", "))")

            // What actually matched from all definitions?
            let actualMatch = ComponentScoring.bestMatch(
                definitions: allDefinitions, rowProps: rowProps
            )

            // Would our target definition match in isolation?
            let targetMatch = ComponentScoring.bestMatch(
                definitions: [definition], rowProps: rowProps
            )

            if let targetMatch = targetMatch {
                let marker = actualMatch?.name == targetMatch.name ? "YOUR COMPONENT" : "YOUR COMPONENT (outscored)"
                lines.append("  ✅ Matched: \(targetMatch.name)  ← \(marker)")
                matchedRowIndices.append(rowIndex)
                if let actual = actualMatch, actual.name != targetMatch.name {
                    lines.append("     (actual winner: \(actual.name))")
                }
            } else if let actual = actualMatch {
                lines.append("  → Matched: \(actual.name)")
            } else {
                lines.append("  → No match (unclassified fallback)")
            }

            // If target didn't match, explain why
            if targetMatch == nil {
                let reasons = explainMismatch(definition: definition, rowProps: rowProps)
                if !reasons.isEmpty {
                    lines.append("  ⓘ Why '\(definition.name)' didn't match: \(reasons.joined(separator: "; "))")
                }
            }
        }

        // Section 3: Results summary
        lines.append("")
        lines.append("=== Results ===")
        if matchedRowIndices.isEmpty {
            lines.append("❌ \(definition.name) matched 0 rows")
            lines.append("   Check the mismatch reasons above for each row.")
        } else {
            let rowList = matchedRowIndices.map { "Row \($0)" }.joined(separator: ", ")
            lines.append("✅ \(definition.name) matched \(matchedRowIndices.count) row(s): [\(rowList)]")
            for idx in matchedRowIndices {
                let row = rows[idx]
                let elementTexts = row.map { "\"\($0.text)\"" }.joined(separator: ", ")
                let classifiedRow = row.compactMap { classifiedByKey[elementKey($0)] }
                let tapTarget = resolveTapTarget(classifiedRow, definition: definition)
                let tapDesc = tapTarget.map { "\"\($0.text)\"" } ?? "nil"
                let clickableDesc = definition.interaction.clickable ? "clickable" : "non-clickable"
                lines.append("   Row \(idx): elements=[\(elementTexts)], tapTarget=\(tapDesc) (\(clickableDesc))")
            }
        }

        // Section 4: Detection pipeline view (what BFS actually sees after absorption)
        let detectionView = formatDetectionView(
            classified: classified,
            allDefinitions: allDefinitions,
            screenHeight: screenHeight
        )
        lines.append("")
        lines.append(detectionView)

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    /// Format match rules for the definition summary section.
    static func formatMatchRules(_ rules: ComponentMatchRules) -> String {
        var parts: [String] = []
        parts.append("min_elements=\(rules.minElements)")
        parts.append("max_elements=\(rules.maxElements)")
        parts.append("max_row_height_pt=\(Int(rules.maxRowHeightPt))")

        var optionals: [String] = []
        if let mode = rules.chevronMode {
            optionals.append("chevron_mode=\(mode.rawValue)")
        } else {
            optionals.append("row_has_chevron=\(rules.rowHasChevron.map(String.init) ?? "nil")")
        }
        optionals.append("has_numeric=\(rules.hasNumericValue.map(String.init) ?? "nil")")
        optionals.append("has_long_text=\(rules.hasLongText.map(String.init) ?? "nil")")
        optionals.append("has_dismiss=\(rules.hasDismissButton.map(String.init) ?? "nil")")
        if let minConf = rules.minConfidence {
            optionals.append("min_confidence=\(String(format: "%.2f", minConf))")
        }
        if let excludeNum = rules.excludeNumericOnly {
            optionals.append("exclude_numeric_only=\(excludeNum)")
        }
        if let textPattern = rules.textPattern {
            optionals.append("text_pattern=\(textPattern)")
        }

        return "match_rules: \(parts.joined(separator: ", ")), \(optionals.joined(separator: ", "))"
    }

    // MARK: - Mismatch Explanation

    /// Explain why a definition didn't match a row's properties.
    /// Returns a list of human-readable reasons for each failed constraint.
    static func explainMismatch(
        definition: ComponentDefinition,
        rowProps: ComponentDetector.RowProperties
    ) -> [String] {
        let rules = definition.matchRules
        var reasons: [String] = []

        if rules.zone != rowProps.zone {
            reasons.append("zone: need \(rules.zone.rawValue), got \(rowProps.zone.rawValue)")
        }
        let effectiveCount = rules.excludeNumericOnly == true
            ? rowProps.elementCount - rowProps.numericOnlyCount
            : rowProps.elementCount
        if effectiveCount < rules.minElements {
            reasons.append("too few elements: need ≥\(rules.minElements), got \(effectiveCount)")
        }
        if effectiveCount > rules.maxElements {
            reasons.append("too many elements: need ≤\(rules.maxElements), got \(effectiveCount)")
        }
        if rowProps.rowHeight > rules.maxRowHeightPt {
            reasons.append("row too tall: need ≤\(Int(rules.maxRowHeightPt))pt, got \(Int(rowProps.rowHeight))pt")
        }
        if let mode = rules.chevronMode {
            switch mode {
            case .required where !rowProps.hasChevron:
                reasons.append("chevron: required but absent")
            case .forbidden where rowProps.hasChevron:
                reasons.append("chevron: forbidden but present")
            case .preferred where !rowProps.hasChevron:
                // Not a mismatch — score penalty only
                break
            default:
                break
            }
        } else if let requireChevron = rules.rowHasChevron, requireChevron != rowProps.hasChevron {
            reasons.append("chevron: need \(requireChevron), got \(rowProps.hasChevron)")
        }
        if let requireNumeric = rules.hasNumericValue, requireNumeric != rowProps.hasNumericValue {
            reasons.append("numeric: need \(requireNumeric), got \(rowProps.hasNumericValue)")
        }
        if let requireLongText = rules.hasLongText, requireLongText != rowProps.hasLongText {
            reasons.append("long_text: need \(requireLongText), got \(rowProps.hasLongText)")
        }
        if let requireDismiss = rules.hasDismissButton, requireDismiss != rowProps.hasDismissButton {
            reasons.append("dismiss: need \(requireDismiss), got \(rowProps.hasDismissButton)")
        }
        if let minConf = rules.minConfidence, rowProps.averageConfidence < minConf {
            let got = String(format: "%.2f", rowProps.averageConfidence)
            let need = String(format: "%.2f", minConf)
            reasons.append("confidence: need ≥\(need), got \(got)")
        }
        if let pattern = rules.textPattern {
            let regex = try? NSRegularExpression(pattern: pattern)
            let anyMatch = regex.map { rx in
                rowProps.elementTexts.contains { text in
                    let range = NSRange(text.startIndex..., in: text)
                    return rx.firstMatch(in: text, range: range) != nil
                }
            } ?? false
            if !anyMatch {
                reasons.append("text_pattern: no element matches /\(pattern)/")
            }
        }

        return reasons
    }

    // MARK: - Detection Pipeline View

    /// Format the detection pipeline view showing what BFS actually sees after absorption.
    /// Runs full detect() + applyAbsorption() and formats each resulting ScreenComponent.
    static func formatDetectionView(
        classified: [ClassifiedElement],
        allDefinitions: [ComponentDefinition],
        screenHeight: Double
    ) -> String {
        let raw = ComponentDetector.detect(
            classified: classified,
            definitions: allDefinitions,
            screenHeight: screenHeight
        )
        let components = ComponentDetector.applyAbsorption(raw)

        var lines: [String] = []
        lines.append("=== Detection Result (after absorption) ===")

        if components.isEmpty {
            lines.append("No components detected.")
            return lines.joined(separator: "\n")
        }

        let absorbedCount = raw.count - components.count
        lines.append("\(components.count) component(s) (\(absorbedCount) absorbed)")

        for component in components {
            let yRange = component.topY == component.bottomY
                ? "\(Int(component.topY))"
                : "\(Int(component.topY))-\(Int(component.bottomY))"

            // Count how many elements were absorbed from other rows
            let originalCount = raw.first { $0.kind == component.kind && $0.topY == component.topY }
                .map { $0.elements.count } ?? component.elements.count
            let absorbedElements = component.elements.count - originalCount

            var header = "  \(component.kind) [y=\(yRange)] → \(component.elements.count) element(s)"
            if absorbedElements > 0 {
                header += " (\(absorbedElements) absorbed)"
            }
            lines.append(header)

            // Element texts
            let texts = component.elements.map { "\"\($0.point.text)\"" }.joined(separator: ", ")
            lines.append("    \(texts)")

            // Tap target
            if let tap = component.tapTarget {
                let clickDesc = component.definition.interaction.clickResult.rawValue
                lines.append("    tapTarget: \"\(tap.text)\" (\(clickDesc))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

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

    /// Position-based key for an element.
    private static func elementKey(_ point: TapPoint) -> String {
        "\(point.text)@\(Int(point.tapX)),\(Int(point.tapY))"
    }

    /// Resolve the tap target for a matched row using the definition's click target rule.
    private static func resolveTapTarget(
        _ row: [ClassifiedElement],
        definition: ComponentDefinition
    ) -> TapPoint? {
        guard definition.interaction.clickable else { return nil }

        switch definition.interaction.clickTarget {
        case .firstNavigation:
            if let nav = row.first(where: { $0.role == .navigation }) {
                return nav.point
            }
            return row.first(where: { $0.role != .decoration })?.point
        case .firstText:
            return row.first(where: {
                $0.role != .decoration && $0.point.text != "icon"
            })?.point
        case .firstDismissButton:
            if let dismiss = row.first(where: { element in
                ElementClassifier.dismissCharacters.contains(
                    element.point.text.trimmingCharacters(in: .whitespaces)
                )
            }) {
                return dismiss.point
            }
            return row.first(where: { $0.role != .decoration })?.point
        case .centered:
            let sorted = row.sorted { $0.point.tapX < $1.point.tapX }
            return sorted[sorted.count / 2].point
        case .none:
            return nil
        }
    }
}
