// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Helper methods for BFSExplorer: context escape, plan building, scroll support.
// ABOUTME: Split from BFSExplorer.swift to stay under the 500-line limit.

import Foundation
import HelperLib

extension BFSExplorer {

    /// Check if the explorer has left the target app and handle accordingly.
    /// Returns an ExploreStepResult to return early, or nil if still in-app.
    func handleContextEscape(
        elements: [TapPoint], input: InputProviding, describer: ScreenDescribing
    ) -> ExploreStepResult? {
        let check = ExplorerUtilities.verifyAppContext(
            elements: elements, screenHeight: windowSize.height,
            appName: appName, input: input, describer: describer)
        switch check {
        case .ok: return nil
        case .recovered:
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        case .failed(let reason):
            lock.lock(); isFinished = true; lock.unlock()
            return .paused(reason: "Left app: \(reason)")
        }
    }

    /// Build a screen plan using component detection or legacy per-element classification.
    func buildScreenPlan(
        classified: [ClassifiedElement], visitedElements: Set<String>
    ) -> [RankedElement] {
        guard !componentDefinitions.isEmpty else {
            DebugLog.log("bfs", "plan-path: LEGACY (0 component definitions)")
            return ScreenPlanner.buildPlan(
                classified: classified, visitedElements: visitedElements,
                scoutResults: [:], screenHeight: windowSize.height)
        }
        let rawComponents = classifier?.classify(
            classified: classified, definitions: componentDefinitions,
            screenHeight: windowSize.height
        ) ?? ComponentDetector.detect(
            classified: classified, definitions: componentDefinitions,
            screenHeight: windowSize.height)
        let components = ComponentDetector.applyAbsorption(rawComponents)
        DebugLog.log("bfs", "plan-path: COMPONENT (\(componentDefinitions.count) defs, " +
            "\(rawComponents.count) raw, \(components.count) absorbed)")
        let explorableCount = components.filter { $0.definition.exploration.explorable }.count
        let nonExplorableNames = components
            .filter { !$0.definition.exploration.explorable }
            .map { $0.displayLabel }
        if !nonExplorableNames.isEmpty {
            DebugLog.log("bfs", "non-explorable components: \(nonExplorableNames)")
        }
        DebugLog.log("bfs", "explorable: \(explorableCount)/\(components.count) components")
        return ScreenPlanner.buildComponentPlan(
            components: components, visitedElements: visitedElements,
            scoutResults: [:], screenHeight: windowSize.height)
    }

    /// Calibrate the root screen by scrolling through the full page to discover all elements.
    /// Uses CalibrationScroller (via describeFullPage) when a bridge is available for proper
    /// anchor-based deduplication and scroll offsets. Falls back to simple scroll loop otherwise.
    /// Merges discovered elements into the graph node for awareness, then scrolls back to top.
    /// Does NOT consume the regular scroll budget — uses a separate calibration pass.
    ///
    /// - Parameters:
    ///   - currentFP: Fingerprint of the root screen to calibrate.
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for swipe gestures.
    func calibrateRootScreen(
        currentFP: String, describer: ScreenDescribing, input: InputProviding
    ) {
        let fromFraction = EnvConfig.scrollSwipeFromYFraction
        let toFraction = EnvConfig.scrollSwipeToYFraction
        DebugLog.log("bfs", "calibration: starting full-page scan for root screen " +
            "(fromY=\(String(format: "%.0f", windowSize.height * fromFraction))pt " +
            "toY=\(String(format: "%.0f", windowSize.height * toFraction))pt)")

        // Prefer CalibrationScroller when bridge is available — it has proper
        // anchor-based offset detection and overlap deduplication.
        if let bridge = bridge {
            DebugLog.log("bfs", "calibration: using CalibrationScroller (bridge available)")
            guard let scrollResult = describer.describeFullPage(
                input: input, bridge: bridge, maxScrolls: budget.scrollLimit
            ) else {
                DebugLog.log("bfs", "calibration: CalibrationScroller returned nil — OCR failure")
                return
            }

            let novelCount = graph.mergeScrolledElements(
                fingerprint: currentFP, newElements: scrollResult.elements
            )

            // Scroll back to the top so exploration starts from the first viewport
            let centerX = windowSize.width / 2
            let scrollFromY = windowSize.height * fromFraction
            let scrollToY = windowSize.height * toFraction
            for _ in 0..<scrollResult.scrollCount {
                _ = input.swipe(
                    fromX: centerX, fromY: scrollToY,
                    toX: centerX, toY: scrollFromY, durationMs: 300
                )
                usleep(EnvConfig.stepSettlingDelayMs * 1000)
            }

            let totalElements = graph.node(for: currentFP)?.elements.count ?? 0
            DebugLog.log("bfs", "calibration complete (CalibrationScroller): " +
                "\(scrollResult.scrollCount) scrolls, \(novelCount) new elements, " +
                "\(totalElements) total on screen")
            lock.lock()
            calibrationSummary = ExplorationReportFormatter.CalibrationSummary(
                scrollCount: scrollResult.scrollCount,
                newElementCount: novelCount,
                totalElements: totalElements,
                usedCalibrationScroller: true)
            lock.unlock()
            return
        }

        // Fallback: simple scroll loop without anchor-based dedup
        DebugLog.log("bfs", "calibration: using simple scroll loop (no bridge)")
        let centerX = windowSize.width / 2
        let scrollFromY = windowSize.height * fromFraction
        let scrollToY = windowSize.height * toFraction
        var scrollsDone = 0
        var totalNovel = 0

        for i in 0..<budget.scrollLimit {
            _ = input.swipe(
                fromX: centerX, fromY: scrollFromY,
                toX: centerX, toY: scrollToY, durationMs: 300
            )
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
            scrollsDone += 1

            guard let result = describer.describe(skipOCR: false) else { break }

            let novelCount = graph.mergeScrolledElements(
                fingerprint: currentFP, newElements: result.elements
            )
            totalNovel += novelCount

            DebugLog.log("bfs", "calibration scroll \(i + 1): \(novelCount) new elements")

            if novelCount == 0 { break }
        }

        // Scroll back to the top so exploration starts from the first viewport
        for _ in 0..<scrollsDone {
            _ = input.swipe(
                fromX: centerX, fromY: scrollToY,
                toX: centerX, toY: scrollFromY, durationMs: 300
            )
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
        }

        let totalElements = graph.node(for: currentFP)?.elements.count ?? 0
        DebugLog.log("bfs", "calibration complete (simple): \(scrollsDone) scrolls, " +
            "\(totalNovel) new elements, \(totalElements) total on screen")
        lock.lock()
        calibrationSummary = ExplorationReportFormatter.CalibrationSummary(
            scrollCount: scrollsDone,
            newElementCount: totalNovel,
            totalElements: totalElements,
            usedCalibrationScroller: false)
        lock.unlock()
    }

