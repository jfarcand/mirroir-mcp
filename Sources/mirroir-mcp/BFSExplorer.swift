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
// ABOUTME: BFS (breadth-first) explorer that traverses app screens layer by layer.
// ABOUTME: Each step() call performs one action: navigate, tap an element, or return to root.

import Foundation
import HelperLib

/// BFS explorer: traverses app screens layer by layer. Each `step()` call
/// performs one action (navigate, tap, or return to root).
/// Session Accumulator pattern with NSLock protection.
final class BFSExplorer: @unchecked Sendable {

    let graph: any NavigationGraphing
    let session: ExplorationSession
    let budget: ExplorationBudget
    let windowSize: CGSize
    let appName: String
    let componentDefinitions: [ComponentDefinition]
    let classifier: (any ComponentClassifying)?
    let bridge: (any WindowBridging)?

    /// Collaborator owning the frontier queue, phase state machine, per-screen
    /// action counter, and viewport tracking. Replaces six scattered mutable
    /// fields (frontier, frontierIndex, phase, actionsOnCurrentScreen,
    /// currentViewportIndex, totalViewpoints).
    let frontierManager = FrontierManager()

    /// Read-only passthroughs for tests and external readers.
    var totalViewpoints: Int { frontierManager.totalViewpoints }
    var currentViewportIndex: Int { frontierManager.currentViewportIndex }
    var startTime: Date = Date()
    /// Fingerprints of screens that have been calibrated (full-page scroll + component detection).
    var calibratedScreens: Set<String> = []
    /// Collaborator owning per-screen action entries, tap-cache-hit counts,
    /// and the calibration summary. Thread-safe internally — callers no
    /// longer lock around these accesses.
    let reporter = ExplorationReporter()
    var actionCount: Int = 0
    var isFinished: Bool = false
    let coverageMonitor: CoverageMonitor
    /// AI advisor for plateau-phase guidance. Suggests which elements to tap
    /// when systematic exploration stalls.
    let advisor: (any ExplorationAdvising)?
    /// Seeded PRNG for deterministic exploration ordering. nil = system random.
    let rng: ExplorationRNG
    /// Skip component detection during calibration (scroll still runs).
    let skipCalibration: Bool
    /// Loaded screen recipes for archetype detection.
    let recipes: [ScreenRecipe]
    /// Total viewpoints discovered during calibration scroll.
    let lock = NSLock()

    /// Back-navigation strategy. Target-dependent: iPhone Mirroring uses
    /// OCR-chevron tap; macOS apps use keyboard shortcuts. Defaults to the
    /// OCR backtracker so tests and the single-target fallback keep working.
    let backtracker: any Backtracking

    /// Target profile providing orientation-aware layout zones. Used by the
    /// tap-safety stencil and any site that needs to know the target's layout
    /// conventions (status-bar fraction, tab-bar fraction, etc.). Defaults to
    /// the iPhone-Mirroring profile so tests and the single-target fallback
    /// keep working.
    let profile: TargetProfile

    init(
        session: ExplorationSession,
        budget: ExplorationBudget,
        windowSize: CGSize = CGSize(width: 410, height: 890),
        componentDefinitions: [ComponentDefinition] = [],
        classifier: (any ComponentClassifying)? = nil,
        bridge: (any WindowBridging)? = nil,
        seed: UInt64? = nil,
        skipCalibration: Bool = false,
        advisor: (any ExplorationAdvising)? = nil,
        coverageMonitor: CoverageMonitor = CoverageMonitor(),
        recipes: [ScreenRecipe] = [],
        backtracker: any Backtracking = OCRChevronBacktracker(),
        profile: TargetProfile = IPhoneMirroringTarget.profile
    ) {
        self.session = session
        self.graph = session.currentGraph
        self.budget = budget
        self.windowSize = windowSize
        self.appName = session.currentAppName
        self.componentDefinitions = componentDefinitions
        self.classifier = classifier
        self.bridge = bridge
        self.rng = seed.map { ExplorationRNG(seed: $0) } ?? ExplorationRNG()
        self.skipCalibration = skipCalibration
        self.advisor = advisor
        self.coverageMonitor = coverageMonitor
        self.recipes = recipes
        self.backtracker = backtracker
        self.profile = profile
    }

