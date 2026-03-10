// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Helper methods for BFSExplorer: calibration pipeline, plan resolution, scroll support.
// ABOUTME: Split from BFSExplorer.swift to stay under the 500-line limit.

import Foundation
import HelperLib

/// Result of a screen calibration attempt.
enum CalibrationResult {
    /// Calibration succeeded and plan was built.
    case ok
    /// Calibration validation failed (strict mode, too many unclassified elements).
    case failed(String)
}

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

    // MARK: - Calibration Pipeline: Calibrate → Detect → Validate → Plan

    /// Calibrate a screen: scroll full page, run component detection on all elements,
    /// validate classification quality, and build the exploration plan.
    ///
    /// Pipeline: Calibrate (scroll + collect) → Detect (component matching) →
    /// Validate (quality gate) → Plan (ranked exploration items).
    ///
    /// - Parameters:
    ///   - fingerprint: Fingerprint of the screen to calibrate.
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for swipe gestures.
    /// - Returns: `.ok` on success, `.failed` with diagnostic message on validation failure.
    func calibrateScreen(
        fingerprint: String, describer: ScreenDescribing, input: InputProviding
    ) -> CalibrationResult {
        // Stage 1: Calibrate — scroll and collect all elements
        let scrollData = scrollAndCollect(fingerprint: fingerprint, describer: describer, input: input)

        // Stage 2: Detect — run component detection on the full element set
        let allElements = graph.node(for: fingerprint)?.elements ?? []
        guard !allElements.isEmpty else {
            DebugLog.log("bfs", "calibration: no elements after scroll — skipping detection")
            return .ok
        }

        let classified = ElementClassifier.classify(
            allElements, budget: budget, screenHeight: windowSize.height
        )

        guard !componentDefinitions.isEmpty else {
            // No component definitions — build legacy plan from full element set
            let plan = ScreenPlanner.buildPlan(
                classified: classified, visitedElements: [],
                scoutResults: [:], screenHeight: windowSize.height)
            graph.setScreenPlan(for: fingerprint, plan: plan)
            storeSummary(scrollData: scrollData, fingerprint: fingerprint)
            return .ok
        }

        let rawComponents = classifier?.classify(
            classified: classified, definitions: componentDefinitions,
            screenHeight: windowSize.height
        ) ?? ComponentDetector.detect(
            classified: classified, definitions: componentDefinitions,
            screenHeight: windowSize.height)
        let components = ComponentDetector.applyAbsorption(rawComponents)

        DebugLog.log("bfs", "calibration detect: \(componentDefinitions.count) defs, " +
            "\(rawComponents.count) raw → \(components.count) absorbed")

        // Register breadth_navigation labels (e.g. tab bar items) for global tracking.
        // These will be explored once and skipped on every subsequent screen.
        let breadthLabels = Set(
            components
                .filter { $0.definition.exploration.role == .breadthNavigation }
                .map { $0.displayLabel }
        )
        if !breadthLabels.isEmpty {
            graph.registerBreadthLabels(breadthLabels)
            DebugLog.log("bfs", "registered \(breadthLabels.count) breadth labels: \(breadthLabels.sorted())")
        }

        // Stage 3: Validate — check unclassified ratio in content zone
        let validation = CalibrationValidator.validate(
            components: components, screenHeight: windowSize.height
        )
        DebugLog.log("bfs", "calibration validation: \(validation.report)")

        if !validation.passed {
            storeSummary(
                scrollData: scrollData, fingerprint: fingerprint,
                componentCount: components.count,
                unclassifiedCount: validation.unclassifiedCount,
                validationPassed: false, validationReport: validation.report)
            return .failed(
                "Calibration failed: \(validation.unclassifiedCount)/\(validation.totalContentElements) " +
                "content elements unclassified (\(String(format: "%.0f", validation.unclassifiedRatio * 100))%). " +
                "New component definitions may be needed.\n\n\(validation.report)")
        }

        // Stage 4: Plan — build exploration plan from component map
        let plan = ScreenPlanner.buildComponentPlan(
            components: components, visitedElements: [],
            scoutResults: [:], screenHeight: windowSize.height)
        graph.setScreenPlan(for: fingerprint, plan: plan)

        let explorableCount = components.filter { $0.definition.exploration.explorable }.count
        DebugLog.log("bfs", "calibration plan: \(plan.count) items " +
            "(\(explorableCount) explorable / \(components.count) total components)")

        storeSummary(
            scrollData: scrollData, fingerprint: fingerprint,
            componentCount: components.count,
            unclassifiedCount: validation.unclassifiedCount,
            validationPassed: true, validationReport: validation.report)

        return .ok
    }

    // MARK: - Plan Coordinate Resolution

    /// Resolve the next unvisited plan item against the current viewport's OCR elements.
    /// Uses displayLabel matching to find fresh coordinates. If the item isn't visible,
    /// scrolls to reveal it. Skips items that can't be found or should be skipped.
    func resolveNextPlanItem<S: ExplorationStrategy>(
        currentFP: String,
        viewportElements: [TapPoint],
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> RankedElement? {
        var scrollAttempts = 0
        let maxScrollAttempts = budget.scrollLimit

        while let ranked = graph.nextPlannedElement(for: currentFP) {
            if strategy.shouldSkip(elementText: ranked.point.text, budget: budget) {
                graph.markElementVisited(fingerprint: currentFP, elementText: ranked.displayLabel)
                continue
            }

            // Try resolving against current viewport
            let resolution = PlanCoordinateResolver.resolve(
                planItem: ranked, viewportElements: viewportElements
            )

            switch resolution {
            case .found(let freshPoint):
                return PlanCoordinateResolver.withFreshCoordinates(
                    planItem: ranked, freshPoint: freshPoint
                )

            case .needsScroll:
                // Element not in current viewport — try scrolling to reveal it
                guard scrollAttempts < maxScrollAttempts else {
                    DebugLog.log("bfs", "resolve: skip \"\(ranked.displayLabel)\" — " +
                        "scroll budget exhausted (\(scrollAttempts) attempts)")
                    graph.markElementVisited(fingerprint: currentFP, elementText: ranked.displayLabel)
                    continue
                }

                if let freshElements = scrollToReveal(input: input, describer: describer) {
                    scrollAttempts += 1
                    let retryResolution = PlanCoordinateResolver.resolve(
                        planItem: ranked, viewportElements: freshElements
                    )
                    if case .found(let freshPoint) = retryResolution {
                        return PlanCoordinateResolver.withFreshCoordinates(
                            planItem: ranked, freshPoint: freshPoint
                        )
                    }
                }
                // Still not found after scroll — skip this item, try next
                DebugLog.log("bfs", "resolve: skip \"\(ranked.displayLabel)\" — not found after scroll")
                graph.markElementVisited(fingerprint: currentFP, elementText: ranked.displayLabel)
            }
        }
        return nil
    }

    // MARK: - Scroll Support

    /// Scroll down one step and return fresh OCR elements, or nil on failure.
    private func scrollToReveal(
        input: InputProviding, describer: ScreenDescribing
    ) -> [TapPoint]? {
        let centerX = windowSize.width / 2
        let fromY = windowSize.height * EnvConfig.scrollSwipeFromYFraction
        let toY = windowSize.height * EnvConfig.scrollSwipeToYFraction
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        return describer.describe(skipOCR: false)?.elements
    }

    /// Attempt to scroll the current screen to reveal hidden elements.
    /// For calibrated screens, does NOT rebuild the plan — the calibrated plan is authoritative.
    /// Returns a step result if scrolling revealed new elements, or nil to fall through.
    func performScrollIfAvailable(
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ExploreStepResult? {
        guard graph.scrollCount(for: currentFP) < budget.scrollLimit else { return nil }

        let centerX = windowSize.width / 2
        let fromY = windowSize.height * EnvConfig.scrollSwipeFromYFraction
        let toY = windowSize.height * EnvConfig.scrollSwipeToYFraction
        DebugLog.log("bfs", "scroll: fromY=\(Int(fromY))pt toY=\(Int(toY))pt")
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)

        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        guard let afterResult = describer.describe(skipOCR: false) else { return nil }

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
        return nil
    }

    // MARK: - Calibration Internals

    /// Scroll and collect data struct returned by the scroll phase.
    private struct ScrollCollectionData {
        let scrollCount: Int
        let novelCount: Int
        let totalElements: Int
        let usedCalibrationScroller: Bool
    }

    /// Phase 1 of calibration: scroll through the full page, collect all OCR elements,
    /// merge into the graph node, and scroll back to the top.
    private func scrollAndCollect(
        fingerprint: String, describer: ScreenDescribing, input: InputProviding
    ) -> ScrollCollectionData {
        let fromFraction = EnvConfig.scrollSwipeFromYFraction
        let toFraction = EnvConfig.scrollSwipeToYFraction
        DebugLog.log("bfs", "calibration: starting full-page scan for \(fingerprint.prefix(8))")

        // Prefer CalibrationScroller when bridge is available
        if let bridge = bridge {
            DebugLog.log("bfs", "calibration: using CalibrationScroller")
            guard let scrollResult = describer.describeFullPage(
                input: input, bridge: bridge, maxScrolls: budget.scrollLimit
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

            // Scroll back to top
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

            let totalElements = graph.node(for: fingerprint)?.elements.count ?? 0
            DebugLog.log("bfs", "calibration scroll done: " +
                "\(scrollResult.scrollCount) scrolls, \(novelCount) new, \(totalElements) total")

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

        for i in 0..<budget.scrollLimit {
            _ = input.swipe(
                fromX: centerX, fromY: scrollFromY,
                toX: centerX, toY: scrollToY, durationMs: 300
            )
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
            scrollsDone += 1

            guard let result = describer.describe(skipOCR: false) else { break }
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
    private func storeSummary(
        scrollData: ScrollCollectionData, fingerprint: String,
        componentCount: Int? = nil, unclassifiedCount: Int? = nil,
        validationPassed: Bool? = nil, validationReport: String? = nil
    ) {
        lock.lock()
        calibrationSummary = ExplorationReportFormatter.CalibrationSummary(
            scrollCount: scrollData.scrollCount,
            newElementCount: scrollData.novelCount,
            totalElements: scrollData.totalElements,
            usedCalibrationScroller: scrollData.usedCalibrationScroller,
            componentCount: componentCount,
            unclassifiedCount: unclassifiedCount,
            validationPassed: validationPassed,
            validationReport: validationReport)
        lock.unlock()
    }

    // MARK: - Report Generation

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
