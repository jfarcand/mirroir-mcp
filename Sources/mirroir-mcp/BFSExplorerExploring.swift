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
// ABOUTME: BFSExplorer `.exploring` phase — calibrate, plan, tap, classify transition, backtrack.
// ABOUTME: Extracted from BFSExplorer.swift to stay under the 500-line limit.

import Foundation
import HelperLib

extension BFSExplorer {

    /// Explore one element on the current frontier screen, tap back if it navigated.
    func stepExploring<S: ExplorationStrategy>(
        screen: FrontierScreen,
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        let currentFP = screen.fingerprint
        // OCR current screen, dismissing any system alert or app-specific obstacle
        let appObstacles = session.currentAppDescription?.obstacleMode == .auto
            ? (session.currentAppDescription?.obstacles ?? []) : []
        guard let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input, obstacles: appObstacles
        ) else {
            return .paused(reason: "Failed to capture screen during exploration")
        }

        if let exit = handleContextEscape(elements: result.elements, input: input, describer: describer) { return exit }

        // Self-re-arming trap: an obstacle trigger that dismissAlertIfPresent could
        // not clear (e.g. the Story camera). It cannot be escaped in-app, so reset
        // our position to root and signal the loop to force-quit + cold-relaunch.
        if let trigger = ExplorerUtilities.persistentObstacle(
            elements: result.elements, obstacles: appObstacles) {
            DebugLog.log("bfs", "TRAP at step start: stuck on '\(trigger)' — requesting force-quit recovery")
            graph.setCurrentFingerprint(graph.rootFingerprint)
            frontierManager.phase = .atRoot
            return .trapped(reason: "screen stuck on '\(trigger)' (cannot be dismissed in-app)")
        }

        // Calibrate this screen if not already done: scroll full page to discover all
        // elements, then optionally run component detection + validation.
        var viewportElements = result.elements
        if !calibratedScreens.contains(currentFP) {
            let calResult = calibrateScreen(
                fingerprint: currentFP, describer: describer, input: input,
                skipComponentDetection: skipCalibration,
                icons: result.icons
            )
            calibratedScreens.insert(currentFP)
            switch calResult {
            case .failed(let reason):
                lock.lock(); isFinished = true; lock.unlock()
                return .paused(reason: reason)
            case .ok(let viewportMayHaveShifted):
                // Re-OCR only when calibration scrolled and found novel content.
                // The scroll-back may not land at exactly the original position,
                // so fresh elements prevent the resolver from scrolling unnecessarily.
                if viewportMayHaveShifted, let fresh = describer.describe() {
                    viewportElements = fresh.elements
                }
            }
        }
        // Log all OCR elements so we can compare with what's visible on screen
        let ocrTexts = viewportElements.map { "\($0.text)@(\(Int($0.tapX)),\(Int($0.tapY)))" }
        DebugLog.log("bfs", "OCR elements (\(viewportElements.count)): \(ocrTexts.joined(separator: ", "))")

        // Build plan from CURRENT viewport if none exists (per-viewport approach).
        if graph.screenPlan(for: currentFP) == nil {
            let canonicalElements = ExplorationRNG.canonicalOrder(viewportElements)
            let classified = ElementClassifier.classify(
                canonicalElements, budget: budget, screenHeight: windowSize.height
            )
            let visitedElements = graph.node(for: currentFP)?.visitedElements ?? []
            let plan = buildScreenPlan(
                classified: classified, visitedElements: visitedElements,
                icons: result.icons
            )
            graph.setScreenPlan(for: currentFP, plan: applyQBoostIfAvailable(plan: plan, fingerprint: currentFP))
            DebugLog.log("bfs", "=== VIEWPORT \(frontierManager.currentViewportIndex + 1)/\(frontierManager.totalViewpoints) ===")
            DebugLog.log("bfs", "viewport elements: \(viewportElements.count)")
            DebugLog.log("bfs", "components matched: \(plan.count)")
            let planTexts = plan.map { "\($0.displayLabel)(y=\(Int($0.point.tapY)), score=\(String(format: "%.1f", $0.score)))" }
            DebugLog.log("bfs", "click plan: \(planTexts)")
        }

