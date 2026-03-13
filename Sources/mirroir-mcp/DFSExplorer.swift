// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Autonomous DFS explorer that systematically traverses app screens via graph-based backtracking.
// ABOUTME: Each step() call performs one exploration action: tap an unvisited element or backtrack.

import Foundation
import HelperLib

/// Result of a single DFS exploration step.
enum ExploreStepResult: Sendable {
    /// Exploration continues — an action was performed and a new/revisited screen was reached.
    case `continue`(description: String)
    /// Backtracked from one screen to another after exhausting elements.
    case backtracked(from: String, to: String)
    /// Exploration paused due to a budget constraint or external condition.
    case paused(reason: String)
    /// Exploration is complete — all reachable screens have been visited.
    case finished(bundle: SkillBundle)
}

/// Autonomous DFS explorer that systematically traverses app screens.
/// Each call to `step()` performs one exploration action: OCR the current screen,
/// decide what to tap (or backtrack), execute the action, and record the result.
/// Follows the Session Accumulator pattern with NSLock protection.
final class DFSExplorer: @unchecked Sendable {

    let graph: NavigationGraph
    let session: ExplorationSession
    let budget: ExplorationBudget
    let windowSize: CGSize
    let appName: String
    var backtrackStack: [String] = []
    private var startTime: Date = Date()
    var actionCount: Int = 0
    var actionsOnCurrentScreen: Int = 0
    var isFinished: Bool = false
    let lock = NSLock()

    /// Initialize the DFS explorer.
    ///
    /// - Parameters:
    ///   - session: The exploration session tracking screens and graph state.
    ///   - budget: Exploration budget limits.
    ///   - windowSize: Size of the target window for scroll coordinate computation.
    init(session: ExplorationSession, budget: ExplorationBudget, windowSize: CGSize = CGSize(width: 410, height: 890)) {
        self.session = session
        self.graph = session.currentGraph
        self.budget = budget
        self.windowSize = windowSize
        self.appName = session.currentAppName
    }

    /// Record the exploration start time. Call once after the initial screen capture.
    func markStarted() {
        lock.lock()
        defer { lock.unlock() }
        startTime = Date()
        if graph.started {
            backtrackStack = [graph.currentFingerprint]
        }
    }

    /// Perform one DFS exploration step.
    /// OCRs the current screen, decides what to do, executes the action, and records the result.
    ///
    /// - Parameters:
    ///   - describer: Screen describer for OCR.
    ///   - input: Input provider for tap/press_key actions.
    ///   - strategy: Exploration strategy for element ranking and classification.
    /// - Returns: The result of this step.
    func step<S: ExplorationStrategy>(
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        lock.lock()
        let finished = isFinished
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let depth = backtrackStack.count - 1
        let screenCount = graph.nodeCount
        lock.unlock()

        guard !finished else {
            return .finished(bundle: generateBundle())
        }

        // Check budget
        if budget.isExhausted(depth: depth, screenCount: screenCount, elapsedSeconds: elapsed) {
            lock.lock()
            isFinished = true
            lock.unlock()
            return .finished(bundle: generateBundle())
        }

        // OCR current screen, dismissing any alert that may be present
        guard let result = dismissAlertIfPresent(describer: describer, input: input) else {
            return .paused(reason: "Failed to capture screen")
        }

        // Verify we're still inside the target app
        switch ExplorerUtilities.verifyAppContext(
            elements: result.elements, screenHeight: windowSize.height,
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

        let currentFP = graph.currentFingerprint
        let screenType = strategy.classifyScreen(elements: result.elements, hints: result.hints)

        // Classify all OCR elements using spatial proximity before filtering
        let classified = ElementClassifier.classify(
            result.elements, budget: budget, screenHeight: windowSize.height
        )
        let navigationElements = classified.filter { $0.role == .navigation }.map(\.point)

        // Scout phase: on broad screens at shallow depth, scout elements before diving
        let phase = graph.traversalPhase(for: currentFP)
        let navCount = navigationElements.count

        if phase == .scout && ScoutPhase.shouldScout(
            screenType: screenType, depth: depth, navigationCount: navCount
        ) {
            let scouted = graph.scoutResults(for: currentFP)
            if scouted.count < budget.maxScoutsPerScreen,
               let target = ScoutPhase.nextScoutTarget(
                   classified: classified, scouted: Set(scouted.keys)
               ) {
                return performScoutTap(
                    target: target, currentFP: currentFP,
                    input: input, describer: describer, strategy: strategy
                )
            }
            // All scouted or budget reached — advance to dive phase
            graph.setTraversalPhase(for: currentFP, phase: .dive)
        }

        // Dive phase: build or retrieve a scored exploration plan for this screen
        let visitedElements = graph.node(for: currentFP)?.visitedElements ?? []
        if graph.screenPlan(for: currentFP) == nil {
            graph.setScreenPlan(for: currentFP, plan: ScreenPlanner.buildPlan(
                classified: classified, visitedElements: visitedElements,
                scoutResults: graph.scoutResults(for: currentFP),
                screenHeight: windowSize.height
            ))
        }

        // Get the next highest-scored unvisited element from the plan
        let rankedElement: RankedElement? = if let ranked = graph.nextPlannedElement(for: currentFP),
            !strategy.shouldSkip(elementText: ranked.point.text, budget: budget) { ranked } else { nil }

        lock.lock()
        let currentActions = actionsOnCurrentScreen
        lock.unlock()

        // Check if we should tap an element or backtrack
        if let ranked = rankedElement, currentActions < budget.maxActionsPerScreen {
            return performTap(
                target: ranked.point, displayLabel: ranked.displayLabel,
                currentFP: currentFP,
                input: input, describer: describer, strategy: strategy,
                result: result
            )
        }

        // Try scrolling to reveal hidden elements before backtracking
        if let scrollResult = performScrollIfAvailable(
            currentFP: currentFP, input: input, describer: describer
        ) {
            DebugLog.log("dfs", "scroll revealed new elements, resetting action counter")
            lock.lock()
            actionsOnCurrentScreen = 0
            lock.unlock()
            return scrollResult
        }

        // No more elements, scroll exhausted — backtrack
        return performBacktrack(
            currentFP: currentFP, input: input,
            describer: describer, strategy: strategy,
            hints: result.hints, elements: result.elements
        )
    }

    /// Whether the exploration has completed.
    var completed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    /// Current exploration statistics.
    var stats: (nodeCount: Int, edgeCount: Int, actionCount: Int, elapsedSeconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (
            nodeCount: graph.nodeCount,
            edgeCount: graph.edgeCount,
            actionCount: actionCount,
            elapsedSeconds: Int(Date().timeIntervalSince(startTime))
        )
    }

    // MARK: - Private Actions

    private func performTap<S: ExplorationStrategy>(
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
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        case .failed(let reason):
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
            lock.lock()
            backtrackStack.append(fp)
            actionsOnCurrentScreen = 0
            lock.unlock()
            return .continue(description: "Tapped \"\(displayLabel)\" → new screen (\(graph.nodeCount) total)")

        case .revisited:
            lock.lock()
            actionsOnCurrentScreen += 1
            lock.unlock()
            return .continue(description: "Tapped \"\(displayLabel)\" → revisited screen")

        case .duplicate:
            lock.lock()
            actionsOnCurrentScreen += 1
            lock.unlock()
            return .continue(description: "Tapped \"\(displayLabel)\" → no screen change")
        }
    }

