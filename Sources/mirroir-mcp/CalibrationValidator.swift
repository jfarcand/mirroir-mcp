// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Validates calibration quality by checking unclassified element ratio in the content zone.
// ABOUTME: Hard fails when ratio exceeds threshold, providing diagnostic report for component library gaps.

import Foundation
import HelperLib

/// Validates component detection quality after calibration.
/// Counts unclassified elements in the content zone and fails when the ratio exceeds
/// a configurable threshold. Each unclassified element signals a gap in the component
/// library that may need a new definition in `../mirroir-skills/components/ios/`.
/// Pure transformation: all static methods, no stored state.
enum CalibrationValidator {

    /// Result of calibration validation.
    struct ValidationResult: Sendable {
        /// Whether the calibration passed the quality gate.
        let passed: Bool
        /// Total number of elements in the content zone.
        let totalContentElements: Int
        /// Number of unclassified elements in the content zone.
        let unclassifiedCount: Int
        /// Ratio of unclassified to total content elements (0.0–1.0).
        let unclassifiedRatio: Double
        /// Component summary: count per component kind.
        let componentCounts: [String: Int]
        /// Diagnostic report with matched and unclassified details. Always populated.
        let report: String
    }

    /// Validate calibration quality by checking unclassified element ratio.
    ///
    /// - Parameters:
    ///   - components: Detected screen components (after absorption).
    ///   - screenHeight: Height of the target window for zone calculation.
    ///   - strict: When true, validation fails if ratio exceeds threshold.
    ///   - threshold: Maximum allowed ratio of unclassified content-zone elements.
    /// - Returns: Validation result with diagnostic report.
    static func validate(
        components: [ScreenComponent],
        screenHeight: Double,
        strict: Bool = EnvConfig.calibrationStrict,
        threshold: Double = EnvConfig.calibrationUnclassifiedThreshold
    ) -> ValidationResult {
        let navBarMaxY = screenHeight * ComponentDetector.navBarZoneFraction
        let tabBarMinY = screenHeight * (1 - ComponentDetector.tabBarZoneFraction)

        // Content-zone components: exclude nav_bar and tab_bar zones
        let contentComponents = components.filter { comp in
            let midY = (comp.topY + comp.bottomY) / 2
            return midY >= navBarMaxY && midY <= tabBarMinY
        }

        let unclassified = contentComponents.filter { $0.kind == "unclassified" }
        // Lone "icon" elements are OCR artifacts from chart visualizations (sparklines,
        // activity rings). They aren't real UI components and shouldn't inflate the
        // unclassified ratio or block calibration.
        let iconNoiseCount = unclassified.filter { comp in
            comp.elements.count == 1 && comp.displayLabel == "icon"
        }.count
        let totalCount = contentComponents.count - iconNoiseCount
        let unclassifiedCount = unclassified.count - iconNoiseCount
        let ratio = totalCount > 0 ? Double(unclassifiedCount) / Double(totalCount) : 0.0

        let passed = !strict || ratio <= threshold

        // Build component counts
        var counts: [String: Int] = [:]
        for comp in components {
            counts[comp.kind, default: 0] += 1
        }

        let report = formatReport(
            components: components,
            unclassified: unclassified,
            counts: counts,
            totalContentElements: totalCount,
            unclassifiedCount: unclassifiedCount,
            ratio: ratio,
            passed: passed,
            screenHeight: screenHeight
        )

        return ValidationResult(
            passed: passed,
            totalContentElements: totalCount,
            unclassifiedCount: unclassifiedCount,
            unclassifiedRatio: ratio,
            componentCounts: counts,
            report: report
        )
    }

    // MARK: - Report Formatting

    private static func formatReport(
        components: [ScreenComponent],
        unclassified: [ScreenComponent],
        counts: [String: Int],
        totalContentElements: Int,
        unclassifiedCount: Int,
        ratio: Double,
        passed: Bool,
        screenHeight: Double
    ) -> String {
        var lines: [String] = []

        let status = passed ? "PASSED" : "FAILED"
        lines.append("Calibration validation: \(status)")
        lines.append("  Content elements: \(totalContentElements), " +
            "unclassified: \(unclassifiedCount) " +
            "(ratio: \(String(format: "%.0f", ratio * 100))%)")
        lines.append("")

        // Matched components grouped by kind
        lines.append("Matched components:")
        let matched = counts.filter { $0.key != "unclassified" }
            .sorted { $0.key < $1.key }
        for (kind, count) in matched {
            let labels = components
                .filter { $0.kind == kind }
                .map { $0.displayLabel }
            let labelStr = labels.joined(separator: ", ")
            lines.append("  \(kind) × \(count) (\(labelStr))")
        }

        if !unclassified.isEmpty {
            lines.append("")
            lines.append("Unclassified (may need new component definition):")
            for comp in unclassified {
                guard let tap = comp.tapTarget ?? comp.elements.first?.point else { continue }
                let zone = zoneLabel(y: tap.tapY, screenHeight: screenHeight)
                let elementCount = comp.elements.count
                let chevron = comp.hasChevron ? ", has chevron" : ""
                lines.append("  \"\(comp.displayLabel)\" at " +
                    "(\(Int(tap.tapX)), \(Int(tap.tapY))) — " +
                    "\(zone) zone, \(elementCount) element\(elementCount == 1 ? "" : "s")\(chevron)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func zoneLabel(y: Double, screenHeight: Double) -> String {
        let navBarMaxY = screenHeight * ComponentDetector.navBarZoneFraction
        let tabBarMinY = screenHeight * (1 - ComponentDetector.tabBarZoneFraction)
        if y < navBarMaxY { return "nav_bar" }
        if y > tabBarMinY { return "tab_bar" }
        return "content"
    }
}
