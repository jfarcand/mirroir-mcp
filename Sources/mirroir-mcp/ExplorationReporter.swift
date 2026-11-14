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
// ABOUTME: Telemetry accumulator for BFSExplorer — per-screen action entries, tap-cache hits, calibration summary.
// ABOUTME: Thread-safe via its own NSLock; replaces scattered lock-guarded dictionary pokes on BFSExplorer.

import Foundation
import HelperLib

/// Collects exploration telemetry (per-screen actions, cache-hit counts,
/// calibration summary) on behalf of an explorer. Thread-safe accumulator —
/// callers do not need to lock around mutations.
///
/// Owns what were three scattered fields on BFSExplorer (`screenActions`,
/// `cacheHitsPerScreen`, `calibrationSummary`) plus their ad-hoc lock pokes.
final class ExplorationReporter: @unchecked Sendable {

    private let lock = NSLock()
    private var screenActions: [String: [ExplorationReportFormatter.ActionEntry]] = [:]
    private var cacheHitsPerScreen: [String: Int] = [:]
    private var calibrationSummary: ExplorationReportFormatter.CalibrationSummary?

    /// Append an action entry for a specific screen.
    func recordAction(fingerprint: String, entry: ExplorationReportFormatter.ActionEntry) {
        lock.lock()
        defer { lock.unlock() }
        screenActions[fingerprint, default: []].append(entry)
    }

    /// Increment the tap-cache-hit count for a screen.
    func recordCacheHit(fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        cacheHitsPerScreen[fingerprint, default: 0] += 1
    }

    /// Store the calibration summary for the explorer's first-screen scan.
    func setCalibrationSummary(_ summary: ExplorationReportFormatter.CalibrationSummary) {
        lock.lock()
        defer { lock.unlock() }
        calibrationSummary = summary
    }

    /// Immutable snapshot for report formatting. Called once at the end of
    /// exploration; returns everything needed to build the final report.
    struct Snapshot {
        let screenActions: [String: [ExplorationReportFormatter.ActionEntry]]
        let cacheHitsPerScreen: [String: Int]
        let calibrationSummary: ExplorationReportFormatter.CalibrationSummary?
        var totalCacheHits: Int { cacheHitsPerScreen.values.reduce(0, +) }
    }

    /// Copy all accumulated state under the lock for safe read-only access
    /// by the report formatter.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            screenActions: screenActions,
            cacheHitsPerScreen: cacheHitsPerScreen,
            calibrationSummary: calibrationSummary
        )
    }
}
