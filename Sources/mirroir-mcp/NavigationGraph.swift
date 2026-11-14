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
// ABOUTME: Directed graph of app screens (nodes) and navigation actions (edges) for DFS exploration.
// ABOUTME: Thread-safe session accumulator tracking visited elements, screen types, and transitions.

import Foundation
import HelperLib


/// Thread-safe directed graph tracking screen navigation during app exploration.
/// Follows the Session Accumulator pattern: explicit lifecycle with NSLock protection.
final class NavigationGraph: @unchecked Sendable {

    var nodes: [String: ScreenNode] = [:]
    var edges: [NavigationEdge] = []
    /// Adjacency list for O(1) outgoing edge lookup, maintained incrementally.
    var adjacency: [String: [NavigationEdge]] = [:]
    var currentFP: String = ""
    var rootFP: String = ""
    var isStarted: Bool = false
    /// Per-screen runtime state (scroll counts + tap-area dedup cache).
    /// NavigationGraph delegates the `recordTap`, `wasAlreadyTapped`,
    /// `tapCount`, `scrollCount`, `incrementScrollCount` methods to this
    /// collaborator.
    let perScreen = PerScreenExplorationState()
    var scoutResultsMap: [String: [String: ScoutResult]] = [:]
    var traversalPhases: [String: TraversalPhase] = [:]
    var screenPlans: [String: [RankedElement]] = [:]
    /// Viewpoints captured during calibration: ordered scroll positions with visible elements.
    var viewpointsMap: [String: [CalibrationScroller.Viewpoint]] = [:]
    /// Labels of breadth_navigation components (e.g. tab bar items) registered during calibration.
    var breadthLabels: Set<String> = []
    /// Labels of breadth_navigation components already explored. Shared across all screens
    /// so tab bars are not re-tapped from every child screen.
    var globalVisited: Set<String> = []
    /// Edges that produced dead taps (no screen change), keyed by "fromFP:elementText".
    var deadEdges: Set<String> = []
    /// Recovery events logged during exploration for post-hoc diagnosis.
    var recoveryEvents: [RecoveryEvent] = []
    /// Refinement levels per fingerprint for CEGAR-style adaptive abstraction.
    var refinementLevels: [String: StateAbstraction.RefinementLevel] = [:]
    let lock = NSLock()

    // MARK: - Lifecycle

