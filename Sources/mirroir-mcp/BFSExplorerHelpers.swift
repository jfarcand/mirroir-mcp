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
// ABOUTME: Helper methods for BFSExplorer: calibration pipeline, plan resolution, scroll support.
// ABOUTME: Split from BFSExplorer.swift to stay under the 500-line limit.

import Foundation
import HelperLib

/// Result of a screen calibration attempt.
enum CalibrationResult {
    /// Calibration succeeded and plan was built.
    /// `viewportMayHaveShifted` is true when calibration scrolled and discovered
    /// novel content — the caller should re-OCR to get fresh viewport coordinates
    /// because the scroll-back may not land at exactly the same position.
    case ok(viewportMayHaveShifted: Bool)
    /// Calibration validation failed (strict mode, too many unclassified elements).
    case failed(String)
}

extension BFSExplorer {

    /// Check if the explorer has left the target app and handle accordingly.
    /// Returns an ExploreStepResult to return early, or nil if still in-app.
    ///
    /// Short-circuits when the viewport matches a known graph node (via Jaccard or
    /// containment). This prevents false home-screen positives on root screens like
    /// Santé's dashboard, which has many short labels in a grid-like layout but no
    /// back chevron.
    func handleContextEscape(
        elements: [TapPoint], input: InputProviding, describer: ScreenDescribing
    ) -> ExploreStepResult? {
        // If the viewport matches any known graph node, we're still in the app.
        // This avoids false home-screen positives on root screens with grid-like layouts
        // (e.g. Santé dashboard: many short labels, no back chevron).
        if graph.findMatchingNodeWithContainment(elements: elements) != nil {
            return nil
        }

        let check = ExplorerUtilities.verifyAppContext(
            elements: elements, screenHeight: windowSize.height,
            appName: appName, input: input, describer: describer)
        switch check {
        case .ok: return nil
        case .recovered:
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .appRelaunched,
                screenFingerprint: graph.currentFingerprint,
                description: "App escaped during BFS exploration, relaunched"
            ))
            // App was relaunched — reset to root and continue exploring
            graph.setCurrentFingerprint(graph.rootFingerprint)
            frontierManager.phase = .atRoot
            return .continue(description: "App escaped — relaunched and continuing from root")
        case .failed(let reason):
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .appEscape,
                screenFingerprint: graph.currentFingerprint,
                description: "App escaped during BFS exploration: \(reason)"
            ))
            // Stuck — try in-app tap-back recovery before falling back to Spotlight.
            DebugLog.log("bfs", "context escape failed — returning to root for \(appName)")
            _ = AppRootNavigator.resetToRoot(
                appName: appName,
                rootElements: graph.node(for: graph.rootFingerprint)?.elements,
                input: input, describer: describer, backtracker: backtracker,
                windowSize: windowSize,
                backButtonFallback: currentLayoutZones.backButtonFallback
            )
            graph.setCurrentFingerprint(graph.rootFingerprint)
            frontierManager.phase = .atRoot
            return .continue(description: "App stuck — reset and continuing from root")
        }
    }

    /// Build a screen plan using component detection or legacy per-element classification.
    /// When the plan is empty and the session has APP.md tabs, injects tab elements
    /// as high-priority navigation targets (tab-driven navigation).
    func buildScreenPlan(
        classified: [ClassifiedElement], visitedElements: Set<String>,
        icons: [IconDetector.DetectedIcon] = []
    ) -> [RankedElement] {
        let plan: [RankedElement]

        if componentDefinitions.isEmpty {
            DebugLog.log("bfs", "plan-path: LEGACY (0 component definitions)")
            plan = ScreenPlanner.buildPlan(
                classified: classified, visitedElements: visitedElements,
                scoutResults: [:], screenHeight: windowSize.height)
        } else {
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
            DebugLog.log("bfs", "explorable: \(explorableCount)/\(components.count) components")
            plan = ScreenPlanner.buildComponentPlan(
                components: components, visitedElements: visitedElements,
                scoutResults: [:], screenHeight: windowSize.height)
        }

        // Tab-driven navigation: inject APP.md tab targets at the front of the
        // plan (shared with the component-calibration path via TabTargetInjector).
        // Globally-visited labels are unioned in so a tab explored once (breadth
        // one-tap-global tracking) is never re-injected on subsequent screens.
        let appDesc = session.currentAppDescription
        return TabTargetInjector.inject(
            into: plan, classifiedPoints: classified.map { $0.point },
            icons: icons, visitedElements: visitedElements.union(graph.globalVisitedLabels),
            tabs: appDesc?.tabs ?? [], tabLayout: appDesc?.tabLayout, windowSize: windowSize)
    }

    // MARK: - Calibration Pipeline

    /// Calibrate a screen: scroll full page, then build an exploration plan.
    ///
    /// When `skipComponentDetection` is false (default), runs the full pipeline:
    /// scroll → component detection → validation → component plan.
    /// When true, skips component matching and the validation gate, building
    /// the plan directly from classified elements (for vision describers).
    func calibrateScreen(
        fingerprint: String, describer: ScreenDescribing, input: InputProviding,
        skipComponentDetection: Bool = false,
        icons: [IconDetector.DetectedIcon] = []
    ) -> CalibrationResult {
        // Stage 1: Scroll full page and collect all elements (always runs).
        let scrollData = scrollAndCollect(fingerprint: fingerprint, describer: describer, input: input)

        let allElements = graph.node(for: fingerprint)?.elements ?? []
        guard !allElements.isEmpty else {
            DebugLog.log("bfs", "calibration: no elements after scroll — skipping detection")
            return .ok(viewportMayHaveShifted: false)
        }

        let scrolledWithNovelContent = scrollData.scrollCount > 0 && scrollData.novelCount > 0

        // Stage 2: Classify all elements as interactive/non-interactive.
        let classified = ElementClassifier.classify(
            allElements, budget: budget, screenHeight: windowSize.height
        )

        // Fast path: skip component detection. Do NOT build a full-page plan here.
        // The explorer will build per-viewport plans from fresh OCR, processing one
        // viewport at a time (scroll → describe → classify → tap → next viewport).
        if skipComponentDetection || componentDefinitions.isEmpty {
            // Record viewpoint count for per-viewport processing.
            // +1 for the initial viewport captured before any scroll.
            frontierManager.resetViewports(total: scrollData.scrollCount + 1)

            DebugLog.log("bfs", "=== CALIBRATION: \(frontierManager.totalViewpoints) viewpoints, " +
                "\(allElements.count) total elements ===")
            DebugLog.log("bfs", "plan will be built per viewport (no full-page plan)")
            storeSummary(scrollData: scrollData, fingerprint: fingerprint)
            return .ok(viewportMayHaveShifted: scrolledWithNovelContent)
        }

        // Full path: component detection → validation → component plan.
        return calibrateWithComponents(
            fingerprint: fingerprint, scrollData: scrollData,
            classified: classified, scrolledWithNovelContent: scrolledWithNovelContent,
            icons: icons
        )
    }

    /// Full component detection pipeline: match elements to component definitions,
    /// validate classification quality, and build a component-based exploration plan.
    private func calibrateWithComponents(
        fingerprint: String, scrollData: ScrollCollectionData,
        classified: [ClassifiedElement], scrolledWithNovelContent: Bool,
        icons: [IconDetector.DetectedIcon]
    ) -> CalibrationResult {
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

        // Recipe matching: identify app archetype from detected component composition.
        // Runs on the first calibrated screen only (recipe is stored in the session).
        if session.currentRecipeMatch == nil && !recipes.isEmpty {
            let detectedKinds = Set(components.map { $0.kind })
            if let match = RecipeMatcher.bestMatch(
                detectedComponents: detectedKinds, recipes: recipes
            ) {
                session.setRecipeMatch(match)
                let (refined, _) = StrategyDetector.refineWithRecipe(
                    current: StrategyChoice(rawValue: session.currentStrategy) ?? .mobile,
                    detectedComponents: detectedKinds,
                    recipes: recipes
                )
                session.setStrategy(refined.rawValue)
                DebugLog.log("bfs", "recipe matched: '\(match.recipe.name)' " +
                    "(score=\(String(format: "%.1f", match.score)), " +
                    "nav=\(match.recipe.navigationModel.type), " +
                    "strategy=\(refined.rawValue))")
            }
        }

        // Validate: check unclassified ratio in content zone.
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

        // Build exploration plan from matched components, then inject APP.md tab
        // targets at the front. The component path sets the plan during calibration
        // and therefore bypasses `buildScreenPlan`, so the same injection runs here
        // to keep tab-driven navigation working for component-path apps (Instagram).
        let componentPlan = ScreenPlanner.buildComponentPlan(
            components: components, visitedElements: [],
            scoutResults: [:], screenHeight: windowSize.height)
        // Globally-visited labels are passed as visited so a tab explored once
        // (breadth one-tap-global tracking) is never re-injected here either.
        let appDesc = session.currentAppDescription
        let plan = TabTargetInjector.inject(
            into: componentPlan, classifiedPoints: classified.map { $0.point },
            icons: icons, visitedElements: graph.globalVisitedLabels,
            tabs: appDesc?.tabs ?? [], tabLayout: appDesc?.tabLayout, windowSize: windowSize)
        // Q-boost with persisted edge data (same helper as the per-viewport path)
        // so both planning paths order identically on fresh:false runs.
        graph.setScreenPlan(
            for: fingerprint,
            plan: applyQBoostIfAvailable(plan: plan, fingerprint: fingerprint))

        frontierManager.resetViewports(total: scrollData.scrollCount + 1)
        let explorableCount = components.filter { $0.definition.exploration.explorable }.count
        DebugLog.log("bfs", "=== CALIBRATION: \(frontierManager.totalViewpoints) viewpoints ===")
        DebugLog.log("bfs", "calibration plan: \(plan.count) items " +
            "(\(explorableCount) explorable / \(components.count) total components)")

        storeSummary(
            scrollData: scrollData, fingerprint: fingerprint,
            componentCount: components.count,
            unclassifiedCount: validation.unclassifiedCount,
            validationPassed: true, validationReport: validation.report)

        return .ok(viewportMayHaveShifted: scrolledWithNovelContent)
    }

    // MARK: - Plan Coordinate Resolution

    /// Resolve the next unvisited plan item against the current viewport's OCR elements.
    /// Two-pass approach: first try all items against the viewport (no scrolling),
    /// then try scrolling to find unresolved items. This prevents high-score below-fold
    /// items from blocking lower-score viewport-visible items.
    func resolveNextPlanItem<S: ExplorationStrategy>(
        currentFP: String,
        viewportElements: [TapPoint],
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> RankedElement? {
        guard let plan = graph.screenPlan(for: currentFP) else { return nil }
        let visited = graph.node(for: currentFP)?.visitedElements ?? []
        let globalVisited = graph.globalVisitedLabels

        // Collect unvisited, non-skipped plan items
        var candidates: [RankedElement] = []
        for item in plan {
            if visited.contains(item.displayLabel) || globalVisited.contains(item.displayLabel) {
                continue
            }
            // Skip-check the display label, not the raw OCR text: synthesized
            // icon-only tab anchors carry empty text and only the label names
            // them ("Créer"), so a text-only check lets Skip-listed tabs
            // through to the tap.
            let skipKey = item.point.text.isEmpty ? item.displayLabel : item.point.text
            if strategy.shouldSkip(elementText: skipKey, budget: budget) {
                graph.markElementVisited(fingerprint: currentFP, elementText: item.displayLabel)
                continue
            }
            candidates.append(item)
        }

        // Pass 1: Try each candidate against the current viewport (no scrolling).
        for candidate in candidates {
            // Text-less breadth anchors (synthesized icon-only tab targets) carry
            // authoritative geometric coordinates and have no text to match against
            // the viewport — the resolver would always report `needsScroll`. Tap
            // them at their planned position directly.
            if candidate.isBreadthNavigation && candidate.point.text.isEmpty {
                return candidate
            }
            let resolution = PlanCoordinateResolver.resolve(
                planItem: candidate, viewportElements: viewportElements
            )
            if case .found(let freshPoint) = resolution {
                return PlanCoordinateResolver.withFreshCoordinates(
                    planItem: candidate, freshPoint: freshPoint
                )
            }
        }

        // Pass 2: Scroll through viewpoints in calibration order to find candidates.
        // Each scroll advances one viewport. After scrolling, check ALL remaining
        // candidates against the fresh viewport — tap the first match found.
        guard !candidates.isEmpty else { return nil }
        let maxScrollAttempts = budget.scrollLimit
        for scrollIdx in 0..<maxScrollAttempts {
            guard let freshElements = scrollToReveal(input: input, describer: describer) else {
                break
            }
            DebugLog.log("bfs", "resolve: scroll \(scrollIdx + 1)/\(maxScrollAttempts), " +
                "\(freshElements.count) elements in viewport")
            for candidate in candidates {
                let resolution = PlanCoordinateResolver.resolve(
                    planItem: candidate, viewportElements: freshElements
                )
                if case .found(let freshPoint) = resolution {
                    return PlanCoordinateResolver.withFreshCoordinates(
                        planItem: candidate, freshPoint: freshPoint
                    )
                }
            }
        }

        DebugLog.log("bfs", "resolve: no candidates found after \(maxScrollAttempts) scrolls")
        return nil
    }

    // MARK: - Report Generation

    /// Generate a structured exploration report covering calibration, per-screen actions,
    /// and tap cache statistics.
    func generateReport() -> String {
        let report = reporter.snapshot()
        let currentStats = stats
        var screenSummaries: [ExplorationReportFormatter.ScreenSummary] = []

        let snapshot = graph.finalize()
        for (fp, node) in snapshot.nodes.sorted(by: { $0.value.depth < $1.value.depth }) {
            let actions = report.screenActions[fp] ?? []
            let cacheHits = report.cacheHitsPerScreen[fp] ?? 0
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
            calibration: report.calibrationSummary,
            screens: screenSummaries,
            stats: currentStats,
            tapCacheTotal: report.totalCacheHits,
            graphStructure: ExplorationReportFormatter.formatGraphStructure(snapshot: snapshot)
        )
    }
}
