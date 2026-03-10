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
}

/// Thread-safe directed graph tracking screen navigation during app exploration.
/// Follows the Session Accumulator pattern: explicit lifecycle with NSLock protection.
final class NavigationGraph: @unchecked Sendable {

    private var nodes: [String: ScreenNode] = [:]
    private var edges: [NavigationEdge] = []
    private var currentFP: String = ""
    private var rootFP: String = ""
    private var isStarted: Bool = false
    private var scrollCounts: [String: Int] = [:]
    private var scoutResultsMap: [String: [String: ScoutResult]] = [:]
    private var traversalPhases: [String: TraversalPhase] = [:]
    private var screenPlans: [String: [RankedElement]] = [:]
    private var tapCaches: [String: TapAreaCache] = [:]
    private let lock = NSLock()

    // MARK: - Lifecycle

    /// Initialize the graph with the root screen.
    ///
    /// - Parameters:
    ///   - rootElements: OCR elements from the first screen.
    ///   - icons: Detected icons from the first screen.
    ///   - hints: Navigation hints from the first screen.
    ///   - screenshot: Base64-encoded screenshot of the first screen.
    ///   - screenType: Classified type of the root screen.
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

    /// Record a navigation transition after performing an action.
    /// Compares the new screen against all known nodes using structural similarity.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the new screen.
    ///   - icons: Detected icons from the new screen.
    ///   - hints: Navigation hints from the new screen.
    ///   - screenshot: Base64-encoded screenshot.
    ///   - actionType: The action that caused navigation (e.g. "tap").
    ///   - elementText: The raw element text associated with the action (for visited-state matching).
    ///   - displayLabel: Clean label derived from the component's LabelRule (for skill naming).
    ///   - screenType: Classified type of the new screen.
    ///   - edgeType: Classified transition type for backtracking (default `.push`).
    /// - Returns: A `TransitionResult` indicating what happened.
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
            rootFingerprint: rootFP
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

    /// Get the incoming edge that led to a given screen fingerprint.
    /// Returns the most recent edge pointing to this fingerprint.
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

    /// Get unvisited element texts for a given screen.
    /// Returns elements that have not been marked as visited, sorted by Y position.
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

    // MARK: - Scroll Support

    /// Merge newly discovered elements (from scrolling) into an existing screen node.
    /// Deduplicates by element text — only elements with novel text are added.
    ///
    /// - Parameters:
    ///   - fingerprint: The screen to merge elements into.
    ///   - newElements: Elements from the scrolled viewport.
    /// - Returns: Number of novel elements added, or 0 if all were duplicates.
    func mergeScrolledElements(fingerprint: String, newElements: [TapPoint]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[fingerprint] else { return 0 }
        let existingTexts = Set(node.elements.map(\.text))
        let novel = newElements.filter { !existingTexts.contains($0.text) }
        guard !novel.isEmpty else { return 0 }
        var updatedElements = node.elements
        updatedElements.append(contentsOf: novel)
        nodes[fingerprint] = ScreenNode(
            fingerprint: node.fingerprint,
            elements: updatedElements,
            icons: node.icons,
            hints: node.hints,
            depth: node.depth,
            screenType: node.screenType,
            screenshotBase64: node.screenshotBase64,
            visitedElements: node.visitedElements,
            navBarTitle: node.navBarTitle
        )
        return novel.count
    }

    /// Get the number of scroll actions performed on a screen.
    func scrollCount(for fingerprint: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return scrollCounts[fingerprint, default: 0]
    }

    /// Increment the scroll count for a screen.
    func incrementScrollCount(for fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        scrollCounts[fingerprint, default: 0] += 1
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

    /// Update the current fingerprint to reflect navigation after backtracking.
    /// Called after Cmd+[ or fast-backtrack to sync graph state with the physical screen.
    ///
    /// - Parameter fingerprint: The fingerprint of the screen the explorer landed on.
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
    ///
    /// - Parameters:
    ///   - fingerprint: The screen fingerprint where scouting occurred.
    ///   - elementText: The text of the element that was scouted.
    ///   - result: Whether tapping the element caused navigation.
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

    /// Get the next unvisited element from the screen's exploration plan.
    /// Returns the highest-scored element whose displayLabel is NOT in the visited set.
    /// Uses displayLabel (not raw point.text) to avoid collisions when multiple
    /// components share the same raw text (e.g. YOLO "icon" detections).
    func nextPlannedElement(for fingerprint: String) -> RankedElement? {
        lock.lock()
        defer { lock.unlock() }
        guard let plan = screenPlans[fingerprint],
              let node = nodes[fingerprint] else { return nil }
        return plan.first { !node.visitedElements.contains($0.displayLabel) }
    }

    /// Clear the exploration plan for a screen, forcing a rebuild on next access.
    func clearScreenPlan(for fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        screenPlans[fingerprint] = nil
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

    // MARK: - Node Matching

    /// Find an existing node whose structural elements are similar to the given elements.
    /// Returns the fingerprint of the matching node, or nil if no match found.
    /// Uses title-aware similarity: screens with different nav bar titles are never matched.
    /// Used internally for transition recording and externally for backtrack verification.
    func findMatchingNode(elements: [TapPoint]) -> String? {
        for (fp, node) in nodes {
            let sim = StructuralFingerprint.titleAwareSimilarity(elements, node.elements)
            if sim >= StructuralFingerprint.similarityThreshold {
                return fp
            }
        }
        return nil
    }
}
