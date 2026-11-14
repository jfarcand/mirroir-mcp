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
// ABOUTME: DFSExplorer tap actions — regular tap (commits navigation) and scout tap (probe + backtrack).
// ABOUTME: Extracted from DFSExplorer.swift to stay under the 500-line limit.

import Foundation
import HelperLib

extension DFSExplorer {

    func performTap<S: ExplorationStrategy>(
        target: TapPoint,
        displayLabel: String,
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing,
        strategy: S.Type,
        result: ScreenDescriber.DescribeResult
    ) -> ExploreStepResult {
        // Mark element as visited before tapping (raw text for identity matching)
        graph.markElementVisited(fingerprint: currentFP, elementText: target.text)

        // Tap the element
        _ = input.tap(x: target.tapX, y: target.tapY)

        // Wait for screen to settle
        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // OCR the new screen, dismissing any alert triggered by the tap
        guard let afterResult = dismissAlertIfPresent(describer: describer, input: input) else {
            return .paused(reason: "Failed to capture screen after tap")
        }

        // Verify we're still inside the target app after the tap
        switch ExplorerUtilities.verifyAppContext(
            elements: afterResult.elements, screenHeight: windowSize.height,
            appName: appName, input: input, describer: describer
        ) {
        case .ok: break
        case .recovered:
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .appRelaunched,
                screenFingerprint: currentFP,
                description: "App escaped after tapping \"\(displayLabel)\", relaunched"
            ))
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        case .failed(let reason):
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .appEscape,
                screenFingerprint: currentFP,
                description: "App escaped after tapping \"\(displayLabel)\": \(reason)"
            ))
            lock.lock(); isFinished = true; lock.unlock()
            return .paused(reason: "Left app: \(reason)")
        }

        let screenType = strategy.classifyScreen(
            elements: afterResult.elements, hints: afterResult.hints
        )

        // Classify the transition type for intelligent backtracking
        let edgeType: EdgeType
        if let sourceNode = graph.node(for: currentFP) {
            edgeType = EdgeClassifier.classify(
                sourceNode: sourceNode,
                destinationElements: afterResult.elements,
                destinationHints: afterResult.hints,
                tappedElement: target,
                screenHeight: windowSize.height
            )
        } else {
            edgeType = .push
        }

        // Record transition in graph (raw text for visited-state, displayLabel for naming)
        let transition = graph.recordTransition(
            elements: afterResult.elements, icons: afterResult.icons,
            hints: afterResult.hints, screenshot: afterResult.screenshotBase64,
            actionType: "tap", elementText: target.text, displayLabel: displayLabel,
            screenType: screenType, edgeType: edgeType
        )

        // Also record in session for flat screen list.
        // Skip graph transition since the explorer manages the graph directly above.
        session.capture(
            elements: afterResult.elements, hints: afterResult.hints,
            icons: afterResult.icons, actionType: "tap",
            arrivedVia: target.text, displayLabel: displayLabel,
            screenshotBase64: afterResult.screenshotBase64,
            skipGraphTransition: true
        )

        lock.lock()
        actionCount += 1
        lock.unlock()

        switch transition {
        case .newScreen(let fp):
            depthTracker.push(fp)
            return .continue(description: "Tapped \"\(displayLabel)\" → new screen (\(graph.nodeCount) total)")

        case .revisited:
            depthTracker.incrementActionsOnCurrentScreen()
            return .continue(description: "Tapped \"\(displayLabel)\" → revisited screen")

        case .duplicate:
            // Mark this edge as dead so future exploration plans skip it
            graph.markEdgeDead(fromFingerprint: currentFP, displayLabel: target.text)
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .deadTap,
                screenFingerprint: currentFP,
                description: "Tapped \"\(displayLabel)\" but screen did not change"
            ))
            DebugLog.log("dfs", "dead tap: \"\(displayLabel)\" on \(currentFP.prefix(8))")
            depthTracker.incrementActionsOnCurrentScreen()
            return .continue(description: "Tapped \"\(displayLabel)\" → dead tap (marked)")
        }
    }

    /// Scout a single element: tap, compare fingerprints, immediately backtrack if navigated.
    /// Records the scout result in the graph for later use in dive-phase ranking.
    func performScoutTap<S: ExplorationStrategy>(
        target: TapPoint,
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing,
        strategy: S.Type
    ) -> ExploreStepResult {
        // Scout deduplication is handled by scoutResultsMap (nextScoutTarget checks
        // scouted.contains), NOT visitedElements. Marking visited here would starve
        // the dive phase by filtering out scouted elements from the dive plan.

        // Tap the element
        _ = input.tap(x: target.tapX, y: target.tapY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // OCR after tap, dismissing any alert
        guard let afterResult = dismissAlertIfPresent(describer: describer, input: input) else {
            return .paused(reason: "Failed to capture screen after scout tap")
        }

        // Verify we're still inside the target app after the scout tap
        switch ExplorerUtilities.verifyAppContext(
            elements: afterResult.elements, screenHeight: windowSize.height,
            appName: appName, input: input, describer: describer
        ) {
        case .ok: break
        case .recovered:
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        case .failed(let reason):
            lock.lock(); isFinished = true; lock.unlock()
            return .paused(reason: "Left app: \(reason)")
        }

        // Compare using structural similarity (not exact hash) for consistency
        // with NavigationGraph's Jaccard-based node matching.
        let navigated: Bool
        if let currentNode = graph.node(for: currentFP) {
            navigated = !StructuralFingerprint.areEquivalentTitleAware(
                currentNode.elements, afterResult.elements
            )
        } else {
            let afterFP = StructuralFingerprint.compute(
                elements: afterResult.elements, icons: afterResult.icons
            )
            navigated = afterFP != currentFP
        }
        let scoutResult: ScoutResult = navigated ? .navigated : .noChange
        graph.recordScoutResult(
            fingerprint: currentFP, elementText: target.text, result: scoutResult
        )

        lock.lock()
        actionCount += 1
        lock.unlock()

        if navigated {
            // Record the transition in the graph so we know about this screen
            let screenType = strategy.classifyScreen(
                elements: afterResult.elements, hints: afterResult.hints
            )
            let scoutEdgeType: EdgeType
            if let sourceNode = graph.node(for: currentFP) {
                scoutEdgeType = EdgeClassifier.classify(
                    sourceNode: sourceNode,
                    destinationElements: afterResult.elements,
                    destinationHints: afterResult.hints,
                    tappedElement: target,
                    screenHeight: windowSize.height
                )
            } else {
                scoutEdgeType = .push
            }
            _ = graph.recordTransition(
                elements: afterResult.elements, icons: afterResult.icons,
                hints: afterResult.hints, screenshot: afterResult.screenshotBase64,
                actionType: "tap", elementText: target.text, displayLabel: nil,
                screenType: screenType, edgeType: scoutEdgeType
            )
            // Record in session for flat screen list.
            // Skip graph transition since the explorer manages the graph directly above.
            session.capture(
                elements: afterResult.elements, hints: afterResult.hints,
                icons: afterResult.icons, actionType: "tap",
                arrivedVia: target.text, screenshotBase64: afterResult.screenshotBase64,
                skipGraphTransition: true
            )

            // Immediately backtrack: tap the "<" back button and verify
            _ = tapBackButton(elements: afterResult.elements, input: input)

            // Verify we returned to the parent screen. If the back tap missed,
            // retry once to avoid graph desync.
            let resolvedFP = verifyBacktrack(
                expectedFP: currentFP, fromFP: currentFP,
                elements: afterResult.elements, input: input, describer: describer
            )
            graph.setCurrentFingerprint(resolvedFP)

            return .continue(
                description: "Scouted \"\(target.text)\" → navigates (will dive later)"
            )
        }

        return .continue(
            description: "Scouted \"\(target.text)\" → no navigation"
        )
    }
}