        // Resolve next plan item against fresh viewport coordinates
        let rankedElement = resolveNextPlanItem(
            currentFP: currentFP, viewportElements: viewportElements,
            describer: describer, input: input, strategy: strategy
        )

        let currentActions = frontierManager.actionsOnCurrentScreen

        let visited = graph.node(for: currentFP)?.visitedElements ?? []
        DebugLog.log("bfs", "exploring depth=\(screen.depth) fp=\(currentFP.prefix(8)) " +
            "actions=\(currentActions)/\(budget.maxActionsPerScreen) " +
            "visited=\(visited) next=\(rankedElement?.displayLabel ?? "nil")")

        guard let ranked = rankedElement, currentActions < budget.maxActionsPerScreen else {
            // Current viewport exhausted — scroll down to next viewport and rebuild plan.
            // Clear the plan so the next step builds a fresh one from the new viewport.
            if let scrollResult = performScrollIfAvailable(
                currentFP: currentFP, input: input, describer: describer
            ) {
                graph.clearScreenPlan(for: currentFP)
                frontierManager.advanceViewport()
                frontierManager.resetActionsOnCurrentScreen()
                DebugLog.log("bfs", "=== VIEWPORT \(frontierManager.currentViewportIndex)/\(frontierManager.totalViewpoints) — scrolled down, plan cleared ===")
                return scrollResult
            }

            // Plan exhausted on this screen. If systematic coverage has
            // plateaued (discovery rate fell off but the run hasn't timed out
            // into exhaustion yet), ask the AI advisor for one more element to
            // try before declaring the screen done. No-op unless an advisor is
            // configured AND CoverageMonitor is in the `.plateau` phase.
            if let advisorStep = tryPlateauAdvisor(
                fingerprint: currentFP,
                screenshotBase64: result.screenshotBase64,
                viewportElements: viewportElements,
                input: input
            ) {
                return advisorStep
            }

            // Done with this screen — no more viewports to scroll to
            let visited = graph.node(for: currentFP)?.visitedElements ?? []
            DebugLog.log("bfs", "=== SCREEN DONE depth=\(screen.depth) visited=\(visited.count) items ===")
            if screen.depth == 0 {
                frontierManager.phase = .atRoot
            } else {
                frontierManager.phase = .returning(depthRemaining: screen.depth)
            }
            return .continue(description: "Finished exploring depth-\(screen.depth) screen")
        }

        let target = ranked.point
        let label = ranked.displayLabel

        // Global safe zone stencil: reject taps outside the app content area.
        // Fractions come from the target profile (orientation-aware for iPhone,
        // orientation-invariant for macOS). Breadth-navigation items (tab bar)
        // are exempt from the bottom margin because they sit at the very bottom.
        let zones = currentLayoutZones
        let safeMinY = windowSize.height * zones.safeZone.minTapYFraction
        let safeMaxY = windowSize.height * zones.safeZone.maxTapYFraction
        let outsideBottom = !ranked.isBreadthNavigation && target.tapY > safeMaxY
        if target.tapY < safeMinY || outsideBottom
            || target.tapX < 0 || target.tapX > windowSize.width {
            DebugLog.log("bfs", "STENCIL \"\(label)\" at (\(Int(target.tapX)),\(Int(target.tapY))) — " +
                "outside safe zone (y: \(Int(safeMinY))–\(Int(safeMaxY))" +
                "\(ranked.isBreadthNavigation ? ", breadth-exempt" : ""))")
            graph.markElementVisited(fingerprint: currentFP, elementText: label)
            return .continue(description: "Skipped \"\(label)\" — outside safe zone")
        }