    /// Resolve the current layout zones from the profile using the bridge's
    /// reported orientation. Safe to call repeatedly — orientation can change
    /// during an exploration session.
    var currentLayoutZones: LayoutZones {
        profile.layoutZones(bridge?.getOrientation())
    }

    /// Calibration scroll cap in effect for the current session. The matched
    /// recipe's navigation model may declare a per-archetype cap (data-driven —
    /// infinite-scroll feeds cap calibration low so full-page scans don't burn
    /// the exploration budget); the budget's limit is the global default.
    var effectiveCalibrationScrollLimit: Int {
        session.currentRecipeMatch?.recipe.navigationModel.calibrationScrollLimit
            ?? budget.calibrationScrollLimit
    }

    /// Record start time and seed frontier with the root screen. Call once after initial capture.
    func markStarted() {
        lock.lock()
        startTime = Date()
        lock.unlock()
        coverageMonitor.start()
        // Register APP.md tab names as breadth labels upfront. Icon-only tab
        // anchors are synthesized by TabTargetInjector and never component-matched,
        // so calibration's breadth-label registration never sees them — without
        // this, markGloballyVisited-based one-tap-global tracking cannot fire and
        // every new screen would re-inject the full tab list.
        if let tabs = session.currentAppDescription?.tabs, !tabs.isEmpty {
            graph.registerBreadthLabels(Set(tabs))
        }
        if graph.started {
            let rootFP = graph.rootFingerprint
            frontierManager.seed(FrontierScreen(
                fingerprint: rootFP, pathFromRoot: [], depth: 0
            ))
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

        // Coverage exhaustion — stop if no new screens for extended period
        if coverageMonitor.currentPhase == .exhaustion {
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        }

        let currentPhase = frontierManager.phase
        DebugLog.log("bfs", "step: phase=\(currentPhase) screens=\(screenCount) elapsed=\(elapsed)s")
        switch currentPhase {
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

    // MARK: - Phase: At Root

    /// Dequeue the next frontier screen and begin navigation or exploration.
    private func stepAtRoot<S: ExplorationStrategy>(
        describer: ScreenDescribing,
        input: InputProviding,
        strategy: S.Type
    ) -> ExploreStepResult {
        guard let target = frontierManager.dequeueNext() else {
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        }

        let pathDesc = target.pathFromRoot.map { $0.elementText }.joined(separator: " → ")
        let progress = frontierManager.progress
        DebugLog.log("bfs", "dequeue frontier[\(progress.index)/\(progress.total)] " +
            "depth=\(target.depth) path=[\(pathDesc)] fp=\(target.fingerprint.prefix(8))")

        if target.pathFromRoot.isEmpty {
            // Root screen (depth 0) — calibrate by scrolling through the full page
            // to discover all elements, run component detection, build plan, then
            // scroll back to top before exploring.
            graph.setCurrentFingerprint(target.fingerprint)
            frontierManager.phase = .exploring(screen: target)
            return stepExploring(
                screen: target, describer: describer, input: input, strategy: strategy
            )
        }

        // Navigate from root to the target screen
        frontierManager.phase = .navigating(target: target, pathIndex: 0)
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
            frontierManager.phase = target.depth > 1
                ? .returning(depthRemaining: pathIndex + 1) : .atRoot
            return .paused(reason: "OCR failed during navigation to depth-\(target.depth) screen")
        }

        let nextIndex = pathIndex + 1
        if nextIndex >= target.pathFromRoot.count {
            // Trust path replay: tapping the same element navigates to the same screen.
            // Structural verification was too strict — clock changes, scroll position
            // differences, and dynamic content cause false negatives on nearly identical screens.
            graph.setCurrentFingerprint(target.fingerprint)
            frontierManager.resetActionsOnCurrentScreen()
            frontierManager.phase = .exploring(screen: target)
            return .continue(
                description: "Navigated to depth-\(target.depth) screen via \"\(segment.elementText)\""
            )
        }

        // More path segments to go
        frontierManager.phase = .navigating(target: target, pathIndex: nextIndex)
        return .continue(
            description: "Navigating: tapped \"\(segment.elementText)\" " +
                "(step \(nextIndex)/\(target.pathFromRoot.count))"
        )
    }

}
