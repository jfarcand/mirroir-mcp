// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: BFS (breadth-first) explorer that traverses app screens layer by layer.
// ABOUTME: Each step() call performs one action: navigate, tap an element, or return to root.

import Foundation
import HelperLib

/// BFS explorer that systematically traverses app screens layer by layer.
/// Explores all elements at the current depth before moving deeper.
/// Each call to `step()` performs one exploration action: navigate a path segment,
/// tap an element and record the result, or tap back toward root.
/// Follows the Session Accumulator pattern with NSLock protection.
final class BFSExplorer: @unchecked Sendable {

    let graph: NavigationGraph
    let session: ExplorationSession
    let budget: ExplorationBudget
    let windowSize: CGSize
    let appName: String
    /// Loaded component definitions for grouping OCR elements into UI components.
    let componentDefinitions: [ComponentDefinition]
    /// Classifier for grouping OCR elements into components. nil uses legacy element-level planning.
    let classifier: (any ComponentClassifying)?
    /// Window bridge for calibration scroll (CalibrationScroller needs window info).
    let bridge: (any WindowBridging)?

    private var frontier: [FrontierScreen] = []
    private var frontierIndex: Int = 0
    private var phase: BFSPhase = .atRoot
    private var actionsOnCurrentScreen: Int = 0
    private var startTime: Date = Date()
    /// Fingerprints of screens that have been calibrated (full-page scroll + component detection).
    var calibratedScreens: Set<String> = []
    /// Report data: calibration summary, collected during calibration phase.
    var calibrationSummary: ExplorationReportFormatter.CalibrationSummary?
    /// Report data: per-screen action entries, keyed by fingerprint.
    var screenActions: [String: [ExplorationReportFormatter.ActionEntry]] = [:]
    /// Report data: tap cache hit count per screen.
    var cacheHitsPerScreen: [String: Int] = [:]
    var actionCount: Int = 0
    var isFinished: Bool = false
    let lock = NSLock()

    /// Initialize the BFS explorer.
    ///
    /// - Parameters:
    ///   - session: The exploration session tracking screens and graph state.
    ///   - budget: Exploration budget limits.
    ///   - windowSize: Size of the target window for coordinate computation.
    ///   - componentDefinitions: Component definitions for grouping OCR elements.
    ///   - classifier: Component classifier to use. nil falls back to legacy per-element planning.
    ///   - bridge: Window bridge for CalibrationScroller. nil falls back to simple scroll calibration.
    init(
        session: ExplorationSession,
        budget: ExplorationBudget,
        windowSize: CGSize = CGSize(width: 410, height: 890),
        componentDefinitions: [ComponentDefinition] = [],
        classifier: (any ComponentClassifying)? = nil,
        bridge: (any WindowBridging)? = nil
    ) {
        self.session = session
        self.graph = session.currentGraph
        self.budget = budget
        self.windowSize = windowSize
        self.appName = session.currentAppName
        self.componentDefinitions = componentDefinitions
        self.classifier = classifier
        self.bridge = bridge
    }

    /// Record start time and seed frontier with the root screen. Call once after initial capture.
    func markStarted() {
        lock.lock()
        defer { lock.unlock() }
        startTime = Date()
        if graph.started {
            let rootFP = graph.rootFingerprint
            frontier = [FrontierScreen(fingerprint: rootFP, pathFromRoot: [], depth: 0)]
            frontierIndex = 0
        }
    }

