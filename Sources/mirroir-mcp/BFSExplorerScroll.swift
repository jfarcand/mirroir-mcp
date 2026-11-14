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
// ABOUTME: BFSExplorer scroll + calibration-summary helpers extracted from BFSExplorerHelpers.
// ABOUTME: Owns reveal-scroll, full-page collection, and per-screen calibration summary storage.

import Foundation
import HelperLib

extension BFSExplorer {

    // MARK: - Runtime Scrolling

    /// Scroll down one step and return fresh OCR elements, or nil on failure.
    func scrollToReveal(
        input: InputProviding, describer: ScreenDescribing
    ) -> [TapPoint]? {
        let centerX = windowSize.width / 2
        let fromY = windowSize.height * EnvConfig.scrollSwipeFromYFraction
        let toY = windowSize.height * EnvConfig.scrollSwipeToYFraction
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        return describer.describe()?.elements
    }

    /// Attempt to scroll the current screen to reveal hidden elements.
    /// For calibrated screens, does NOT rebuild the plan — the calibrated plan is authoritative.
    /// Returns a step result if scrolling revealed new elements, or nil to fall through.
    func performScrollIfAvailable(
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ExploreStepResult? {
        // Skip scrolling if content was already fully revealed or is infinite scroll.
        // Per-viewport mode (skipCalibration) ignores calibration's exhaustion flag
        // because exploration needs to scroll through viewports independently.
        guard graph.scrollCount(for: currentFP) < budget.scrollLimit,
              (skipCalibration || !graph.isScrollExhausted(fingerprint: currentFP)),
              !graph.isInfiniteScroll(fingerprint: currentFP) else { return nil }

        let centerX = windowSize.width / 2
        let fromY = windowSize.height * EnvConfig.scrollSwipeFromYFraction
        let toY = windowSize.height * EnvConfig.scrollSwipeToYFraction
        DebugLog.log("bfs", "scroll: fromY=\(Int(fromY))pt toY=\(Int(toY))pt")
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)

        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        guard let afterResult = describer.describe() else { return nil }

        let novelCount = graph.mergeScrolledElements(
            fingerprint: currentFP, newElements: afterResult.elements
        )
        graph.incrementScrollCount(for: currentFP)

        if novelCount > 0 {
            // New elements discovered — rebuild the plan to include them.
            // Even calibrated screens may have dynamic content that appears after calibration.
            graph.clearScreenPlan(for: currentFP)
            return .continue(description: "Scrolled, found \(novelCount) new elements")
        }
        // skipCalibration uses per-viewport exploration: calibration already merged
        // the full-page element set into the graph node, so a runtime scroll between
        // viewports legitimately reports novelCount=0. Still surface the scroll as a
        // step result so the caller advances the viewport instead of declaring the
        // screen finished prematurely.
        if skipCalibration {
            graph.clearScreenPlan(for: currentFP)
            return .continue(description: "Scrolled to next viewport (no novel elements)")
        }
        return nil
    }

    // MARK: - Calibration Scroll + Summary

    /// Scroll and collect data struct returned by the scroll phase.
    struct ScrollCollectionData {
        let scrollCount: Int
        let novelCount: Int
        let totalElements: Int
        let usedCalibrationScroller: Bool
    }