    /// Attempt to scroll the current screen to reveal hidden elements.
    /// Returns a step result if scrolling revealed new elements, or nil to fall through.
    func performScrollIfAvailable(
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ExploreStepResult? {
        guard graph.scrollCount(for: currentFP) < budget.scrollLimit else { return nil }

        // Swipe up (scroll content down) using calibrated Y positions
        let centerX = windowSize.width / 2
        let fromY = windowSize.height * EnvConfig.scrollSwipeFromYFraction
        let toY = windowSize.height * EnvConfig.scrollSwipeToYFraction
        DebugLog.log("bfs", "scroll: fromY=\(Int(fromY))pt toY=\(Int(toY))pt " +
            "(fractions: \(EnvConfig.scrollSwipeFromYFraction)/\(EnvConfig.scrollSwipeToYFraction))")
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)

        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // OCR the new viewport
        guard let afterResult = describer.describe(skipOCR: false) else { return nil }

        let novelCount = graph.mergeScrolledElements(
            fingerprint: currentFP, newElements: afterResult.elements
        )
        graph.incrementScrollCount(for: currentFP)

        if novelCount > 0 {
            // New elements discovered — invalidate the plan so it rebuilds with them
            graph.clearScreenPlan(for: currentFP)
            return .continue(description: "Scrolled, found \(novelCount) new elements")
        }
        // No new elements — scroll exhaustion, fall through
        return nil
    }

    /// Generate a structured exploration report covering calibration, per-screen actions,
    /// and tap cache statistics.
    func generateReport() -> String {
        lock.lock()
        let allScreenActions = screenActions
        let allCacheHits = cacheHitsPerScreen
        let calSummary = calibrationSummary
        lock.unlock()

        let currentStats = stats
        var screenSummaries: [ExplorationReportFormatter.ScreenSummary] = []
        let totalCacheHits = allCacheHits.values.reduce(0, +)

        // Build per-screen summaries from the graph
        let snapshot = graph.finalize()
        for (fp, node) in snapshot.nodes.sorted(by: { $0.value.depth < $1.value.depth }) {
            let actions = allScreenActions[fp] ?? []
            let cacheHits = allCacheHits[fp] ?? 0
            let plan = graph.screenPlan(for: fp)
            screenSummaries.append(ExplorationReportFormatter.ScreenSummary(
                depth: node.depth,
                fingerprint: String(fp.prefix(8)),
                componentCount: plan?.count ?? 0,
                actionCount: actions.count,
                cacheHits: cacheHits,
                actions: actions
            ))
        }

        return ExplorationReportFormatter.formatExplorationReport(
            appName: appName,
            calibration: calSummary,
            screens: screenSummaries,
            stats: currentStats,
            tapCacheTotal: totalCacheHits
        )
    }
}