    /// Perform one BFS exploration step. Dispatches to the current phase handler.
    func step<S: ExplorationStrategy>(
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        lock.lock()
        let finished = isFinished
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let screenCount = graph.nodeCount
        lock.unlock()

        guard !finished else {
            return .finished(bundle: generateBundle())
        }

        // Budget check — depth is enforced at frontier insertion, check time/screens here
        if budget.isExhausted(depth: 0, screenCount: screenCount, elapsedSeconds: elapsed) {
            lock.lock()
            isFinished = true
            lock.unlock()
            return .finished(bundle: generateBundle())
        }

        switch phase {
        case .atRoot:
            return stepAtRoot(describer: describer, input: input, strategy: strategy)
        case .navigating(let target, let pathIndex):
            return stepNavigating(
                target: target, pathIndex: pathIndex,
                describer: describer, input: input, strategy: strategy
            )
        case .exploring(let screen):
            return stepExploring(
                screen: screen, describer: describer, input: input, strategy: strategy
            )
        case .returning(let depthRemaining):
            return stepReturning(
                depthRemaining: depthRemaining, describer: describer, input: input
            )
        }
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

    func generateBundle() -> SkillBundle {
        guard let data = session.finalize() else {
            return SkillBundle(appName: "", skills: [], manifest: nil)
        }
        return SkillBundleGenerator.generate(
            appName: data.appName, goal: data.goal,
            snapshot: data.graphSnapshot, allScreens: data.screens
        )
    }

    // MARK: - Phase: At Root

    /// Dequeue the next frontier screen and begin navigation or exploration.
    private func stepAtRoot<S: ExplorationStrategy>(
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        lock.lock()
        guard frontierIndex < frontier.count else {
            isFinished = true
            lock.unlock()
            return .finished(bundle: generateBundle())
        }
        let target = frontier[frontierIndex]
        frontierIndex += 1
        actionsOnCurrentScreen = 0
        lock.unlock()

        let pathDesc = target.pathFromRoot.map { $0.elementText }.joined(separator: " → ")
        DebugLog.log("bfs", "dequeue frontier[\(frontierIndex - 1)/\(frontier.count)] " +
            "depth=\(target.depth) path=[\(pathDesc)] fp=\(target.fingerprint.prefix(8))")

        if target.pathFromRoot.isEmpty {
            // Root screen (depth 0) — calibrate by scrolling through the full page
            // to discover all elements, run component detection, build plan, then
            // scroll back to top before exploring.
            graph.setCurrentFingerprint(target.fingerprint)
            phase = .exploring(screen: target)
            return stepExploring(
                screen: target, describer: describer, input: input, strategy: strategy
            )
        }

        // Navigate from root to the target screen
        phase = .navigating(target: target, pathIndex: 0)
        return stepNavigating(
            target: target, pathIndex: 0,
            describer: describer, input: input, strategy: strategy
        )
    }

    // MARK: - Phase: Navigating

    /// Tap one path segment to navigate toward the target frontier screen.
    private func stepNavigating<S: ExplorationStrategy>(
        target: FrontierScreen,
        pathIndex: Int,
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        let segment = target.pathFromRoot[pathIndex]

        // Tap the element at this path segment
        _ = input.tap(x: segment.tapX, y: segment.tapY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        lock.lock()
        actionCount += 1
        lock.unlock()

        // OCR to verify navigation succeeded
        guard ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) != nil else {
            // OCR failed — skip this frontier screen, return to root
            phase = target.depth > 1
                ? .returning(depthRemaining: pathIndex + 1) : .atRoot
            return .paused(reason: "OCR failed during navigation to depth-\(target.depth) screen")
        }

        let nextIndex = pathIndex + 1
        if nextIndex >= target.pathFromRoot.count {
            // Trust path replay: tapping the same element navigates to the same screen.
            // Structural verification was too strict — clock changes, scroll position
            // differences, and dynamic content cause false negatives on nearly identical screens.
            graph.setCurrentFingerprint(target.fingerprint)
            lock.lock()
            actionsOnCurrentScreen = 0
            lock.unlock()
            phase = .exploring(screen: target)
            return .continue(
                description: "Navigated to depth-\(target.depth) screen via \"\(segment.elementText)\""
            )
        }

        // More path segments to go
        phase = .navigating(target: target, pathIndex: nextIndex)
        return .continue(
            description: "Navigating: tapped \"\(segment.elementText)\" " +
                "(step \(nextIndex)/\(target.pathFromRoot.count))"
        )
    }

    // MARK: - Phase: Exploring

    /// Explore one element on the current frontier screen, tap back if it navigated.
    private func stepExploring<S: ExplorationStrategy>(
        screen: FrontierScreen,
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        let currentFP = screen.fingerprint

        // OCR current screen, dismissing any alert
        guard let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            return .paused(reason: "Failed to capture screen during exploration")
        }

        if let exit = handleContextEscape(elements: result.elements, input: input, describer: describer) { return exit }

        // Calibrate this screen if not already done (scroll full page + component detect + plan)
        var viewportElements = result.elements
        if !calibratedScreens.contains(currentFP) {
            let calResult = calibrateScreen(
                fingerprint: currentFP, describer: describer, input: input
            )
            calibratedScreens.insert(currentFP)
            if case .failed(let reason) = calResult {
                lock.lock(); isFinished = true; lock.unlock()
                return .paused(reason: reason)
            }
            // Re-OCR after calibration: the scroller scrolls down then back up,
            // so the viewport may differ from the pre-calibration capture.
            // Fresh elements ensure the resolver doesn't scroll unnecessarily.
            if let fresh = describer.describe(skipOCR: false) {
                viewportElements = fresh.elements
            }
        }

        // Log all OCR elements so we can compare with what's visible on screen
        let ocrTexts = viewportElements.map { "\($0.text)@(\(Int($0.tapX)),\(Int($0.tapY)))" }
        DebugLog.log("bfs", "OCR elements (\(viewportElements.count)): \(ocrTexts.joined(separator: ", "))")

        // Build plan from viewport if calibration didn't produce one (e.g. non-scrollable screen)
        if graph.screenPlan(for: currentFP) == nil {
            let classified = ElementClassifier.classify(
                viewportElements, budget: budget, screenHeight: windowSize.height
            )
            let visitedElements = graph.node(for: currentFP)?.visitedElements ?? []
            let plan = buildScreenPlan(
                classified: classified, visitedElements: visitedElements
            )
            graph.setScreenPlan(for: currentFP, plan: plan)
        }

        if let plan = graph.screenPlan(for: currentFP) {
            let planTexts = plan.map { "\($0.displayLabel)(score=\(String(format: "%.1f", $0.score)))" }
            DebugLog.log("bfs", "plan: \(planTexts)")
        }

        // Resolve next plan item against fresh viewport coordinates
        let rankedElement = resolveNextPlanItem(
            currentFP: currentFP, viewportElements: viewportElements,
            describer: describer, input: input, strategy: strategy
        )

        lock.lock()
        let currentActions = actionsOnCurrentScreen
        lock.unlock()

        let visited = graph.node(for: currentFP)?.visitedElements ?? []
        DebugLog.log("bfs", "exploring depth=\(screen.depth) fp=\(currentFP.prefix(8)) " +
            "actions=\(currentActions)/\(budget.maxActionsPerScreen) " +
            "visited=\(visited) next=\(rankedElement?.displayLabel ?? "nil")")

        guard let ranked = rankedElement, currentActions < budget.maxActionsPerScreen else {
            // Try scrolling to reveal hidden elements
            if let scrollResult = performScrollIfAvailable(
                currentFP: currentFP, input: input, describer: describer
            ) {
                DebugLog.log("bfs", "scroll revealed new elements, resetting action counter")
                lock.lock()
                actionsOnCurrentScreen = 0
                lock.unlock()
                return scrollResult
            }

            // Done with this screen
            if screen.depth == 0 {
                phase = .atRoot
            } else {
                phase = .returning(depthRemaining: screen.depth)
            }
            return .continue(description: "Finished exploring depth-\(screen.depth) screen")
        }

        let target = ranked.point
        let label = ranked.displayLabel

        // Check tap area cache — skip if we already tapped near these coordinates
        if graph.wasAlreadyTapped(fingerprint: currentFP, x: target.tapX, y: target.tapY) {
            DebugLog.log("bfs", "SKIP \"\(label)\" at (\(Int(target.tapX)),\(Int(target.tapY))) — " +
                "already tapped nearby (cache has \(graph.tapCount(for: currentFP)) entries)")
            graph.markElementVisited(fingerprint: currentFP, elementText: label)
            lock.lock()
            cacheHitsPerScreen[currentFP, default: 0] += 1
            screenActions[currentFP, default: []].append(
                ExplorationReportFormatter.ActionEntry(
                    label: label, x: target.tapX, y: target.tapY,
                    result: "cache_skip", skippedByCache: true))
            lock.unlock()
            return .continue(description: "Skipped \"\(label)\" — already tapped nearby")
        }

        // Mark visited using displayLabel (unique per component) to avoid
        // collisions when multiple components share the same raw text (e.g. "icon").
        graph.markElementVisited(fingerprint: currentFP, elementText: label)

        // Mark breadth_navigation components (e.g. tab bar items) as globally visited
        // so they are not re-tapped from every child screen.
        if graph.isBreadthLabel(label) {
            graph.markGloballyVisited(label: label)
            DebugLog.log("bfs", "globally visited breadth label: \"\(label)\"")
        }

        // Record tap coordinates in cache before tapping
        graph.recordTap(fingerprint: currentFP, x: target.tapX, y: target.tapY)

        // Tap the element
        _ = input.tap(x: target.tapX, y: target.tapY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // OCR the resulting screen
        guard let afterResult = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            return .paused(reason: "Failed to capture screen after tap")
        }

        if let exit = handleContextEscape(elements: afterResult.elements, input: input, describer: describer) { return exit }

        let screenType = strategy.classifyScreen(
            elements: afterResult.elements, hints: afterResult.hints
        )

        // Record transition in graph (raw text for visited-state, displayLabel for naming)
        let transition = graph.recordTransition(
            elements: afterResult.elements, icons: afterResult.icons,
            hints: afterResult.hints, screenshot: afterResult.screenshotBase64,
            actionType: "tap", elementText: target.text, displayLabel: label,
            screenType: screenType
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
        actionsOnCurrentScreen += 1
        lock.unlock()

        let transitionDesc: String
        switch transition {
        case .newScreen: transitionDesc = "new_screen"
        case .revisited: transitionDesc = "revisited"
        case .duplicate: transitionDesc = "no_navigation"
        }
        DebugLog.log("bfs", "tapped \"\(label)\" at (\(Int(target.tapX)),\(Int(target.tapY))) → \(transitionDesc)")
        lock.lock()
        screenActions[currentFP, default: []].append(
            ExplorationReportFormatter.ActionEntry(
                label: label, x: target.tapX, y: target.tapY,
                result: transitionDesc, skippedByCache: false))
        lock.unlock()

        switch transition {
        case .newScreen(let fp):
            // Add child to frontier for later exploration
            let childDepth = screen.depth + 1
            if childDepth < budget.maxDepth && graph.nodeCount < budget.maxScreens {
                let newPath = screen.pathFromRoot + [PathSegment(
                    elementText: target.text, tapX: target.tapX, tapY: target.tapY
                )]
                frontier.append(FrontierScreen(
                    fingerprint: fp, pathFromRoot: newPath, depth: childDepth
                ))
            }

            // Tap back and verify we returned to the expected screen.
            // If lost (stuck in modal, wrong screen), finishes exploration gracefully.
            if let lostResult = tapBackAndVerify(
                expectedFP: currentFP, afterElements: afterResult.elements,
                describer: describer, input: input
            ) {
                return lostResult
            }

            return .continue(
                description: "Tapped \"\(label)\" → new screen (\(graph.nodeCount) total)"
            )

        case .revisited:
            // Already-known screen — tap back, verify, don't re-explore
            if let lostResult = tapBackAndVerify(
                expectedFP: currentFP, afterElements: afterResult.elements,
                describer: describer, input: input
            ) {
                return lostResult
            }

            return .continue(description: "Tapped \"\(label)\" → revisited screen")

        case .duplicate:
            // Didn't navigate — stay on current screen, no back-tap needed
            return .continue(description: "Tapped \"\(label)\" → no navigation")
        }
    }

    // MARK: - Phase: Returning

    /// Tap back one level toward root. Each step reduces depth by one.
    private func stepReturning(
        depthRemaining: Int,
        describer: ScreenDescribing,
        input: InputProviding
    ) -> ExploreStepResult {
        // Get current screen elements for back button detection
        let elements: [TapPoint]
        if let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) {
            elements = result.elements
        } else {
            elements = []
        }

        ExplorerUtilities.tapBackButton(
            elements: elements, input: input, windowSize: windowSize
        )

        let remaining = depthRemaining - 1
        if remaining > 0 {
            phase = .returning(depthRemaining: remaining)
        } else {
            phase = .atRoot
            graph.setCurrentFingerprint(graph.rootFingerprint)
        }

        return .continue(
            description: "Returning to root (\(remaining) level\(remaining == 1 ? "" : "s") remaining)"
        )
    }

}