    /// Scout a single element: tap, compare fingerprints, immediately backtrack if navigated.
    /// Records the scout result in the graph for later use in dive-phase ranking.
    private func performScoutTap<S: ExplorationStrategy>(
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
                actionType: "tap", elementText: target.text, screenType: screenType,
                edgeType: scoutEdgeType
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

    /// Attempt to scroll the current screen to reveal hidden elements.
    /// Returns a step result if scrolling revealed new elements, or nil to fall through to backtrack.
    private func performScrollIfAvailable(
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ExploreStepResult? {
        guard graph.scrollCount(for: currentFP) < budget.scrollLimit else { return nil }

        // Swipe up (scroll content down) from center of screen
        let centerX = windowSize.width / 2
        let fromY = windowSize.height * 0.75
        let toY = windowSize.height * 0.25
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)

        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // OCR the new viewport
        guard let afterResult = describer.describe() else { return nil }

        let novelCount = graph.mergeScrolledElements(
            fingerprint: currentFP, newElements: afterResult.elements
        )
        graph.incrementScrollCount(for: currentFP)

        if novelCount > 0 {
            // New elements discovered — invalidate the plan so it rebuilds with them
            graph.clearScreenPlan(for: currentFP)
            return .continue(description: "Scrolled, found \(novelCount) new elements")
        }
        // No new elements — scroll exhaustion, fall through to backtrack
        return nil
    }

    /// OCR the screen and dismiss any detected iOS alert before returning the result.
    /// If no alert is detected, the initial OCR result is returned directly (zero overhead).
    /// Retries up to `AlertDetector.maxDismissAttempts` times for persistent alerts.
    private func dismissAlertIfPresent(
        describer: ScreenDescribing,
        input: InputProviding
    ) -> ScreenDescriber.DescribeResult? {
        guard var result = describer.describe() else { return nil }

        for _ in 0..<AlertDetector.maxDismissAttempts {
            guard let alert = AlertDetector.detectAlert(elements: result.elements) else {
                return result
            }
            // Tap the dismiss target
            _ = input.tap(x: alert.dismissTarget.tapX, y: alert.dismissTarget.tapY)
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
            // Re-OCR to get clean screen
            guard let cleanResult = describer.describe() else { return nil }
            result = cleanResult
        }

        // After max attempts, return whatever we have
        return result
    }

    func generateBundle() -> SkillBundle {
        guard let data = session.finalize() else {
            return SkillBundle(appName: "", skills: [], manifest: nil)
        }
        return SkillBundleGenerator.generate(
            appName: data.appName, goal: data.goal,
            snapshot: data.graphSnapshot, allScreens: data.screens
        )
    }
}