    /// Initialize the graph with the root screen, resetting all state.
    func start(
        rootElements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String],
        screenshot: String,
        screenType: ScreenType
    ) {
        lock.lock()
        defer { lock.unlock() }

        nodes = [:]
        edges = []
        adjacency = [:]
        perScreen.reset()
        scoutResultsMap = [:]
        traversalPhases = [:]
        screenPlans = [:]
        viewpointsMap = [:]
        breadthLabels = []
        globalVisited = []
        deadEdges = []
        recoveryEvents = []
        refinementLevels = [:]

        let fp = StructuralFingerprint.compute(elements: rootElements, icons: icons)
        let title = StructuralFingerprint.extractNavBarTitle(from: rootElements)
        let rootHash = VisualFingerprint.compute(screenshotBase64: screenshot)
        let node = ScreenNode(
            fingerprint: fp, elements: rootElements, icons: icons, hints: hints,
            depth: 0, screenType: screenType, screenshotBase64: screenshot,
            visitedElements: [], navBarTitle: title,
            visualHash: rootHash != 0 ? rootHash : nil
        )
        nodes[fp] = node
        currentFP = fp
        rootFP = fp
        isStarted = true
    }

    /// Record a navigation transition. Compares new screen against known nodes via similarity.
    func recordTransition(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String],
        screenshot: String,
        actionType: String,
        elementText: String,
        displayLabel: String? = nil,
        screenType: ScreenType,
        edgeType: EdgeType = .push
    ) -> TransitionResult {
        lock.lock()
        defer { lock.unlock() }

        let newFP = StructuralFingerprint.compute(elements: elements, icons: icons)

        // Check if action had no effect (same screen)
        if newFP == currentFP {
            // Double-check with title-aware similarity in case hash collision or minor OCR variation
            if let currentNode = nodes[currentFP] {
                let sim = StructuralFingerprint.titleAwareSimilarity(
                    currentNode.elements, elements
                )
                if sim >= StructuralFingerprint.similarityThreshold {
                    return .duplicate
                }
            } else {
                return .duplicate
            }
        }

        // Check if this screen matches any known node (by similarity, not just hash)
        let candidateHash = VisualFingerprint.compute(screenshotBase64: screenshot)
        let candidateVHash: UInt64? = candidateHash != 0 ? candidateHash : nil
        var matchingFP = findMatchingNode(elements: elements, visualHash: candidateVHash)

        // CEGAR refinement: if the match is behaviorally different, refine the fingerprint
        if let existingFP = matchingFP, let existingNode = nodes[existingFP],
           !StateAbstraction.areBehaviorallyEquivalent(
               existingElements: existingNode.elements, newElements: elements
           ) {
            if let level = StateAbstraction.findDistinguishingLevel(
                existingElements: existingNode.elements, newElements: elements
            ) {
                let refinedFP = StateAbstraction.computeRefinedFingerprint(
                    elements: elements, icons: icons, level: level
                )
                if nodes[refinedFP] == nil {
                    DebugLog.log("graph", "CEGAR refine: \(existingFP.prefix(8)) → " +
                        "\(refinedFP.prefix(8)) at level \(level)")
                    refinementLevels[refinedFP] = level
                    matchingFP = nil // treat as new screen with refined fingerprint
                }
            }
        }

        let targetFP = matchingFP ?? newFP
        let edge = NavigationEdge(
            fromFingerprint: currentFP,
            toFingerprint: targetFP,
            actionType: actionType,
            elementText: elementText,
            displayLabel: displayLabel ?? elementText,
            edgeType: edgeType,
            qValue: 1.0
        )
        edges.append(edge)
        adjacency[edge.fromFingerprint, default: []].append(edge)

        if let existingFP = matchingFP {
            currentFP = existingFP
            return .revisited(fingerprint: existingFP)
        }

        // New screen: use refined fingerprint if CEGAR refinement occurred
        let effectiveFP = refinementLevels[targetFP] != nil ? targetFP : newFP
        let currentDepth = nodes[currentFP]?.depth ?? 0
        let title = StructuralFingerprint.extractNavBarTitle(from: elements)
        let node = ScreenNode(
            fingerprint: effectiveFP,
            elements: elements,
            icons: icons,
            hints: hints,
            depth: currentDepth + 1,
            screenType: screenType,
            screenshotBase64: screenshot,
            visitedElements: [],
            navBarTitle: title,
            visualHash: candidateVHash
        )
        nodes[effectiveFP] = node
        currentFP = effectiveFP

        return .newScreen(fingerprint: effectiveFP)
    }

    /// Mark an element as visited on the specified screen.
    func markElementVisited(fingerprint: String, elementText: String) {
        lock.lock()
        defer { lock.unlock() }
        nodes[fingerprint]?.visitedElements.insert(elementText)
    }

    /// Export an immutable snapshot of the current graph state.
    func finalize() -> GraphSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return GraphSnapshot(
            nodes: nodes,
            edges: edges,
            adjacency: adjacency,
            rootFingerprint: rootFP,
            deadEdges: deadEdges,
            recoveryEvents: recoveryEvents,
            refinementLevels: refinementLevels
        )
    }

    // MARK: - Accessors

    /// Number of distinct screens discovered.
    var nodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    /// Number of navigation edges recorded.
    var edgeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return edges.count
    }

    /// Fingerprint of the current screen.
    var currentFingerprint: String {
        lock.lock()
        defer { lock.unlock() }
        return currentFP
    }

    /// Get all edges originating from a given screen fingerprint.
    /// O(1) lookup via the incrementally-maintained adjacency list.
    func edges(from fingerprint: String) -> [NavigationEdge] {
        lock.lock()
        defer { lock.unlock() }
        return adjacency[fingerprint] ?? []
    }

    /// Get the most recent incoming edge that led to a given screen fingerprint.
    func incomingEdge(to fingerprint: String) -> NavigationEdge? {
        lock.lock()
        defer { lock.unlock() }
        return edges.last { $0.toFingerprint == fingerprint }
    }

    /// Whether the graph has been initialized with a root screen.
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStarted
    }

    /// Get unvisited elements for a screen, filtered by the visited set.
    /// Test-only utility — production code uses resolveNextPlanItem() instead.
    func unvisitedElements(for fingerprint: String) -> [TapPoint] {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[fingerprint] else { return [] }
        return node.elements.filter { !node.visitedElements.contains($0.text) }
    }

    /// Get the node for a given fingerprint.
    func node(for fingerprint: String) -> ScreenNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[fingerprint]
    }

    /// Get the screen type of the root node.
    func rootScreenType() -> ScreenType? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[rootFP]?.screenType
    }

    /// Fingerprint of the root (first) screen.
    var rootFingerprint: String {
        lock.lock()
        defer { lock.unlock() }
        return rootFP
    }

    /// Update the current fingerprint after backtracking to sync graph state.
    func setCurrentFingerprint(_ fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        currentFP = fingerprint
    }

    /// Check if a screen has unvisited elements (elements not in the visited set).
    /// Test-only utility — production code uses resolveNextPlanItem() instead.
    func hasUnvisitedElements(for fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[fingerprint] else { return false }
        return node.elements.contains { !node.visitedElements.contains($0.text) }
    }

    // MARK: - Scout Phase Support

    /// Record the result of scouting an element on a screen.
    func recordScoutResult(fingerprint: String, elementText: String, result: ScoutResult) {
        lock.lock()
        defer { lock.unlock() }
        scoutResultsMap[fingerprint, default: [:]][elementText] = result
    }

    /// Get all scout results for a screen.
    func scoutResults(for fingerprint: String) -> [String: ScoutResult] {
        lock.lock()
        defer { lock.unlock() }
        return scoutResultsMap[fingerprint, default: [:]]
    }

    /// Get the current traversal phase for a screen. Defaults to `.scout`.
    func traversalPhase(for fingerprint: String) -> TraversalPhase {
        lock.lock()
        defer { lock.unlock() }
        return traversalPhases[fingerprint, default: .scout]
    }

    /// Set the traversal phase for a screen.
    func setTraversalPhase(for fingerprint: String, phase: TraversalPhase) {
        lock.lock()
        defer { lock.unlock() }
        traversalPhases[fingerprint] = phase
    }

    // MARK: - Screen Plan Support

    /// Store a ranked exploration plan for a screen.
    func setScreenPlan(for fingerprint: String, plan: [RankedElement]) {
        lock.lock()
        defer { lock.unlock() }
        screenPlans[fingerprint] = plan
    }

    /// Get the exploration plan for a screen, if one has been built.
    func screenPlan(for fingerprint: String) -> [RankedElement]? {
        lock.lock()
        defer { lock.unlock() }
        return screenPlans[fingerprint]
    }

    /// Get the next unvisited plan element, skipping per-screen and global visited sets.
    func nextPlannedElement(for fingerprint: String) -> RankedElement? {
        lock.lock()
        defer { lock.unlock() }
        guard let plan = screenPlans[fingerprint],
              let node = nodes[fingerprint] else { return nil }
        return plan.first {
            !node.visitedElements.contains($0.displayLabel) &&
            !globalVisited.contains($0.displayLabel)
        }
    }

    /// Clear the exploration plan for a screen, forcing a rebuild on next access.
    func clearScreenPlan(for fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        screenPlans[fingerprint] = nil
    }

    // MARK: - Global Component Tracking

    /// Register breadth_navigation labels (e.g. tab bar items) for global tracking.
    func registerBreadthLabels(_ labels: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        breadthLabels.formUnion(labels)
    }

    /// Check if a displayLabel belongs to a breadth_navigation component.
    func isBreadthLabel(_ label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return breadthLabels.contains(label)
    }

    /// The set of labels marked globally visited (breadth_navigation items).
    var globalVisitedLabels: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return globalVisited
    }

    /// Mark a breadth_navigation component as globally visited across all screens.
    func markGloballyVisited(label: String) {
        lock.lock()
        defer { lock.unlock() }
        globalVisited.insert(label)
    }

    // MARK: - Tap Area Cache

    /// Record a tap at the given coordinates on a screen.
    func recordTap(fingerprint: String, x: Double, y: Double) {
        perScreen.recordTap(fingerprint: fingerprint, x: x, y: y)
    }

    /// Check whether a point was already tapped on a screen (within proximity radius).
    func wasAlreadyTapped(fingerprint: String, x: Double, y: Double) -> Bool {
        perScreen.wasAlreadyTapped(fingerprint: fingerprint, x: x, y: y)
    }

    /// Number of tapped areas recorded for a screen.
    func tapCount(for fingerprint: String) -> Int {
        perScreen.tapCount(for: fingerprint)
    }

}
