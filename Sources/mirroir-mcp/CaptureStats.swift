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
// ABOUTME: Counts how each screen capture was taken: ScreenCaptureKit, or the screencapture CLI fallback and why.
// ABOUTME: `mirroir test` prints the totals so a run (and CI) can see a capture path silently degrading.

import Foundation

/// Point-in-time totals from `CaptureStats`.
struct CaptureStatsSnapshot: Equatable, Sendable {
    /// Captures ScreenCaptureKit answered.
    let sck: Int
    /// Captures that fell back to the `screencapture` CLI, by reason.
    let fallbackReasons: [WindowShotFailure: Int]

    /// Total fallbacks across every reason.
    var fallback: Int { fallbackReasons.values.reduce(0, +) }

    /// One-line summary, e.g. `capture: sck=4 fallback=1 (handler_dropped=1)`.
    /// The reason list appears only when something fell back.
    var summaryLine: String {
        let base = "capture: sck=\(sck) fallback=\(fallback)"
        guard fallback > 0 else { return base }
        let reasons = WindowShotFailure.allCases
            .compactMap { reason in
                fallbackReasons[reason].map { "\(reason.rawValue)=\($0)" }
            }
            .joined(separator: ", ")
        return base + " (\(reasons))"
    }
}

/// Accumulates capture-path counts for the life of the process.
final class CaptureStats: @unchecked Sendable {
    /// The process-wide counters every `ScreenCapture` records into by default.
    static let shared = CaptureStats()

    private let lock = NSLock()
    private var sck = 0
    private var fallbackReasons: [WindowShotFailure: Int] = [:]

    /// Record a capture ScreenCaptureKit answered.
    func recordSCK() {
        lock.withLock { sck += 1 }
    }

    /// Record a capture that fell back to the `screencapture` CLI.
    func recordFallback(_ reason: WindowShotFailure) {
        lock.withLock { fallbackReasons[reason, default: 0] += 1 }
    }

    /// Current totals.
    func snapshot() -> CaptureStatsSnapshot {
        lock.withLock {
            CaptureStatsSnapshot(sck: sck, fallbackReasons: fallbackReasons)
        }
    }
}