        // Check tap area cache — skip if we already tapped near these coordinates
        if graph.wasAlreadyTapped(fingerprint: currentFP, x: target.tapX, y: target.tapY) {
            DebugLog.log("bfs", "SKIP \"\(label)\" at (\(Int(target.tapX)),\(Int(target.tapY))) — " +
                "already tapped nearby (cache has \(graph.tapCount(for: currentFP)) entries)")
            graph.markElementVisited(fingerprint: currentFP, elementText: label)
            reporter.recordCacheHit(fingerprint: currentFP)
            reporter.recordAction(
                fingerprint: currentFP,
                entry: ExplorationReportFormatter.ActionEntry(
                    label: label, x: target.tapX, y: target.tapY,
                    result: "cache_skip", skippedByCache: true)
            )
            return .continue(description: "Skipped \"\(label)\" — already tapped nearby")
        }

        // Mark visited using displayLabel (unique per component) to avoid
        // collisions when multiple components share the same raw text (e.g. "icon").
        graph.markElementVisited(fingerprint: currentFP, elementText: label)

        // Mark breadth_navigation components (e.g. tab bar items) as globally visited
        // so they are not re-tapped from every child screen. Gated on the plan
        // item's breadth role, not just the label string: an organic content
        // element whose OCR text happens to equal a registered tab name must not
        // globally retire the real tab before it has been explored.
        if ranked.isBreadthNavigation && graph.isBreadthLabel(label) {
            graph.markGloballyVisited(label: label)
            DebugLog.log("bfs", "globally visited breadth label: \"\(label)\"")
        }

        // Record tap coordinates in cache before tapping
        graph.recordTap(fingerprint: currentFP, x: target.tapX, y: target.tapY)

        // Tap the element and validate the result with vision
        let beforeElementCount = viewportElements.count
        _ = input.tap(x: target.tapX, y: target.tapY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        // OCR the resulting screen to validate the tap actually did something
        guard let afterResult = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input, obstacles: appObstacles
        ) else {
            return .paused(reason: "Failed to capture screen after tap")
        }
        DebugLog.log("bfs", "tap validation: \"\(label)\" — before=\(beforeElementCount) elements, " +
            "after=\(afterResult.elements.count) elements")

        // Re-check context after tap: if we accidentally triggered the home gesture,
        // detect it early. The improved AppContextDetector (nav-bar title + single-word
        // ratio filters) prevents false positives on chart/data screens.
        if let exit = handleContextEscape(elements: afterResult.elements, input: input, describer: describer) { return exit }

        // Trap: the tap opened a self-re-arming screen we can't dismiss (Story
        // camera). The element is already marked visited (above), so reset to root
        // and request a force-quit recovery rather than recording the trap as a screen.
        if let trigger = ExplorerUtilities.persistentObstacle(
            elements: afterResult.elements, obstacles: appObstacles) {
            DebugLog.log("bfs", "TRAP: tap \"\(label)\" opened a screen stuck on '\(trigger)' — requesting recovery")
            graph.setCurrentFingerprint(graph.rootFingerprint)
            frontierManager.phase = .atRoot
            return .trapped(reason: "tapping \"\(label)\" opened a screen stuck on '\(trigger)'")
        }

        let screenType = strategy.classifyScreen(
            elements: afterResult.elements, hints: afterResult.hints
        )

        // Classify edge type for intelligent backtracking, then record transition
        let edgeType = graph.node(for: currentFP).map { sourceNode in
            EdgeClassifier.classify(
                sourceNode: sourceNode, destinationElements: afterResult.elements,
                destinationHints: afterResult.hints, tappedElement: target,
                screenHeight: windowSize.height)
        } ?? .push
        let transition = graph.recordTransition(
            elements: afterResult.elements, icons: afterResult.icons,
            hints: afterResult.hints, screenshot: afterResult.screenshotBase64,
            actionType: "tap", elementText: target.text, displayLabel: label,
            screenType: screenType, edgeType: edgeType
        )

