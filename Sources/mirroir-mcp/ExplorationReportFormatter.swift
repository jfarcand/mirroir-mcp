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
// ABOUTME: Formats structured exploration reports for calibration and exploration results.
// ABOUTME: Pure transformation: enum namespace with static methods, no stored state.

import Foundation
import HelperLib

/// Formats detailed exploration reports for output to the MCP client.
/// Provides calibration summaries, per-screen exploration details, and
/// component detection breakdowns for debugging and transparency.
enum ExplorationReportFormatter {

    /// Entry for a single exploration action in the report.
    struct ActionEntry: Sendable {
        /// Display label of the tapped element.
        let label: String
        /// Coordinates of the tap.
        let x: Double
        let y: Double
        /// Result of the tap action.
        let result: String
        /// Whether the tap was skipped due to tap area cache.
        let skippedByCache: Bool
    }

    /// Summary of calibration scroll results.
    struct CalibrationSummary: Sendable {
        /// Number of scroll gestures performed.
        let scrollCount: Int
        /// Number of new elements discovered by scrolling.
        let newElementCount: Int
        /// Total elements on the root screen after calibration.
        let totalElements: Int
        /// Whether CalibrationScroller was used (vs simple scroll fallback).
        let usedCalibrationScroller: Bool
        /// Number of components detected after calibration (nil if not run).
        let componentCount: Int?
        /// Number of unclassified content-zone elements (nil if not run).
        let unclassifiedCount: Int?
        /// Whether calibration validation passed (nil if not run).
        let validationPassed: Bool?
        /// Calibration validation diagnostic report (nil if not run).
        let validationReport: String?

        init(scrollCount: Int, newElementCount: Int, totalElements: Int,
             usedCalibrationScroller: Bool, componentCount: Int? = nil,
             unclassifiedCount: Int? = nil, validationPassed: Bool? = nil,
             validationReport: String? = nil) {
            self.scrollCount = scrollCount
            self.newElementCount = newElementCount
            self.totalElements = totalElements
            self.usedCalibrationScroller = usedCalibrationScroller
            self.componentCount = componentCount
            self.unclassifiedCount = unclassifiedCount
            self.validationPassed = validationPassed
            self.validationReport = validationReport
        }
    }

    /// Per-screen exploration summary.
    struct ScreenSummary: Sendable {
        /// BFS depth of the screen.
        let depth: Int
        /// Screen fingerprint (truncated for display).
        let fingerprint: String
        /// Number of components detected on the screen.
        let componentCount: Int
        /// Number of actions performed on the screen.
        let actionCount: Int
        /// Tap cache hits (skipped taps).
        let cacheHits: Int
        /// Actions taken with their results.
        let actions: [ActionEntry]
    }

    // MARK: - Formatting

    /// Format the calibration summary section of the report.
    static func formatCalibration(_ summary: CalibrationSummary) -> String {
        var lines: [String] = []
        lines.append("## Calibration Report")
        lines.append("- Method: \(summary.usedCalibrationScroller ? "CalibrationScroller" : "Simple scroll")")
        lines.append("- Scrolls: \(summary.scrollCount)")
        lines.append("- New elements discovered: \(summary.newElementCount)")
        lines.append("- Total elements on root screen: \(summary.totalElements)")
        return lines.joined(separator: "\n")
    }

    /// Format the full exploration report.
    static func formatExplorationReport(
        appName: String,
        calibration: CalibrationSummary?,
        screens: [ScreenSummary],
        stats: (nodeCount: Int, edgeCount: Int, actionCount: Int, elapsedSeconds: Int),
        tapCacheTotal: Int,
        graphStructure: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("# Exploration Report: \(appName)")
        lines.append("")
        lines.append("## Summary")
        lines.append("- Screens discovered: \(stats.nodeCount)")
        lines.append("- Navigation edges: \(stats.edgeCount)")
        lines.append("- Total actions: \(stats.actionCount)")
        lines.append("- Duration: \(stats.elapsedSeconds)s")
        lines.append("- Tap cache saves: \(tapCacheTotal)")
        lines.append("")

        if let structure = graphStructure, !structure.isEmpty {
            lines.append(structure)
            lines.append("")
        }

        if let cal = calibration {
            lines.append(formatCalibration(cal))
            lines.append("")
        }

        if !screens.isEmpty {
            lines.append("## Per-Screen Details")
            for screen in screens {
                lines.append("")
                lines.append("### Depth \(screen.depth) — \(screen.fingerprint)")
                lines.append("- Components: \(screen.componentCount)")
                lines.append("- Actions: \(screen.actionCount) (cache hits: \(screen.cacheHits))")
                if !screen.actions.isEmpty {
                    for action in screen.actions {
                        let prefix = action.skippedByCache ? "  SKIP" : "  TAP "
                        lines.append("\(prefix) \"\(action.label)\" " +
                            "(\(Int(action.x)),\(Int(action.y))) → \(action.result)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Render a "Graph Structure" section from the final navigation-graph
    /// snapshot: SCC "rooms" (GraphAnalyzer) plus the gateway screens
    /// (DominatorTree) that every path from root must traverse. Diagnostic only
    /// — it surfaces chokepoints and screen clusters without changing which
    /// paths exploration or skill generation selects.
    static func formatGraphStructure(snapshot: GraphSnapshot) -> String {
        var lines: [String] = ["## Graph Structure"]
        lines.append("- Rooms: \(GraphAnalyzer.roomSummary(snapshot: snapshot))")

        let gateways = DominatorTree.gateways(snapshot: snapshot)
            .sorted { $0.dominatedCount > $1.dominatedCount }
        if gateways.isEmpty {
            lines.append("- Gateway screens: none")
        } else {
            lines.append("- Gateway screens (chokepoints all paths traverse):")
            for gateway in gateways.prefix(5) {
                let plural = gateway.dominatedCount == 1 ? "" : "s"
                lines.append("  - \(gateway.fingerprint.prefix(8)) dominates "
                    + "\(gateway.dominatedCount) screen\(plural)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