    /// Phase 1 of calibration: scroll through the full page, collect all OCR elements,
    /// merge into the graph node, and scroll back to the top.
    func scrollAndCollect(
        fingerprint: String, describer: ScreenDescribing, input: InputProviding
    ) -> ScrollCollectionData {
        let fromFraction = EnvConfig.scrollSwipeFromYFraction
        let toFraction = EnvConfig.scrollSwipeToYFraction
        DebugLog.log("bfs", "calibration: starting full-page scan for \(fingerprint.prefix(8))")

        // Prefer CalibrationScroller when bridge is available
        if let bridge = bridge {
            DebugLog.log("bfs", "calibration: using CalibrationScroller")
            guard let scrollResult = describer.describeFullPage(
                input: input, bridge: bridge, maxScrolls: effectiveCalibrationScrollLimit
            ) else {
                DebugLog.log("bfs", "calibration: CalibrationScroller returned nil")
                return ScrollCollectionData(
                    scrollCount: 0, novelCount: 0,
                    totalElements: graph.node(for: fingerprint)?.elements.count ?? 0,
                    usedCalibrationScroller: true)
            }

            let novelCount = graph.mergeScrolledElements(
                fingerprint: fingerprint, newElements: scrollResult.elements
            )
            // Store viewpoints for ordered viewport-by-viewport traversal
            if let navGraph = graph as? NavigationGraph {
                navGraph.viewpointsMap[fingerprint] = scrollResult.viewpoints
            }

            // Propagate scroll state to graph node
            if scrollResult.isInfiniteScroll {
                graph.markInfiniteScroll(fingerprint: fingerprint)
            }
            if scrollResult.scrollExhausted {
                graph.markScrollExhausted(fingerprint: fingerprint)
            }

            // Scroll back to top with aggressive full-height swipes.
            // iOS scroll physics don't perfectly reverse N symmetric swipes,
            // so we use full-height gestures (bottom→top) plus an extra swipe.
            // iOS clamps at the top, so overshooting is safe.
            let centerX = windowSize.width / 2
            let bottomY = windowSize.height * 0.85
            let topY = windowSize.height * 0.10
            for _ in 0...scrollResult.scrollCount {
                _ = input.swipe(
                    fromX: centerX, fromY: topY,
                    toX: centerX, toY: bottomY, durationMs: 300
                )
                usleep(EnvConfig.stepSettlingDelayMs * 1000)
            }

            let totalElements = graph.node(for: fingerprint)?.elements.count ?? 0
            DebugLog.log("bfs", "calibration scroll done: " +
                "\(scrollResult.scrollCount) scrolls, \(novelCount) new, \(totalElements) total" +
                (scrollResult.isInfiniteScroll ? " [infinite]" : "") +
                (scrollResult.scrollExhausted ? " [exhausted]" : ""))

            return ScrollCollectionData(
                scrollCount: scrollResult.scrollCount, novelCount: novelCount,
                totalElements: totalElements, usedCalibrationScroller: true)
        }

        // Fallback: simple scroll loop
        DebugLog.log("bfs", "calibration: using simple scroll loop")
        let centerX = windowSize.width / 2
        let scrollFromY = windowSize.height * fromFraction
        let scrollToY = windowSize.height * toFraction
        var scrollsDone = 0
        var totalNovel = 0

        for i in 0..<effectiveCalibrationScrollLimit {
            _ = input.swipe(
                fromX: centerX, fromY: scrollFromY,
                toX: centerX, toY: scrollToY, durationMs: 300
            )
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
            scrollsDone += 1

            guard let result = describer.describe() else { break }
            let novelCount = graph.mergeScrolledElements(
                fingerprint: fingerprint, newElements: result.elements
            )
            totalNovel += novelCount
            DebugLog.log("bfs", "calibration scroll \(i + 1): \(novelCount) new elements")
            if novelCount == 0 { break }
        }

        // Scroll back to top
        for _ in 0..<scrollsDone {
            _ = input.swipe(
                fromX: centerX, fromY: scrollToY,
                toX: centerX, toY: scrollFromY, durationMs: 300
            )
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
        }

        let totalElements = graph.node(for: fingerprint)?.elements.count ?? 0
        DebugLog.log("bfs", "calibration scroll done: " +
            "\(scrollsDone) scrolls, \(totalNovel) new, \(totalElements) total")

        return ScrollCollectionData(
            scrollCount: scrollsDone, novelCount: totalNovel,
            totalElements: totalElements, usedCalibrationScroller: false)
    }

    /// Store calibration summary in the report data.
    func storeSummary(
        scrollData: ScrollCollectionData, fingerprint: String,
        componentCount: Int? = nil, unclassifiedCount: Int? = nil,
        validationPassed: Bool? = nil, validationReport: String? = nil
    ) {
        reporter.setCalibrationSummary(ExplorationReportFormatter.CalibrationSummary(
            scrollCount: scrollData.scrollCount,
            newElementCount: scrollData.novelCount,
            totalElements: scrollData.totalElements,
            usedCalibrationScroller: scrollData.usedCalibrationScroller,
            componentCount: componentCount,
            unclassifiedCount: unclassifiedCount,
            validationPassed: validationPassed,
            validationReport: validationReport))
    }
}