        // Record in session for flat screen list
        session.capture(
            elements: afterResult.elements, hints: afterResult.hints,
            icons: afterResult.icons, actionType: "tap",
            arrivedVia: target.text, displayLabel: label,
            screenshotBase64: afterResult.screenshotBase64,
            skipGraphTransition: true
        )

        lock.lock()
        actionCount += 1
        lock.unlock()
        frontierManager.incrementActionsOnCurrentScreen()

        let transitionDesc: String
        switch transition {
        case .newScreen: transitionDesc = "new_screen"
        case .revisited: transitionDesc = "revisited"
        case .duplicate: transitionDesc = "no_navigation"
        }
        DebugLog.log("bfs", "tapped \"\(label)\" at (\(Int(target.tapX)),\(Int(target.tapY))) → \(transitionDesc)")
        // Update learned Q-value for this edge (Fastbot2 pattern)
        (graph as? NavigationGraph)?.updateQValue(
            fromFingerprint: currentFP, displayLabel: label, result: transition)
        reporter.recordAction(
            fingerprint: currentFP,
            entry: ExplorationReportFormatter.ActionEntry(
                label: label, x: target.tapX, y: target.tapY,
                result: transitionDesc, skippedByCache: false)
        )

        switch transition {
        case .newScreen(let fp):
            coverageMonitor.recordDiscovery()
            let childDepth = screen.depth + 1
            if childDepth < budget.maxDepth && graph.nodeCount < budget.maxScreens {
                let newPath = screen.pathFromRoot + [PathSegment(
                    elementText: target.text, tapX: target.tapX, tapY: target.tapY
                )]
                // Deep lineage is inherited: a screen reached through a
                // `## Deep Tabs` tab, or through any descendant of one, keeps
                // frontier priority so the whole subtree explores first.
                let deepTabs = session.currentAppDescription?.deepTabs ?? []
                let viaDeepTab = deepTabs.contains {
                    $0.caseInsensitiveCompare(label) == .orderedSame
                }
                frontierManager.enqueue(FrontierScreen(
                    fingerprint: fp, pathFromRoot: newPath, depth: childDepth,
                    isDeepLineage: screen.isDeepLineage || viaDeepTab
                ))
            }

            // Tap back and verify we returned to the expected screen.
            DebugLog.log("bfs", "backtracking to \(currentFP.prefix(8)) after new screen")
            if let lostResult = tapBackAndVerify(
                expectedFP: currentFP, afterElements: afterResult.elements,
                describer: describer, input: input, edgeType: edgeType
            ) {
                DebugLog.log("bfs", "BACKTRACK FAILED — phase changing, remaining plan items lost")
                return lostResult
            }
            DebugLog.log("bfs", "backtrack OK — continuing on \(currentFP.prefix(8))")

            return .continue(
                description: "Tapped \"\(label)\" → new screen (\(graph.nodeCount) total)"
            )

        case .revisited:
            // Already-known screen — tap back, verify, don't re-explore
            DebugLog.log("bfs", "backtracking to \(currentFP.prefix(8)) after revisit")
            if let lostResult = tapBackAndVerify(
                expectedFP: currentFP, afterElements: afterResult.elements,
                describer: describer, input: input, edgeType: edgeType
            ) {
                DebugLog.log("bfs", "BACKTRACK FAILED on revisit — phase changing")
                return lostResult
            }

            return .continue(description: "Tapped \"\(label)\" → revisited screen")

        case .duplicate:
            // Mark this edge as dead so future exploration plans skip it
            graph.markEdgeDead(fromFingerprint: currentFP, displayLabel: label)
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .deadTap,
                screenFingerprint: currentFP,
                description: "Tapped \"\(label)\" but screen did not change"
            ))
            DebugLog.log("bfs", "dead tap: \"\(label)\" on \(currentFP.prefix(8))")
            return .continue(description: "Tapped \"\(label)\" → dead tap (marked)")
        }
    }
}
