// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Directed graph of app screens (nodes) and navigation actions (edges) for DFS exploration.
// ABOUTME: Thread-safe session accumulator tracking visited elements, screen types, and transitions.

import Foundation
import HelperLib

/// Classification of a screen's role in the app navigation hierarchy.
enum ScreenType: String, Sendable {
    /// A screen with a tab bar (root-level navigation).
    case tabRoot
    /// A scrollable list of items.
    case list
    /// A detail/leaf screen showing specific content.
    case detail
    /// A modal overlay (has "Close", "Done", or "Cancel").
    case modal
    /// A settings-style screen with grouped rows.
    case settings
    /// Screen type could not be determined.
    case unknown
}

/// The result of recording a navigation transition in the graph.
enum TransitionResult: Sendable {
    /// Arrived at a screen not previously seen.
    case newScreen(fingerprint: String)
    /// Returned to a previously visited screen.
    case revisited(fingerprint: String)
    /// Screen is structurally identical to the source (action had no effect).
    case duplicate
}

/// An action that can be taken to backtrack in the navigation stack.
enum BacktrackAction: Sendable {
    /// Send Cmd+[ keyboard shortcut (works for desktop apps, not iPhone Mirroring).
    case pressBack
    /// Press the home button to return to app root.
    case pressHome
    /// Tap the "<" back button in the iOS navigation bar.
    case tapBack
    /// No backtracking needed or possible.
    case none
}

/// A node in the navigation graph representing a single screen state.
struct ScreenNode: Sendable {
    /// Structural fingerprint identifying this screen.
    let fingerprint: String
    /// OCR elements visible on the screen.
    let elements: [TapPoint]
    /// Detected icon positions (tab bar, toolbar).
    let icons: [IconDetector.DetectedIcon]
    /// Navigation hints (back button detected, etc.).
    let hints: [String]
    /// DFS depth at which this screen was first discovered.
    let depth: Int
    /// Classified screen type.
    let screenType: ScreenType
    /// Base64-encoded screenshot.
    let screenshotBase64: String
    /// Set of element texts that have been tapped/visited from this screen.
    var visitedElements: Set<String>
    /// Extracted nav bar title for fast screen identity comparison.
    let navBarTitle: String?
    /// Whether this screen has infinite scroll (every scroll reveals new content).
    /// Set during calibration when scrolling never exhausts.
    var isInfiniteScroll: Bool = false
    /// Whether scroll exhaustion was reached (no new elements after scrolling).
    var scrollExhausted: Bool = false
}

/// A directed edge in the navigation graph representing a navigation action.
struct NavigationEdge: Sendable {
    /// Fingerprint of the source screen.
    let fromFingerprint: String
    /// Fingerprint of the destination screen.
    let toFingerprint: String
    /// Type of action that caused the transition (e.g. "tap", "swipe").
    let actionType: String
    /// The raw element text used for visited-state matching (must match what was tapped).
    let elementText: String
    /// Clean label derived from the component's LabelRule, free of OCR artifacts.
    /// Used for skill step naming and path display. Falls back to `elementText` when
    /// no component context is available.
    let displayLabel: String
    /// Classified transition type for intelligent backtracking.
    let edgeType: EdgeType
}

/// Immutable export of the navigation graph state for downstream consumers.
struct GraphSnapshot: Sendable {
    /// All screen nodes keyed by fingerprint.
    let nodes: [String: ScreenNode]
    /// All navigation edges in discovery order.
    let edges: [NavigationEdge]
    /// Fingerprint of the root (first) screen.
    let rootFingerprint: String
    /// Edges that produced dead taps (no screen change), as "fromFP:elementText" keys.
    let deadEdges: Set<String>
    /// Recovery events logged during exploration.
    let recoveryEvents: [RecoveryEvent]
}

/// Thread-safe directed graph tracking screen navigation during app exploration.
/// Follows the Session Accumulator pattern: explicit lifecycle with NSLock protection.
final class NavigationGraph: @unchecked Sendable {

    var nodes: [String: ScreenNode] = [:]
    var edges: [NavigationEdge] = []
    var currentFP: String = ""
    var rootFP: String = ""
    var isStarted: Bool = false
    var scrollCounts: [String: Int] = [:]
    var scoutResultsMap: [String: [String: ScoutResult]] = [:]
    var traversalPhases: [String: TraversalPhase] = [:]
    var screenPlans: [String: [RankedElement]] = [:]
    var tapCaches: [String: TapAreaCache] = [:]
    /// Labels of breadth_navigation components (e.g. tab bar items) registered during calibration.
    var breadthLabels: Set<String> = []
    /// Labels of breadth_navigation components already explored. Shared across all screens
    /// so tab bars are not re-tapped from every child screen.
    var globalVisited: Set<String> = []
    /// Edges that produced dead taps (no screen change), keyed by "fromFP:elementText".
    var deadEdges: Set<String> = []
    /// Recovery events logged during exploration for post-hoc diagnosis.
    var recoveryEvents: [RecoveryEvent] = []
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
        scrollCounts = [:]
        scoutResultsMap = [:]
        traversalPhases = [:]
        screenPlans = [:]
        tapCaches = [:]
        breadthLabels = []
        globalVisited = []
        deadEdges = []
        recoveryEvents = []

        let fp = StructuralFingerprint.compute(elements: rootElements, icons: icons)
        let title = StructuralFingerprint.extractNavBarTitle(from: rootElements)
        let node = ScreenNode(
            fingerprint: fp,
            elements: rootElements,
            icons: icons,
            hints: hints,
            depth: 0,
            screenType: screenType,
            screenshotBase64: screenshot,
            visitedElements: [],
            navBarTitle: title
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
        let matchingFP = findMatchingNode(elements: elements)

        let edge = NavigationEdge(
            fromFingerprint: currentFP,
            toFingerprint: matchingFP ?? newFP,
            actionType: actionType,
            elementText: elementText,
            displayLabel: displayLabel ?? elementText,
            edgeType: edgeType
        )
        edges.append(edge)

        if let existingFP = matchingFP {
            currentFP = existingFP
            return .revisited(fingerprint: existingFP)
        }

        // New screen: add node
        let currentDepth = nodes[currentFP]?.depth ?? 0
        let title = StructuralFingerprint.extractNavBarTitle(from: elements)
        let node = ScreenNode(
            fingerprint: newFP,
            elements: elements,
            icons: icons,
            hints: hints,
            depth: currentDepth + 1,
            screenType: screenType,
            screenshotBase64: screenshot,
            visitedElements: [],
            navBarTitle: title
        )
        nodes[newFP] = node
        currentFP = newFP

        return .newScreen(fingerprint: newFP)
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
            rootFingerprint: rootFP,
            deadEdges: deadEdges,
            recoveryEvents: recoveryEvents
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
    func edges(from fingerprint: String) -> [NavigationEdge] {
        lock.lock()
        defer { lock.unlock() }
        return edges.filter { $0.fromFingerprint == fingerprint }
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
        lock.lock()
        defer { lock.unlock() }
        tapCaches[fingerprint, default: TapAreaCache()].record(x: x, y: y)
    }

    /// Check whether a point was already tapped on a screen (within proximity radius).
    func wasAlreadyTapped(fingerprint: String, x: Double, y: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tapCaches[fingerprint]?.wasAlreadyTapped(x: x, y: y) ?? false
    }

    /// Number of tapped areas recorded for a screen.
    func tapCount(for fingerprint: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tapCaches[fingerprint]?.count ?? 0
    }

}
