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
    /// Stuck on a self-re-arming screen that cannot be dismissed in-app (e.g. the
    /// Instagram Story camera, whose "camera not available" dialog re-pops faster
    /// than it can be cleared). The explore loop recovers by force-quitting and
    /// cold-relaunching the app to root; the explorer has already reset its own
    /// position to root before returning this.
    case trapped(reason: String)
}

/// Autonomous DFS explorer that systematically traverses app screens.
/// Each call to `step()` performs one exploration action: OCR the current screen,
/// decide what to tap (or backtrack), execute the action, and record the result.
/// Follows the Session Accumulator pattern with NSLock protection.
final class DFSExplorer: @unchecked Sendable {

    let graph: any NavigationGraphing
    let session: ExplorationSession
    let budget: ExplorationBudget
    let windowSize: CGSize
    let appName: String
    /// Owns the backtrack stack + per-screen action counter. Thread-safe internally.
    let depthTracker = DepthTracker()
    private var startTime: Date = Date()
    var actionCount: Int = 0
    var isFinished: Bool = false
    let lock = NSLock()

    /// Backward-compatible read-only accessor for the backtrack stack.
    /// Kept so tests and external callers that inspect exploration state
    /// continue to work. All writes go through `depthTracker`.
    var backtrackStack: [String] { depthTracker.snapshot }

    /// Backward-compatible read-only accessor for the action counter.
    var actionsOnCurrentScreen: Int { depthTracker.actionsOnCurrentScreen }

    /// Back-navigation strategy. Target-dependent: iPhone Mirroring uses
    /// OCR-chevron tap; macOS apps use keyboard shortcuts.
    let backtracker: any Backtracking

    /// Target profile providing orientation-aware layout zones.
    let profile: TargetProfile

    /// Bridge reference used to query current orientation at tap time.
    let bridge: (any WindowBridging)?

    /// Resolve the current layout zones from the profile using the bridge's
    /// reported orientation.
    var currentLayoutZones: LayoutZones {
        profile.layoutZones(bridge?.getOrientation())
    }

    /// Initialize the DFS explorer.
    ///
    /// - Parameters:
    ///   - session: The exploration session tracking screens and graph state.
    ///   - budget: Exploration budget limits.
    ///   - windowSize: Size of the target window for scroll coordinate computation.
    ///   - backtracker: Back-navigation strategy. Defaults to OCR-chevron tap
    ///     (the iPhone-Mirroring path) so existing tests keep working.
    ///   - profile: Target profile providing orientation-aware layout zones.
    ///   - bridge: Bridge used to query current orientation (nil-safe).
    init(
        session: ExplorationSession,
        budget: ExplorationBudget,
        windowSize: CGSize = CGSize(width: 410, height: 890),
        backtracker: any Backtracking = OCRChevronBacktracker(),
        profile: TargetProfile = IPhoneMirroringTarget.profile,
        bridge: (any WindowBridging)? = nil
    ) {
        self.session = session
        self.graph = session.currentGraph
        self.budget = budget
        self.windowSize = windowSize
        self.appName = session.currentAppName
        self.backtracker = backtracker
        self.profile = profile
        self.bridge = bridge
    }

    /// Record the exploration start time. Call once after the initial screen capture.
    func markStarted() {
        lock.lock()
        startTime = Date()
        lock.unlock()
        if graph.started {
            depthTracker.seed(rootFP: graph.currentFingerprint)
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
        let screenCount = graph.nodeCount
        lock.unlock()
        let depth = depthTracker.depth

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

        let currentActions = depthTracker.actionsOnCurrentScreen

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
            depthTracker.resetActionsOnCurrentScreen()
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
    /// Delegates to ExplorerUtilities which owns the shared alert-dismissal implementation.
    func dismissAlertIfPresent(
        describer: ScreenDescribing,
        input: InputProviding
    ) -> ScreenDescriber.DescribeResult? {
        ExplorerUtilities.dismissAlertIfPresent(describer: describer, input: input)
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

    /// Generate a summary report of the DFS exploration.
    func generateReport() -> String {
        let s = stats
        let depth = depthTracker.depth
        var lines = [
            "## DFS Exploration Report",
            "- Screens: \(s.nodeCount), Edges: \(s.edgeCount)",
            "- Actions: \(s.actionCount), Duration: \(s.elapsedSeconds)s",
            "- Max depth reached: \(depth)",
        ]
        let events = graph.finalize().recoveryEvents
        if !events.isEmpty {
            lines.append("\n### Recovery Events")
            for event in events { lines.append("- [\(event.category)] \(event.description)") }
        }
        return lines.joined(separator: "\n")
    }
}
